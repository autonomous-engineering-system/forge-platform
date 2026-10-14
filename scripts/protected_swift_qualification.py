"""Exact-source native test evidence; never grants installer/runtime authority."""
from __future__ import annotations
import contextlib
import hashlib
import io
import json
import os
from pathlib import Path
import re
import sys
import stat
from scripts import check_managed_installer_swift_coverage as gate
from scripts import protected_root_qualification as provenance


def snapshots(root, targets):
    return {target: hashlib.sha256((root/'macos/ForgePlatformInstaller'/target.lstrip('/')).read_bytes()).hexdigest()
            for target in targets}


def compact(payload, root, targets, minimum):
    provenance.require(gate.validate(payload, targets, minimum) == 0)
    hashes = snapshots(root, targets)
    files = {}
    for block in payload['data']:
        for record in block['files']:
            for target in targets:
                if record['filename'].replace('\\', '/').endswith(target):
                    files[target] = dict(source_sha256=hashes[target], lines=record['summary']['lines'])
    return dict(schema='forge-platform.source-swift-coverage/v1', files=files)


def admitted_payload(counts, root, targets):
    provenance.require(type(counts) is dict and set(counts) == {'schema','files'}
        and counts['schema'] == 'forge-platform.source-swift-coverage/v1'
        and type(counts['files']) is dict and set(counts['files']) == set(targets))
    hashes = snapshots(root, targets); records = []
    for target in targets:
        item = counts['files'][target]
        provenance.require(type(item) is dict and set(item) == {'source_sha256','lines'}
            and item['source_sha256'] == hashes[target] and type(item['lines']) is dict
            and set(item['lines']) == {'count','covered','percent'})
        records.append(dict(filename=target, summary=dict(lines=item['lines'])))
    payload = dict(data=[dict(files=records)])
    provenance.require(gate.validate(payload, targets, 80.2) == 0)
    return payload


def protected_payload(root, env, local_payload, targets, minimum):
    before = snapshots(root, targets)
    # Validate local LLVM structure/counts even if nonadmin execution cannot
    # cover administrator-only assemblies. Local tests remain mandatory.
    with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
        gate.validate(local_payload, targets, minimum)
    counts = provenance.read_counts(root, env, kind='swift')
    result = admitted_payload(counts, root, targets)
    provenance.require(before == snapshots(root, targets))
    return result


def measured_payload(path, maximum=64*1024*1024):
    fd = os.open(path, os.O_RDONLY|os.O_NONBLOCK|getattr(os,'O_NOFOLLOW_ANY',os.O_NOFOLLOW))
    try:
        before = os.fstat(fd)
        provenance.require(stat.S_ISREG(before.st_mode) and 0 < before.st_size <= maximum)
        raw = bytearray()
        while True:
            block = os.read(fd, min(65536, maximum+1-len(raw)))
            if not block: break
            raw.extend(block); provenance.require(len(raw) <= maximum)
        def identity(value): return (value.st_dev,value.st_ino,value.st_size,value.st_mtime_ns,value.st_ctime_ns)
        provenance.require(identity(before) == identity(os.fstat(fd)) == identity(path.lstat()))
        def pairs(items):
            result = {}
            for key,value in items:
                provenance.require(key not in result); result[key] = value
            return result
        def invalid(_): raise ValueError('non-JSON native measurement constant')
        return json.loads(raw, object_pairs_hook=pairs, parse_constant=invalid)
    finally: os.close(fd)


def qualify(root, env):
    provenance.require(env.get('GITHUB_ACTIONS') == 'true' and env.get('GITHUB_WORKFLOW') == 'Foundation validation'
        and env.get('GITHUB_REPOSITORY') == provenance.REPOSITORY and env.get('GITHUB_EVENT_NAME') == 'push'
        and env.get('GITHUB_REF') == 'refs/heads/main' and env.get('GITHUB_REF_PROTECTED') == 'true')
    sha = provenance.git(root, 'rev-parse', 'HEAD'); tree = provenance.git(root, 'rev-parse', 'HEAD^{tree}')
    provenance.require(sha == env.get('GITHUB_SHA') == env.get('GITHUB_WORKFLOW_SHA')
        and not provenance.git(root, 'status', '--porcelain', '--untracked-files=all'))
    provenance.require(all(re.fullmatch('[1-9][0-9]*', env.get(k,'')) is not None for k in ('GITHUB_RUN_ID','GITHUB_RUN_ATTEMPT')))
    targets = gate.required_targets(env['COVERAGE_BASE_SHA']); before = snapshots(root, targets)
    measured = Path(env['RUNNER_TEMP']).resolve()/'forge-platform-native-evidence/swift-coverage.json'
    payload = measured_payload(measured)
    counts = compact(payload, root, targets, 80.2)
    provenance.require(before == snapshots(root, targets)
        and provenance.git(root, 'rev-parse', 'HEAD') == sha and provenance.git(root, 'rev-parse', 'HEAD^{tree}') == tree
        and not provenance.git(root, 'status', '--porcelain', '--untracked-files=all'))
    return dict(schema='forge-platform.protected-swift-qualification/v1', repository=provenance.REPOSITORY,
        source_sha=sha, source_tree=tree, workflow=provenance.FOUNDATION, workflow_sha=sha,
        run_id=int(env['GITHUB_RUN_ID']), run_attempt=int(env['GITHUB_RUN_ATTEMPT']),
        qualification='PASS_EVERY_SWIFT_FILE', counts=counts)


def export(root, env):
    value = qualify(root, env)
    raw = (json.dumps(value, sort_keys=True, separators=(',', ':'), allow_nan=False)+'\n').encode()
    provenance.require(0 < len(raw) <= provenance.MAXIMUM)
    temp = Path(env['RUNNER_TEMP']).resolve()
    directory = os.open(temp, os.O_RDONLY|os.O_DIRECTORY|getattr(os,'O_NOFOLLOW_ANY',os.O_NOFOLLOW))
    try:
        before = os.fstat(directory)
        fd = os.open('swift-qualification.json',os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600,dir_fd=directory)
        try:
            provenance.require(os.write(fd,raw) == len(raw)); os.fsync(fd)
        finally: os.close(fd)
        os.fsync(directory)
        after = temp.lstat(); provenance.require((before.st_dev,before.st_ino) == (after.st_dev,after.st_ino))
    finally: os.close(directory)
    print('PROTECTED_SWIFT_SOURCE_QUALIFICATION=PASS')


if __name__ == '__main__':
    provenance.require(sys.argv[1:] == ['--export'])
    export(Path(__file__).resolve().parents[1], os.environ)
