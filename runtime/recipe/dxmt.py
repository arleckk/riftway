#!/usr/bin/env python3
"""Riftway's DXMT build (D3D10/11 on Metal) against the Wine build tree, into
work/runtime/phase-2/dxmt-install.

Derived from Recall's scripts/build_portable_dxmt.py (Apache 2.0,
github.com/AsherJN/recall, at the commit in runtime/sources.lock.json). Differences:
  - no MetalFX upscaling: without dxmt-metalfx-upscaling.patch and with NVAPI and
    NGX off, nothing reports an NVIDIA GPU or loads DLSS, and there is no
    nvngx.dll to sign (no signing certificate);
  - the source is reset to the pinned commit before patching, so a tree patched
    with another set is never built;
  - only DXMT's modules are installed (the diagnostic programs stay out).

  runtime/recipe/dxmt.py --workspace work/runtime/phase-2 --toolchains work/runtime/toolchains [--jobs N]
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[2]
RECALL = ROOT / 'work/runtime/recall'
REPOSITORY = 'https://github.com/NerRobDog/dxmt'
BASE = 'c5dc3a0dfe9108e667da43de871324bd298c9c02'
HEADERS = '9df86f2341616ef1888ae59919feaa6d4fad693d'
PATCHES = [
    # Full screen canvas, presentation, shader and pipeline caches (dxmt.conf, env).
    ('dxmt-v1-private.patch', '5afcbde9512381c37e975450d08f7fd3cef1e8755739f1f5b4ae8f1563de5199'),
    # Lossless compression of UAV render targets until first use, CPU/GPU waits, frame pacing.
    ('dxmt-v1-performance.patch', 'b119feb670a3e2ffe656159118e99a75abc5b9a8097e77096c512a01b81861f2'),
    # metal/metallib through portable_metal.py, so no host paths are embedded.
    ('dxmt-portable-metal.patch', '3b9d6a3248c62e8eb3b623fbd3f5c4939d6973dfa366e827b7d25e814428745d'),
]
WRAPPER_SHA256 = 'd6666237dc9827c9c68a94ca00d1d4c528cccab75b4655132a1339e5d3155505'


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(*args, **kwargs):
    return subprocess.run([str(a) for a in args], check=True, **kwargs)


def git(source, *args):
    return subprocess.check_output(['git', '-C', str(source), *args], text=True).strip()


def build(work, tools, jobs):
    source, builddir, install = work / 'dxmt-source', work / 'dxmt-build', work / 'dxmt-install'
    if not source.exists():
        run('git', 'clone', '--no-checkout', REPOSITORY, source)
    # A clean tree at the pinned commit, whatever a previous recipe applied.
    run('git', '-C', source, 'checkout', '--quiet', '--force', '--detach', BASE)
    run('git', '-C', source, 'clean', '-fdq')
    run('git', '-C', source, 'submodule', 'update', '--init', '--recursive', '--force')
    run('git', '-C', source, 'submodule', 'foreach', '--recursive', 'git clean -fdq')
    if git(source / 'include/native/directx', 'rev-parse', 'HEAD') != HEADERS:
        raise ValueError('DirectX header identity mismatch')
    applied = {}
    for name, expected in PATCHES:
        patch = RECALL / 'patches' / name
        if sha(patch) != expected:
            raise ValueError('Recall patch changed: ' + name)
        run('git', 'apply', patch, cwd=source)
        applied[name] = sha(patch)
    wrapper = source / 'portable_metal.py'
    if sha(RECALL / 'scripts/portable_metal.py') != WRAPPER_SHA256:
        raise ValueError('Recall script changed: portable_metal.py')
    shutil.copy2(RECALL / 'scripts/portable_metal.py', wrapper)
    wrapper.chmod(0o755)

    env = os.environ.copy()
    env.pop('DESTDIR', None)
    # PE modules carry the pinned date instead of the build's.
    env['SOURCE_DATE_EPOCH'] = str(json.loads((ROOT / 'runtime/sources.lock.json').read_text())['source_date_epoch']['value'])
    env['PATH'] = ':'.join([str(tools / 'llvm-mingw-20251216-ucrt-macos-universal/bin'), str(tools / 'python/bin'),
                            '/usr/bin', '/bin', '/usr/sbin', '/sbin'])
    meson = tools / 'python/bin/meson'
    # meson does not relink when only the date changes: a tree built with another starts over.
    stamp = builddir / '.riftway-source-date-epoch'
    if builddir.exists() and not (stamp.exists() and stamp.read_text() == env['SOURCE_DATE_EPOCH']):
        shutil.rmtree(builddir)
    setup = [meson, 'setup', builddir, source, '--cross-file', source / 'build-win64.txt', '--buildtype=release',
             '--prefix', install, '--strip', '-Dnative_llvm_path=' + str(tools / 'clang+llvm-15.0.7-x86_64-apple-darwin21.0'),
             '-Dwine_build_path=' + str(work / 'wine-build'), '-Denable_tests=false', '-Denable_nvapi=false',
             '-Denable_nvngx=false', '-Denable_d3d12=false']
    if (builddir / 'meson-private/coredata.dat').exists():
        setup.append('--reconfigure')
    run(*setup, env=env)
    stamp.write_text(env['SOURCE_DATE_EPOCH'])
    run(meson, 'compile', '-C', builddir, '-j', jobs, env=env)
    # A fresh install, so modules of an earlier build (NVAPI, NGX) never linger.
    shutil.rmtree(install, ignore_errors=True)
    run(meson, 'install', '-C', builddir, '--no-rebuild', env=env)
    for program in install.rglob('*.exe'):
        program.unlink()
    files = {str(p.relative_to(install)): sha(p) for p in sorted(install.rglob('*')) if p.is_file()}
    (work / 'dxmt-build-proof.json').write_text(json.dumps({
        'recipe': 'runtime/recipe/dxmt.py', 'derived_from': 'Recall scripts/build_portable_dxmt.py',
        'repository': REPOSITORY, 'base': BASE, 'headers': HEADERS, 'patches': applied,
        'portable_metal_wrapper_sha256': sha(wrapper), 'metalfx': False, 'nvapi': False, 'nvngx': False,
        'files': files}, indent=2) + '\n')
    print('DXMT build complete', flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--workspace', type=Path, required=True)
    parser.add_argument('--toolchains', type=Path, required=True)
    parser.add_argument('--jobs', type=int, choices=range(1, 33), default=2)
    args = parser.parse_args()
    work = args.workspace.resolve()
    if not (work / 'wine-build/.riftway-configuration').exists():
        parser.error('Build Wine first (runtime/build.py wine)')
    build(work, args.toolchains.resolve(), str(args.jobs))
