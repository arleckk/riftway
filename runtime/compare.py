#!/usr/bin/env python3
"""Compares two runtime builds file by file, from their manifests (runtime.json).

  runtime/compare.py A B     A and B: runtime folders or their runtime.json

Prints the files that differ or exist on one side only, grouped by folder, and exits
with 1 if there are any. Two reproducible builds of the same version and inputs (on
this Mac, another workspace or a CI runner) list nothing.
"""
import argparse
from collections import Counter
import json
from pathlib import Path


def manifest(path):
    path = Path(path)
    if path.is_dir():
        path = path / 'runtime.json'
    return json.loads(path.read_text())


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('a')
    parser.add_argument('b')
    args = parser.parse_args()
    a, b = manifest(args.a), manifest(args.b)
    if a['version'] != b['version']:
        print(f"note: versions differ ({a['version']} / {b['version']}); files that embed it will differ")
    fa, fb = a['files'], b['files']
    differ = sorted(p for p in fa.keys() & fb.keys() if fa[p]['sha256'] != fb[p]['sha256'])
    only_a, only_b = sorted(fa.keys() - fb.keys()), sorted(fb.keys() - fa.keys())
    same = len(fa.keys() & fb.keys()) - len(differ)
    print(f'{same} identical, {len(differ)} different, {len(only_a)} only in A, {len(only_b)} only in B')
    for title, paths in (('different', differ), ('only in A', only_a), ('only in B', only_b)):
        if not paths:
            continue
        folders = Counter(str(Path(p).parent) for p in paths)
        print(f'\n{title}: ' + ', '.join(f'{folder} ({n})' for folder, n in folders.most_common()))
        for p in paths[:40]:
            print('  ' + p)
        if len(paths) > 40:
            print(f'  … {len(paths) - 40} more')
    raise SystemExit(1 if differ or only_a or only_b else 0)


if __name__ == '__main__':
    main()
