"""Frozen public carriers for read-only Apple signature source qualification.

No signing/keychain authority, provider cache, product operation or installed
PASS. Only two exact public ZIPs are admitted; existing bytes are hash-checked.
"""
from __future__ import annotations
import hashlib,os,plistlib,stat,subprocess,tempfile,urllib.request
from pathlib import Path

POLICY='anchor apple generic and identifier "com.autonomous-engineering-system.forge-platform-installer" and certificate leaf[subject.OU] = "ZEML4LPXH4"'
ARTIFACTS={
 '0.4.20':(54530542,'25ba1ea041d27403feb358c8c38720d1b3d9d86a902507b8165249f8c62aabb9','4f49a4bb6a3c14cd082c813769beaf0602186838908742284a9ac2a383bfda20'),
 '0.4.21':(55170911,'9dc8d97dbba7d267cc5c3fbf8b33919c34948a94109772c2ef26624471846724','fb78ea1180af984cc0d1d80ba6fc973e3eb3dc526791d15b9305a5f8be90ae2d')}

def public_signed_app(version):
 size,digest,cd=ARTIFACTS[version]
 cache=Path(tempfile.gettempdir()).resolve()/('fpi-readonly-signed-qualification-'+str(os.geteuid()))
 cache.mkdir(mode=0o700,exist_ok=True)
 details=cache.lstat()
 assert stat.S_ISDIR(details.st_mode) and not cache.is_symlink() and details.st_uid==os.geteuid() and stat.S_IMODE(details.st_mode)==0o700
 archive=cache/(digest+'.zip')
 if not archive.exists():
  url='https://github.com/autonomous-engineering-system/forge-platform/releases/download/forge-platform-installer-v'+version+'/ForgePlatformInstaller-macos-arm64.zip'
  fd,name=tempfile.mkstemp(prefix='download-',dir=cache)
  try:
   with os.fdopen(fd,'wb') as output,urllib.request.urlopen(url,timeout=60) as response:
    total=0
    while block:=response.read(1024*1024):
     total+=len(block);assert total<=size;output.write(block)
    output.flush();os.fsync(output.fileno())
   candidate=Path(name);assert candidate.stat().st_size==size and hashlib.sha256(candidate.read_bytes()).hexdigest()==digest
   os.link(candidate,archive,follow_symlinks=False)
  finally:Path(name).unlink(missing_ok=True)
 details=archive.lstat()
 assert stat.S_ISREG(details.st_mode) and not archive.is_symlink() and details.st_uid==os.geteuid() and details.st_nlink==1 and stat.S_IMODE(details.st_mode)==0o600
 assert details.st_size==size and hashlib.sha256(archive.read_bytes()).hexdigest()==digest
 directory=cache/version;app=directory/'ForgePlatformInstaller.app'
 if not directory.exists():
  directory.mkdir(mode=0o700)
  subprocess.run(['/usr/bin/ditto','-x','-k',str(archive),str(directory)],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
 assert not directory.is_symlink() and directory.stat().st_uid==os.geteuid() and stat.S_IMODE(directory.stat().st_mode)==0o700
 assert plistlib.loads((app/'Contents/Info.plist').read_bytes())['CFBundleShortVersionString']==version
 subprocess.run(['/usr/bin/codesign','--verify','--deep','--strict','-R='+POLICY,str(app)],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
 return app,cd

def require_wrong_identity_rejected(app):
 for policy in [POLICY.replace('forge-platform-installer"','unrelated-installer"'),POLICY.replace('ZEML4LPXH4','AAAAAAAAAA')]:
  result=subprocess.run(['/usr/bin/codesign','--verify','--deep','--strict','-R='+policy,str(app)],stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
  assert result.returncode!=0
