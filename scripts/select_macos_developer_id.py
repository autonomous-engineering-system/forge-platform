#!/usr/bin/env python3
"""Select exactly one valid Developer ID Application identity for a Team ID."""

from __future__ import annotations
import argparse
import re
import subprocess
import sys

_HASH=re.compile(r"^[0-9A-F]{40}$")
_TEAM=re.compile(r"^[A-Z0-9]{10}$")
_LINE=re.compile(r'^\s*[0-9]+\)\s+([0-9A-F]{40})\s+"Developer ID Application: .+ \(([A-Z0-9]{10})\)"\s*$')


def parse(output:str,team_id:str)->str:
    if _TEAM.fullmatch(team_id) is None: raise ValueError("Apple Team ID is invalid")
    matches=[]
    for line in output.splitlines():
        match=_LINE.match(line)
        if match and match.group(2)==team_id and _HASH.fullmatch(match.group(1)):
            matches.append(match.group(1))
    if len(matches)!=1:
        raise ValueError("exactly one valid Developer ID Application identity is required")
    return matches[0]


def main()->int:
    p=argparse.ArgumentParser(description=__doc__);p.add_argument("--team-id",required=True);a=p.parse_args()
    try:
        result=subprocess.run(
            ("/usr/bin/security","find-identity","-v","-p","codesigning"),
            capture_output=True,text=True,check=False,
            env={"PATH":"/usr/bin:/bin:/usr/sbin:/sbin","LANG":"C","LC_ALL":"C"},
        )
        if result.returncode: raise ValueError("security identity lookup failed")
        print(parse(result.stdout,a.team_id))
    except (OSError,ValueError) as e:
        print(f"INSTALLER_DEVELOPER_ID=FAIL reason={e}",file=sys.stderr);return 1
    return 0

if __name__=="__main__": raise SystemExit(main())
