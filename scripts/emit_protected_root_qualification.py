#!/usr/bin/env python3
"""Retain actual hosted root source traces, not installed qualification."""
from __future__ import annotations
import json
import os
from pathlib import Path
import subprocess
import sys
import argparse
import re
from scripts import check_managed_installer_python_coverage as coverage
from scripts.protected_root_qualification import REPOSITORY, FOUNDATION, SCHEMA, require, git, decode


def qualify(root, env):
    require(env.get('GITHUB_ACTIONS') == 'true' and env.get('GITHUB_WORKFLOW') == 'Foundation validation'
        and env.get('GITHUB_REPOSITORY') == REPOSITORY and env.get('GITHUB_EVENT_NAME') == 'push'
        and env.get('GITHUB_REF') == 'refs/heads/main' and env.get('GITHUB_REF_PROTECTED') == 'true')
    sha = git(root, 'rev-parse', 'HEAD'); tree = git(root, 'rev-parse', 'HEAD^{tree}')
    require(sha == env.get('GITHUB_SHA') == env.get('GITHUB_WORKFLOW_SHA')
        and not git(root, 'status', '--porcelain', '--untracked-files=all'))
    require(all(re.fullmatch('[1-9][0-9]*', env.get(key,'')) is not None for key in ('GITHUB_RUN_ID','GITHUB_RUN_ATTEMPT')))
    run = int(env['GITHUB_RUN_ID']); attempt = int(env['GITHUB_RUN_ATTEMPT'])
    before = coverage._source_hashes()
    result = subprocess.run(['sudo', '-n', sys.executable, str(root/'scripts/check_managed_installer_python_coverage.py'),
        '--root-private-qualification-counts'], cwd=root, stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE, check=True, timeout=300)
    counts = decode(result.stdout); coverage._require_source_snapshot(before)
    # Same strict decoder as ordinary qualification; no counts are minted here.
    coverage._merge_root_counts({}, before, counts)
    require(git(root, 'rev-parse', 'HEAD') == sha and git(root, 'rev-parse', 'HEAD^{tree}') == tree
        and not git(root, 'status', '--porcelain', '--untracked-files=all'))
    return dict(schema=SCHEMA, repository=REPOSITORY, source_sha=sha, source_tree=tree,
        workflow=FOUNDATION, workflow_sha=sha, run_id=run, run_attempt=attempt,
        qualification='PASS_ROOT_NO_SKIPS', counts=counts)


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--output', type=Path, required=True);args=parser.parse_args()
    root=Path(__file__).resolve().parents[1]
    value=qualify(root, os.environ)
    # RUNNER_TEMP only, no checkout mutation and no arbitrary receipt admission.
    temp=Path(os.environ['RUNNER_TEMP']).resolve(); require(args.output.is_absolute() and args.output.parent.resolve()==temp)
    raw=(json.dumps(value, sort_keys=True, separators=(',', ':'), allow_nan=False)+'\n').encode()
    directory=os.open(temp,os.O_RDONLY|os.O_DIRECTORY|getattr(os,'O_NOFOLLOW_ANY',os.O_NOFOLLOW))
    try:
        before=os.fstat(directory)
        fd=os.open(args.output.name,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600,dir_fd=directory)
        try:
            require(os.write(fd,raw)==len(raw));os.fsync(fd)
        finally:os.close(fd)
        os.fsync(directory)
        after=temp.lstat();require((before.st_dev,before.st_ino)==(after.st_dev,after.st_ino))
    finally:os.close(directory)
    print('PROTECTED_ROOT_SOURCE_QUALIFICATION=PASS')

if __name__=='__main__': main()
