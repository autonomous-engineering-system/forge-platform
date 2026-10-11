"""Closed public certificate/notary metadata parsing; no credential access."""
import json
import re
import uuid


def select_installer_identity(raw: str, selection: str, team: str) -> str:
    if (not isinstance(raw,str) or len(raw)>65536 or not isinstance(selection,str) or not selection
        or len(selection)>512 or any(ord(c)<32 for c in selection) or not isinstance(team,str) or re.fullmatch(r"[A-Z0-9]{10}",team) is None):
        raise ValueError("installer signing selection invalid")
    matches=[]
    for line in raw.splitlines():
        parsed=re.fullmatch(r'\s*[0-9]+\)\s+([0-9A-Fa-f]{40})\s+"([^"\r\n]+)"\s*',line)
        if parsed is None:continue
        fingerprint,name=parsed.groups()
        if name==selection or fingerprint.upper()==selection.upper():
            if any(ord(c)<32 for c in name) or not name.startswith("Developer ID Installer: ") or not name.endswith(" ("+team+")"):
                raise ValueError("installer certificate class or team invalid")
            matches.append(fingerprint.upper())
    if len(matches)!=1:raise ValueError("installer signing identity absent or ambiguous")
    return matches[0]


def accepted_notary_identifier(raw: bytes) -> str:
    if not isinstance(raw,bytes) or not 0<len(raw)<=65536:raise ValueError("package notary metadata exceeds bound")
    def unique(pairs):
        value={}
        for key,item in pairs:
            if key in value:raise ValueError("package notary metadata duplicated")
            value[key]=item
        return value
    def constant(value):raise ValueError("package notary metadata is not finite")
    try:value=json.loads(raw.decode("utf-8"),object_pairs_hook=unique,parse_constant=constant)
    except (UnicodeError,ValueError) as error:raise ValueError("package notary metadata invalid") from error
    if not isinstance(value,dict) or value.get("status")!="Accepted" or not isinstance(value.get("id"),str):
        raise ValueError("package notarization not accepted")
    try:identifier=str(uuid.UUID(value["id"]))
    except ValueError as error:raise ValueError("package notary identifier invalid") from error
    if value["id"].lower()!=identifier:raise ValueError("package notary identifier not canonical")
    return identifier
