"""Unprivileged unsigned public-byte fixtures; never installer runtime input."""
from pathlib import Path
import json
import plistlib
import stat
import subprocess
from types import SimpleNamespace
import zipfile
from forge_platform.installer_release_provenance import canonical_release_provenance_sha256, INSTALLER_RELEASE_PROVENANCE_RESOURCE_NAME
from scripts.prepare_macos_helper_package import APP_RELATIVE, PLIST_RELATIVE, BUNDLE_ID, package_launchdaemon, package_components
from scripts.verified_installer_helper_package import ASSET_NAME


def create(root: Path, *, version='1.1.0', source='a'*40, trust='3'*64, extra_script=False):
    root.mkdir(mode=0o700,parents=True,exist_ok=True);root.chmod(0o700)
    payload=root/'payload';payload.mkdir(mode=0o755)
    app=payload/APP_RELATIVE
    app.mkdir(mode=0o755,parents=True)
    for path in ['Contents/MacOS','Contents/Resources']:(app/path).mkdir(mode=0o755,parents=True,exist_ok=True)
    info=dict(CFBundleIdentifier=BUNDLE_ID,CFBundleShortVersionString=version,CFBundleVersion=version,CFBundlePackageType='APPL',CFBundleExecutable='ForgePlatformInstaller')
    (app/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
    executable=app/'Contents/MacOS/ForgePlatformInstaller';executable.write_bytes(b'source-only nonexecuted bytes');executable.chmod(0o755)
    fields=dict(installer_version=version,channel='stable',release_sequence=7,source_revision=source,policy_revision='forge-platform-installer-release-v1',capabilities=['composition/v1','provider-gate/v1','system-launchdaemon/v1'],release_trust_configuration_sha256=trust)
    digest=canonical_release_provenance_sha256(**fields)
    provenance=dict(fields,schema_version=1,provenance_sha256=digest)
    (app/'Contents/Resources'/INSTALLER_RELEASE_PROVENANCE_RESOURCE_NAME).write_text(json.dumps(provenance))
    daemon=payload/PLIST_RELATIVE;daemon.parent.mkdir(mode=0o755,parents=True);daemon.write_bytes(plistlib.dumps(package_launchdaemon(),fmt=plistlib.FMT_XML,sort_keys=True))
    for path in payload.rglob('*'):
        if path.is_dir():path.chmod(0o755)
        elif path!=executable:path.chmod(0o644)
    archive=root/'source-app.zip'
    with zipfile.ZipFile(archive,'w',compression=zipfile.ZIP_STORED) as bundle:
        for path in [app,*sorted(app.rglob('*'))]:
            relative=app.name+('' if path==app else '/'+str(path.relative_to(app)))
            mode=path.stat().st_mode
            info=zipfile.ZipInfo(relative+('/' if path.is_dir() else ''));info.create_system=3;info.external_attr=mode<<16
            bundle.writestr(info,b'' if path.is_dir() else path.read_bytes())
    archive.chmod(0o600)
    components=root/'components.plist';components.write_bytes(plistlib.dumps(package_components()))
    package=root/ASSET_NAME
    args=['/usr/bin/pkgbuild','--root',str(payload),'--component-plist',str(components),'--ownership','recommended','--compression','legacy','--install-location','/','--identifier',BUNDLE_ID+'.helper-package','--version',version]
    if extra_script:
        scripts=root/'scripts';scripts.mkdir();script=scripts/'postinstall';script.write_bytes(b'#!/bin/sh\nexit 0\n');script.chmod(0o755)
        args.extend(['--scripts',str(scripts)])
    args.append(str(package))
    subprocess.run(args,stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,check=True,env={'PATH':'/usr/bin:/bin:/usr/sbin:/sbin','HOME':'/var/empty','LANG':'C','LC_ALL':'C'})
    package.chmod(0o600)
    return package,archive,SimpleNamespace(installer_version=version,source_revision=source,provenance_sha256=digest)
