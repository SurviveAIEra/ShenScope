#!/usr/bin/env python3
"""Read-only check for legacy licenses in locally publishable Git history."""
from collections import defaultdict
from pathlib import Path
import json
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def git(*args):
    return subprocess.check_output(['git', *args], cwd=ROOT, text=True).strip()


def license_kind(text):
    normalized = text.lstrip()
    if normalized.startswith('ShenScope Contribution-Only License\nVersion 1.0\n'):
        return 'ShenScope-Contribution-Only-1.0'
    if normalized.startswith('Apache License'):
        return 'Apache-2.0'
    return 'other-or-unrecognized'


def main():
    refs = git('for-each-ref', '--format=%(refname)', 'refs/heads', 'refs/tags').splitlines()
    if not refs:
        raise RuntimeError('No local branch or tag found; cannot establish publication scope')
    commits = git('rev-list', *refs).splitlines()
    groups = defaultdict(list)
    blobs = {}
    for commit in commits:
        blob = git('rev-parse', '--verify', commit + ':LICENSE')
        if blob not in blobs:
            blobs[blob] = license_kind(git('cat-file', '-p', blob))
        groups[blobs[blob]].append(commit)
    head = git('rev-parse', '--verify', 'HEAD^{commit}')
    current_kind = license_kind(git('show', head + ':LICENSE'))
    incompatible = sum(len(values) for kind, values in groups.items()
                       if kind != 'ShenScope-Contribution-Only-1.0')
    report = {
        'head': head,
        'head_license': current_kind,
        'local_refs_checked': refs,
        'reachable_commits_checked': len(commits),
        'license_groups': {kind: {'commits': len(values), 'example_commits': values[:3]}
                           for kind, values in sorted(groups.items())},
        'legacy_or_unrecognized_license_commits': incompatible,
        'local_full_history_ready_for_restricted_publication': incompatible == 0,
        'scope': 'Local heads/tags and root LICENSE only; no changes performed',
        'not_checked': ['legal validity', 'prior grants', 'GitHub visibility/cache',
                        'unreachable objects', 'third-party distribution obligations'],
    }
    print(json.dumps(report, indent=2))
    return 1 if incompatible else 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        print('Publication license audit could not complete: ' + str(error), file=sys.stderr)
        sys.exit(2)
