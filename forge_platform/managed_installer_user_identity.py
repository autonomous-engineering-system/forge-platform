"""Read-only real macOS operator identity for signed installer authority v6."""
from hashlib import sha256
import json
import pwd
import re
import subprocess
import uuid

class InstallerUserIdentityError(RuntimeError):
    pass

def canonical_identity(account_name, uid, gid, generated_uid):
    if (not isinstance(account_name, str) or account_name == 'root' or account_name.startswith('_')
        or not re.fullmatch(r'[A-Za-z][A-Za-z0-9_.-]{0,254}', account_name)
        or not isinstance(uid, int) or uid <= 0 or not isinstance(gid, int) or gid <= 0):
        raise InstallerUserIdentityError('named installer operator is invalid')
    try:identifier=str(uuid.UUID(generated_uid)).lower()
    except (ValueError, TypeError, AttributeError) as error:
        raise InstallerUserIdentityError('macOS operator UUID is invalid') from error
    return json.dumps({'account_name':account_name,'uid':uid,'gid':gid,'generated_uid':identifier},
                      sort_keys=True,separators=(',',':')).encode()

def resolve_identity_sha256(account_name):
    # Validate name before using it as one literal Open Directory record argument.
    if not isinstance(account_name,str) or not re.fullmatch(r'[A-Za-z][A-Za-z0-9_.-]{0,254}',account_name):
        raise InstallerUserIdentityError('named installer operator is invalid')
    account=pwd.getpwnam(account_name)
    if account.pw_name!=account_name:
        raise InstallerUserIdentityError('macOS operator lookup drifted')
    result=subprocess.run(['/usr/bin/dscl','.','-read','/Users/'+account_name,'GeneratedUID'],
                          cwd='/',stdin=subprocess.DEVNULL,capture_output=True,text=True,
                          timeout=5,check=False,env={'PATH':'/usr/bin:/bin:/usr/sbin:/sbin'})
    label,separator,identifier=result.stdout.strip().partition(':')
    if result.returncode or label!='GeneratedUID' or not separator:
        raise InstallerUserIdentityError('macOS operator identity unavailable')
    raw=canonical_identity(account_name,account.pw_uid,account.pw_gid,identifier.strip())
    return 'sha256:'+sha256(raw).hexdigest()
