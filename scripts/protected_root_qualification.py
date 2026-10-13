"""Source qualification only: closed protected-build consumption of hosted root traces.

No installer/provider/runtime authority. No caller-selected receipt path or URL.
GitHub readback independently qualifies the owning workflow and exact artifact.
"""
from __future__ import annotations
import hashlib
import io
import json
import os
from pathlib import Path
import re
import select
import subprocess
import time
import zipfile

REPOSITORY = 'autonomous-engineering-system/forge-platform'
FOUNDATION = '.github/workflows/foundation-validation.yml'
BUILD_WORKFLOWS = {
    'Forge Platform installer release framework': '.github/workflows/forge-platform-installer-release.yml',
    'Native Mac installer integration': '.github/workflows/macos-installer-native-integration.yml',
}
JOBS = {'Repository unit and integration tests', 'Native macOS validation / Swift installer-domain tests', 'Foundation validation'}
SCHEMA = 'forge-platform.protected-root-qualification/v1'
MAXIMUM = 2 * 1024 * 1024


def require(ok):
    if not ok: raise ValueError('protected root qualification unavailable or inconsistent')


def decode(raw):
    require(isinstance(raw, bytes) and 0 < len(raw) <= MAXIMUM)
    def pairs(items):
        result = {}
        for key, value in items:
            require(key not in result); result[key] = value
        return result
    def invalid(_): raise ValueError('non-JSON qualification constant')
    return json.loads(raw, object_pairs_hook=pairs, parse_constant=invalid)


def git(root, *args):
    return subprocess.check_output(['git', *args], cwd=root, stderr=subprocess.DEVNULL, timeout=30).decode().strip()


def protected_build(env):
    return env.get('GITHUB_ACTIONS') == 'true' and env.get('GITHUB_WORKFLOW') in BUILD_WORKFLOWS


def context(root, env):
    require(env.get('GITHUB_REPOSITORY') == REPOSITORY and env.get('GITHUB_REF') == 'refs/heads/main'
            and env.get('GITHUB_REF_PROTECTED') == 'true' and env.get('GITHUB_EVENT_NAME') == 'workflow_dispatch'
            and protected_build(env) and bool(env.get('GH_TOKEN'))
            and env.get('GITHUB_SERVER_URL') == 'https://github.com'
            and env.get('GITHUB_API_URL') == 'https://api.github.com')
    sha = env.get('GITHUB_SHA', '')
    require(re.fullmatch('[0-9a-f]{40}', sha) is not None and env.get('GITHUB_WORKFLOW_SHA') == sha)
    require(git(root, 'rev-parse', 'HEAD') == sha and not git(root, 'status', '--porcelain', '--untracked-files=all'))
    run = env.get('GITHUB_RUN_ID', ''); attempt = env.get('GITHUB_RUN_ATTEMPT', '')
    require(re.fullmatch('[1-9][0-9]*', run) is not None and re.fullmatch('[1-9][0-9]*', attempt) is not None)
    return sha, git(root, 'rev-parse', 'HEAD^{tree}'), int(run), int(attempt), BUILD_WORKFLOWS[env['GITHUB_WORKFLOW']]


def gh_bytes(endpoint):
    # Fixed repository API only. gh owns authenticated GitHub redirects; no token
    # is placed in argv, emitted, or forwarded by our own HTTP redirect handler.
    require(endpoint.startswith('repos/' + REPOSITORY + '/') and '\n' not in endpoint)
    process = subprocess.Popen(['gh', 'api', '--hostname', 'github.com', endpoint], stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    raw = bytearray(); deadline = time.monotonic() + 60
    try:
        while True:
            remaining = deadline - time.monotonic(); require(remaining > 0)
            ready, _, _ = select.select([process.stdout], [], [], remaining); require(bool(ready))
            block = os.read(process.stdout.fileno(), min(65536, MAXIMUM + 1 - len(raw)))
            if not block: break
            raw.extend(block); require(len(raw) <= MAXIMUM)
        require(process.wait(timeout=max(.01, deadline-time.monotonic())) == 0)
        return bytes(raw)
    finally:
        if process.poll() is None:
            process.kill(); process.wait(timeout=5)
        process.stdout.close()


def api(endpoint): return decode(gh_bytes('repos/' + REPOSITORY + '/' + endpoint))


def positive_integer(value): return type(value) is int and value > 0


def workflow_path(value, expected):
    return value in (expected, expected + '@refs/heads/main')


def read_counts(root, env, read_api=api, read_bytes=gh_bytes, *, kind='root'):
    sha, tree, own_run, own_attempt, own_workflow = context(root, env)
    branch = read_api('branches/main')
    require(branch.get('protected') is True and branch['commit']['sha'] == sha)
    rules = read_api('rules/branches/main')
    require(any(r.get('type') == 'required_status_checks' and any(
        c.get('context') == 'Foundation validation' for c in r['parameters']['required_status_checks']) for r in rules))
    own = read_api(f'actions/runs/{own_run}/attempts/{own_attempt}')
    require(positive_integer(own.get('id')) and positive_integer(own.get('run_attempt'))
        and own.get('id') == own_run and own.get('run_attempt') == own_attempt
        and own.get('head_sha') == sha and own.get('head_branch') == 'main'
        and own.get('event') == 'workflow_dispatch' and workflow_path(own.get('path'), own_workflow)
        and own.get('status') == 'in_progress' and own.get('conclusion') is None)
    counts = read_hosted_counts(sha, tree, read_api, read_bytes, kind=kind)
    require(context(root, env) == (sha, tree, own_run, own_attempt, own_workflow))
    require(read_api('branches/main')['commit']['sha'] == sha)
    return counts


def read_hosted_counts(sha, tree, read_api=api, read_bytes=gh_bytes, *, kind='root'):
    """Read-only qualification evidence, never a protected-build caller admission.

    Enables independent artifact preflight before spending the single dispatch.
    The build gate always enters through read_counts and its current-run guards.
    """
    require(kind in ('root', 'swift'))
    require(re.fullmatch('[0-9a-f]{40}', sha) is not None and re.fullmatch('[0-9a-f]{40}', tree) is not None)
    branch = read_api('branches/main')
    require(branch.get('protected') is True and branch['commit']['sha'] == sha)
    workflow = read_api('actions/workflows/foundation-validation.yml')
    require(workflow.get('path') == FOUNDATION and workflow.get('state') == 'active' and positive_integer(workflow.get('id')))
    listed = read_api(f'actions/workflows/foundation-validation.yml/runs?event=push&branch=main&head_sha={sha}&status=completed&per_page=20')
    require(type(listed.get('total_count')) is int and 0 <= listed['total_count'] <= 20)
    runs = [r for r in listed['workflow_runs'] if r.get('head_sha') == sha and r.get('head_branch') == 'main'
        and r.get('event') == 'push' and r.get('status') == 'completed' and r.get('conclusion') == 'success'
        and r.get('workflow_id') == workflow['id'] and workflow_path(r.get('path'), FOUNDATION)]
    require(len(runs) == 1)
    run = runs[0]; identifier = run['id']; attempt = run['run_attempt']
    require(positive_integer(identifier) and positive_integer(attempt))
    exact = read_api(f'actions/runs/{identifier}/attempts/{attempt}')
    for key in ('id', 'run_attempt', 'head_sha', 'head_branch', 'event', 'status', 'conclusion', 'workflow_id', 'path'):
        require(type(exact.get(key)) is type(run.get(key)) and exact.get(key) == run.get(key))
    jobs = read_api(f'actions/runs/{identifier}/attempts/{attempt}/jobs?per_page=100')
    require(type(jobs.get('total_count')) is int and jobs['total_count'] <= 100 and len(jobs['jobs']) == jobs['total_count'])
    for name in JOBS:
        matches = [j for j in jobs['jobs'] if j.get('name') == name]
        require(len(matches) == 1 and matches[0].get('status') == 'completed' and matches[0].get('conclusion') == 'success')
    name = f'source-{kind}-qualification-{sha}-{identifier}-{attempt}'
    artifacts = read_api(f'actions/runs/{identifier}/artifacts?name={name}&per_page=100')
    require(type(artifacts.get('total_count')) is int and artifacts['total_count'] <= 100)
    matched = [a for a in artifacts['artifacts'] if a.get('name') == name]
    require(len(matched) == 1); artifact = matched[0]
    require(positive_integer(artifact.get('id')) and artifact.get('expired') is False
        and type(artifact.get('size_in_bytes')) is int and 0 < artifact['size_in_bytes'] <= MAXIMUM
        and artifact['workflow_run']['id'] == identifier and artifact['workflow_run']['head_sha'] == sha
        and artifact['workflow_run']['head_branch'] == 'main'
        and re.fullmatch('sha256:[0-9a-f]{64}', artifact.get('digest', '')) is not None)
    raw = read_bytes(f'repos/{REPOSITORY}/actions/artifacts/{artifact["id"]}/zip')
    require(0 < len(raw) <= MAXIMUM and 'sha256:' + hashlib.sha256(raw).hexdigest() == artifact['digest'])
    with zipfile.ZipFile(io.BytesIO(raw)) as archive:
        members = archive.infolist()
        require(len(members) == 1 and members[0].filename == f'{kind}-qualification.json'
                and 0 < members[0].file_size <= MAXIMUM and members[0].flag_bits & 1 == 0
                and (members[0].external_attr >> 16) & 0o170000 in (0, 0o100000))
        receipt = decode(archive.read(members[0]))
    expected = dict(schema=SCHEMA if kind == 'root' else 'forge-platform.protected-swift-qualification/v1', repository=REPOSITORY, source_sha=sha, source_tree=tree,
        workflow=FOUNDATION, workflow_sha=sha, run_id=identifier, run_attempt=attempt,
        qualification='PASS_ROOT_NO_SKIPS' if kind == 'root' else 'PASS_EVERY_SWIFT_FILE')
    require(set(receipt) == set(expected) | {'counts'}
        and all(type(receipt[k]) is type(v) and receipt[k] == v for k, v in expected.items()))
    require(read_api('branches/main')['commit']['sha'] == sha)
    return receipt['counts']
