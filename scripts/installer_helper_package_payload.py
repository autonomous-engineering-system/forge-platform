"""Bounded read-only companion-payload inspection; never extract or execute it."""
from hashlib import sha256
import gzip
import io
import os
from pathlib import Path
import plistlib
import re
import resource
import stat
import struct
import subprocess
import tempfile
import xml.etree.ElementTree as XML
import zipfile
import zlib
from forge_platform.installer_release_provenance import parse_installer_release_provenance_bytes, INSTALLER_RELEASE_PROVENANCE_RESOURCE_NAME
from scripts.prepare_macos_helper_package import APP_RELATIVE, PLIST_RELATIVE, BUNDLE_ID, package_launchdaemon

LIMIT = 512 * 1024 * 1024


def _xml(data):
    if len(data)>1024*1024 or b'<!DOCTYPE' in data or b'<!ENTITY' in data:
        raise ValueError('helper package XML is not bounded and closed')
    try:
        text=data.decode('utf-8')
        return XML.fromstring(text)
    except (XML.ParseError,UnicodeError) as error:raise ValueError('helper package XML invalid') from error


def _inflate(data, size):
    if not 0<size<=4*1024*1024:raise ValueError('helper package metadata exceeds bound')
    decoder=zlib.decompressobj();value=decoder.decompress(data,size+1)
    if len(value)!=size or not decoder.eof or decoder.unused_data or decoder.unconsumed_tail:
        raise ValueError('helper package metadata compression differs')
    return value


def _xar(fd):
    try:magic,header,version,compressed,expanded,algorithm=struct.unpack('>4sHHQQI',os.pread(fd,28,0))
    except struct.error as error:raise ValueError('helper package XAR header invalid') from error
    total=os.fstat(fd).st_size
    if magic!=b'xar!' or header!=28 or version!=1 or not 0<compressed<=1024*1024 or header+compressed>total:
        raise ValueError('helper package XAR profile invalid')
    root=_xml(_inflate(os.pread(fd,compressed,header),expanded))
    toc=root.find('toc')
    if root.tag!='xar' or toc is None or len(root.findall('toc'))!=1:raise ValueError('helper package XAR TOC invalid')
    entries={};ranges=[]
    for node in toc.findall('file'):
        name=node.findtext('name');data=node.find('data');names=node.findall('name')
        # Apple's real signed package can repeat the same plain name. Admit
        # only that bounded representation, without ambiguous member identity.
        if (len(names) not in {1,2} or any(value.attrib or len(value) or value.text!=name for value in names)
            or name not in {'PackageInfo','Bom','Payload'} or name in entries or node.findtext('type')!='file'
            or node.findall('.//file') or data is None or any(len(node.findall(key))!=1 for key in ['type','data'])):
            raise ValueError('helper package contains unexpected member or scripts')
        values=[]
        for key in ['offset','length','size']:
            raw=data.findtext(key)
            if raw is None or len(data.findall(key))!=1 or re.fullmatch(r'0|[1-9][0-9]*',raw) is None:raise ValueError('helper package member extent invalid')
            values.append(int(raw))
        offset,length,size=values;start=header+compressed+offset
        encoding=data.find('encoding')
        if not 0<length<=LIMIT or not 0<size<=LIMIT or start+length>total or encoding is None or len(data.findall('encoding'))!=1 or any(start<end and beginning<start+length for beginning,end in ranges):
            raise ValueError('helper package member bounds invalid')
        style=encoding.get('style')
        if name=='Payload' and (style!='application/octet-stream' or length!=size):raise ValueError('helper package payload encoding unsupported')
        if name!='Payload' and (style not in {'application/x-gzip','application/octet-stream'} or size>4*1024*1024):raise ValueError('helper package metadata encoding unsupported')
        entries[name]=(start,length,size,style);ranges.append((start,start+length))
    if set(entries)!={'PackageInfo','Bom','Payload'}:raise ValueError('helper package members incomplete')
    return entries


def _metadata(fd,entry):
    start,length,size,style=entry;data=os.pread(fd,length,start)
    if len(data)!=length:raise ValueError('helper package metadata truncated')
    if style=='application/x-gzip':return _inflate(data,size)
    if len(data)!=size:raise ValueError('helper package metadata size differs')
    return data


def _archive(archive,preparation,expected_digest):
    if archive.is_symlink():raise ValueError('companion archive symlink')
    descriptor=os.open(archive,os.O_RDONLY|os.O_NONBLOCK|os.O_NOFOLLOW)
    try:
        before=os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode) or before.st_nlink!=1 or before.st_size>LIMIT:raise ValueError('companion archive invalid')
        digest=sha256();position=0
        while position<before.st_size:
            block=os.pread(descriptor,min(65536,before.st_size-position),position)
            if not block:raise ValueError('companion archive truncated')
            digest.update(block);position+=len(block)
        if 'sha256:'+digest.hexdigest()!=expected_digest:raise ValueError('companion archive differs from signed archive digest')
        expected={};metadata={};root=None
        with os.fdopen(os.dup(descriptor),'rb') as stream,zipfile.ZipFile(stream) as bundle:
            infos=bundle.infolist()
            if not 0<len(infos)<=8192:raise ValueError('companion archive entry bound exceeded')
            total=0
            for entry in infos:
                name=entry.filename.rstrip('/');parts=name.split('/')
                if len(parts)>64 or any(not p or p in {'.','..','__MACOSX','.DS_Store'} or p.startswith('._') or re.fullmatch(r'[A-Za-z0-9 +._-]+',p) is None for p in parts):raise ValueError('companion archive path invalid')
                if root is None:root=parts[0]
                if not root.endswith('.app') or parts[0]!=root or entry.create_system!=3:raise ValueError('companion archive root invalid')
                mode=entry.external_attr>>16
                if stat.S_IFMT(mode) not in {stat.S_IFDIR,stat.S_IFREG} or mode&0o7022 or (stat.S_ISDIR(mode) and mode&0o777!=0o755):raise ValueError('companion archive mode invalid')
                target='.'+'/'+APP_RELATIVE+('' if len(parts)==1 else '/'+'/'.join(parts[1:]))
                if target in expected:raise ValueError('duplicate companion archive path')
                if stat.S_ISDIR(mode):
                    if entry.file_size:raise ValueError('companion archive directory data')
                    expected[target]=(mode,0,0,0,None);continue
                total+=entry.file_size
                if total>LIMIT:raise ValueError('companion archive expansion bound exceeded')
                digest=sha256();collected=bytearray()
                relative='/'.join(parts[1:]);capture=relative in {'Contents/Info.plist','Contents/Resources/'+INSTALLER_RELEASE_PROVENANCE_RESOURCE_NAME}
                if capture and entry.file_size>32*1024:raise ValueError('companion sealed metadata bound exceeded')
                with bundle.open(entry) as file:
                    for block in iter(lambda:file.read(65536),b''):
                        digest.update(block)
                        if capture:collected.extend(block)
                expected[target]=(mode,0,0,entry.file_size,digest.hexdigest())
                if capture:metadata[relative]=bytes(collected)
        after=os.fstat(descriptor)
        if (before.st_dev,before.st_ino,before.st_size,before.st_mtime_ns,before.st_ctime_ns)!=(after.st_dev,after.st_ino,after.st_size,after.st_mtime_ns,after.st_ctime_ns) or archive.lstat().st_ino!=before.st_ino:raise ValueError('companion archive changed')
        info=plistlib.loads(metadata.get('Contents/Info.plist',b''))
        provenance=parse_installer_release_provenance_bytes(metadata.get('Contents/Resources/'+INSTALLER_RELEASE_PROVENANCE_RESOURCE_NAME,b''))
        if (info.get('CFBundleIdentifier')!=BUNDLE_ID or info.get('CFBundleShortVersionString')!=preparation.installer_version
            or info.get('CFBundleVersion')!=preparation.installer_version or provenance.installer_version!=preparation.installer_version
            or provenance.source_revision!=preparation.source_revision or provenance.provenance_sha256!=preparation.provenance_sha256):raise ValueError('companion archive differs from prepared release')
        for name in ['.','./Library','./Library/Application Support','./Library/Application Support/ForgePlatformInstallerHelper','./Library/LaunchDaemons']:
            expected[name]=(stat.S_IFDIR|0o755,0,0,0,None)
        daemon=plistlib.dumps(package_launchdaemon(),fmt=plistlib.FMT_XML,sort_keys=True)
        expected['./'+PLIST_RELATIVE]=(stat.S_IFREG|0o644,0,0,len(daemon),sha256(daemon).hexdigest())
        return expected
    finally:os.close(descriptor)


class _Region(io.RawIOBase):
    def __init__(self,fd,start,length):self.fd=fd;self.start=start;self.length=length;self.position=0
    def read(self,size=-1):
        size=min(self.length-self.position,65536 if size<0 else size)
        value=os.pread(self.fd,size,self.start+self.position);self.position+=len(value);return value


def _os_provenance_sidecar(data):
    # The existing producer profile permits only macOS's protected provenance
    # attribute. No resource fork, Finder flags, ACL, quarantine or other xattr.
    if len(data)!=163:raise ValueError('helper package AppleDouble size unsupported')
    magic,version,filler,count=struct.unpack_from('>II16sH',data)
    if magic!=0x51607 or version!=0x20000 or count!=2:
        raise ValueError('helper package AppleDouble header unsupported')
    if [struct.unpack_from('>III',data,26+12*i) for i in range(2)]!=[(9,50,113),(2,163,0)] or any(data[50:84]):
        raise ValueError('helper package resource fork or Finder metadata forbidden')
    fields=struct.unpack_from('>IIIIIIIIHH',data,84)
    if fields!=(0x41545452,0,163,152,11,0,0,0,0,1):
        raise ValueError('helper package attribute layout unsupported')
    if struct.unpack_from('>IIHB',data,120)!=(152,11,0,21) or data[131:152]!=b'com.apple.provenance\0':
        raise ValueError('helper package unexpected extended attribute')


def _cpio(fd,entry,expected):
    start,length,_,_=entry
    if os.pread(fd,2,start)!=b'\x1f\x8b':raise ValueError('helper package requires legacy gzip payload')
    found=set();sidecars={};total=0;maximum=sum(v[3] for v in expected.values())+len(expected)*(2400)+1024
    with gzip.GzipFile(fileobj=_Region(fd,start,length)) as stream:
        def read(size):
            nonlocal total
            value=stream.read(size);total+=len(value)
            if len(value)!=size or total>maximum:raise ValueError('helper package CPIO bounds invalid')
            return value
        while True:
            header=read(76)
            if header[:6]!=b'070707' or re.fullmatch(b'[0-7]{70}',header[6:]) is None:raise ValueError('helper package CPIO profile invalid')
            mode=int(header[18:24],8);uid=int(header[24:30],8);gid=int(header[30:36],8);links=int(header[36:42],8)
            name_size=int(header[59:65],8);size=int(header[65:76],8)
            if not 0<name_size<=1024:raise ValueError('helper package CPIO name bounds invalid')
            raw=read(name_size)
            if not raw.endswith(b'\0') or b'\0' in raw[:-1]:raise ValueError('helper package CPIO name invalid')
            name=raw[:-1].decode('utf-8')
            if name=='TRAILER!!!':
                if size or found!=set(expected)|set(sidecars):raise ValueError('helper package payload incomplete')
                tail=stream.read(513)
                if len(tail)>512 or any(tail):raise ValueError('helper package trailing data invalid')
                break
            if name not in expected:
                parent, separator, leaf=name.rpartition('/')
                target=parent+'/'+leaf[2:] if separator and leaf.startswith('._') else ''
                target_spec=expected.get(target)
                expected_links=(2+sum(1 for path in expected if path.rpartition('/')[0]==target)) if target_spec and stat.S_ISDIR(target_spec[0]) else 1
                if (target_spec is None or name in found or len(found)>=8192
                    or (mode,uid,gid,size,links)!=(stat.S_IFREG|0o644,0,0,163,expected_links)):
                    raise ValueError('helper package unexpected payload path or sidecar')
                _os_provenance_sidecar(read(size))
                sidecars[name]=(expected[target][0],0,0,0,None)
                found.add(name)
                continue
            if name in found or len(found)>=8192:raise ValueError('helper package duplicate payload path')
            expected_mode,expected_uid,expected_gid,expected_size,digest=expected[name]
            if (mode,uid,gid,size)!=(expected_mode,expected_uid,expected_gid,expected_size) or (stat.S_ISREG(mode) and links!=1):raise ValueError('helper package payload metadata differs')
            hasher=sha256();remaining=size
            while remaining:
                block=read(min(remaining,65536));hasher.update(block);remaining-=len(block)
            if digest is not None and hasher.hexdigest()!=digest:raise ValueError('helper package app or daemon bytes differ')
            found.add(name)

    return sidecars


def _bom(data,expected):
    with tempfile.TemporaryDirectory(prefix='fpi-bom-inspection-') as temporary:
        path=Path(temporary)/'Bom';path.write_bytes(data)
        with tempfile.TemporaryFile() as output:
            def bound():resource.setrlimit(resource.RLIMIT_FSIZE,(8*1024*1024,8*1024*1024))
            result=subprocess.run(['/usr/bin/lsbom','-p','fmugs',str(path)],stdin=subprocess.DEVNULL,stdout=output,stderr=subprocess.DEVNULL,timeout=20,check=False,preexec_fn=bound,env={'PATH':'/usr/bin:/bin','HOME':'/var/empty','LANG':'C','LC_ALL':'C'})
            if result.returncode or output.tell()>8*1024*1024:raise ValueError('helper package BOM inspection failed')
            output.seek(0);text=output.read().decode('utf-8')
    rows={}
    for row in text.splitlines():
        fields=row.split('\t')
        if len(fields)!=5 or fields[0] in rows or fields[0] not in expected:raise ValueError('helper package BOM path differs')
        name,mode,uid,gid,size=fields
        if re.fullmatch(r'[0-7]+',mode) is None or uid!='0' or gid!='0' or (size and re.fullmatch(r'0|[1-9][0-9]*',size) is None):raise ValueError('helper package BOM metadata invalid')
        rows[name]=(int(mode,8),0,0,int(size or '0'))
    if rows!={name:values[:4] for name,values in expected.items()}:raise ValueError('helper package BOM differs from exact payload')


def _verify_payload(fd,*,archive,preparation,archive_digest):
    entries=_xar(fd);info=_xml(_metadata(fd,entries['PackageInfo']))
    bundle=info.find('bundle')
    groups={'payload','bundle','bundle-version','upgrade-bundle','update-bundle','atomic-update-bundle','strict-identifier','relocate'}
    if set(info.attrib)!={'overwrite-permissions','relocatable','identifier','postinstall-action','version','format-version','generator-version','install-location','auth'} or info.get('overwrite-permissions')!='true' or info.get('format-version')!='2' or any(len(info.findall(tag))!=1 for tag in groups):
        raise ValueError('helper package installation profile unsupported')
    for tag in ['bundle-version','upgrade-bundle','strict-identifier']:
        group=info.find(tag)
        if len(group)!=1 or group[0].tag!='bundle' or group[0].attrib!={'id':BUNDLE_ID}:
            raise ValueError('helper package bundle replacement scope differs')
    for tag in ['update-bundle','atomic-update-bundle','relocate']:
        if len(info.find(tag)) or info.find(tag).attrib:
            raise ValueError('helper package relocation or update scope differs')

    if (info.tag!='pkg-info' or info.get('identifier')!=BUNDLE_ID+'.helper-package' or info.get('version')!=preparation.installer_version
        or info.get('install-location')!='/' or info.get('relocatable')!='false' or info.get('auth')!='root'
        or info.get('postinstall-action')!='none' or any(child.tag not in {'payload','bundle','bundle-version','upgrade-bundle','update-bundle','atomic-update-bundle','strict-identifier','relocate'} for child in info) or info.findall('.//scripts') or bundle is None
        or bundle.get('path')!='./'+APP_RELATIVE or bundle.get('id')!=BUNDLE_ID
        or bundle.get('CFBundleVersion')!=preparation.installer_version or bundle.get('CFBundleShortVersionString')!=preparation.installer_version):raise ValueError('helper package install declarations differ from release')
    expected=_archive(archive,preparation,archive_digest)
    sidecars=_cpio(fd,entries['Payload'],expected)
    _bom(_metadata(fd,entries['Bom']),dict(expected,**sidecars))


def verify_payload(fd,*,archive,preparation,archive_digest):
    try:
        _verify_payload(fd,archive=archive,preparation=preparation,archive_digest=archive_digest)
    except (zlib.error,zipfile.BadZipFile,struct.error,EOFError,UnicodeError,XML.ParseError) as error:
        raise ValueError('helper package payload format invalid') from error
