#!/usr/bin/env python3
"""Riftway runtime build, phase 2: Riftway's own recipe (runtime/recipe/), derived
from Recall's, without Whisky's libraries, MetalFX or Soju's GPL-3.0 patch.

Everything lives under work/runtime/ (git-ignored):

  toolchains/   llvm-mingw, LLVM 15 x86_64, bison, a Python venv with meson and ninja
  recall/       Recall at the commit pinned in runtime/sources.lock.json (its patches,
                and its native dependency script)
  phase-2/      the build workspace

  runtime/build.py tools     fetch and verify toolchains, clone Recall
  runtime/build.py check     report what is missing
  runtime/build.py fetch     download the pinned sources (Wine, FreeType, Soju, Mono)
  runtime/build.py deps      native dependencies (GnuTLS, SDL2, MoltenVK…), Recall's script
  runtime/build.py wine      Wine for i386 + x86_64 (WoW64), runtime/recipe/wine.py
  runtime/build.py dxmt      DXMT against the Wine build, runtime/recipe/dxmt.py
  runtime/build.py media     GLib + GStreamer + winegstreamer (video and audio decoding)
  runtime/build.py smoke VERSION   fresh bottle on work/runtime/artifacts/VERSION
                                   (runtime/assemble.py makes it): Windows version,
                                   no Z: drive, WoW64 and a D3D11 draw through DXMT

Nothing here touches Homebrew, CrossOver or any installed runtime.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile

ROOT = Path(__file__).resolve().parents[1]
LOCK = json.loads((ROOT / 'runtime/sources.lock.json').read_text())
WORK = ROOT / 'work/runtime'
TOOLS = WORK / 'toolchains'
DOWNLOADS = WORK / 'downloads'
RECALL = WORK / 'recall'
# Another workspace (RIFTWAY_PHASE2=…/phase-2), to check that two clean builds match.
PHASE2 = Path(os.environ.get('RIFTWAY_PHASE2') or WORK / 'phase-2').resolve()
CLT_SDK = Path('/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk')


def run(*args, **kwargs):
    print('+', ' '.join(str(a) for a in args), flush=True)
    subprocess.run([str(a) for a in args], check=True, **kwargs)


def sha256(path):
    with path.open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()


def fetch(spec, name):
    """Downloads `spec['url']` once and checks its SHA-256 (or, for an input with
    no published digest, its size, and reports the hash to pin)."""
    DOWNLOADS.mkdir(parents=True, exist_ok=True)
    target = DOWNLOADS / spec['url'].rsplit('/', 1)[1].replace('%2B', '+')
    if not target.exists():
        part = target.with_name(target.name + '.part')
        run('/usr/bin/curl', '--fail', '--location', '--retry', '2', '--proto', '=https',
            '--proto-redir', '=https', '-o', part, spec['url'])
        part.rename(target)
    digest = sha256(target)
    if spec.get('sha256'):
        if digest != spec['sha256']:
            raise SystemExit(f'{name}: SHA-256 mismatch ({digest}); delete {target} and retry')
    else:
        if target.stat().st_size != spec['bytes']:
            raise SystemExit(f'{name}: size {target.stat().st_size} differs from the release asset ({spec["bytes"]})')
        print(f'{name}: no published digest; pin this in runtime/sources.lock.json: "sha256": "{digest}"')
    return target


def extract(archive, destination, directory):
    if (destination / directory).is_dir():
        return destination / directory
    destination.mkdir(parents=True, exist_ok=True)
    print(f'Extracting {archive.name}…', flush=True)
    with tarfile.open(archive) as t:
        t.extractall(destination, filter='tar')  # toolchains carry symlinks inside their tree
    return destination / directory


def tools(_):
    TOOLS.mkdir(parents=True, exist_ok=True)
    chains = LOCK['toolchains']
    for name in ('llvm-mingw', 'llvm-15'):
        spec = chains[name]
        extract(fetch(spec, name), TOOLS, spec['directory'])

    bison = TOOLS / 'bison/bin/bison'
    if not bison.exists():
        spec = chains['bison']
        source = extract(fetch(spec, 'bison'), WORK / 'tool-sources', spec['directory'])
        run('./configure', '--prefix=' + str(TOOLS / 'bison'), cwd=source)
        run('make', f'-j{os.cpu_count()}', cwd=source)
        run('make', 'install', cwd=source)

    venv = TOOLS / 'python'
    if not (venv / 'bin/meson').exists():
        run(sys.executable, '-m', 'venv', venv)
        run(venv / 'bin/pip', 'install', '--quiet', *chains['python']['packages'])

    recall = LOCK['recall']
    if not (RECALL / '.git').exists():
        run('git', 'clone', '--quiet', recall['repository'], RECALL)
    head = subprocess.run(['git', 'rev-parse', 'HEAD'], cwd=RECALL, capture_output=True, text=True).stdout.strip()
    if head != recall['commit']:
        run('git', 'checkout', '--quiet', '--detach', recall['commit'], cwd=RECALL)
    # Deviation (sources.lock.json): allow more than four parallel jobs.
    for script in ('build_portable_dependencies.py',):
        path = RECALL / 'scripts' / script
        text = path.read_text()
        if 'range(1,5)' in text or 'range(1, 5)' in text:
            path.write_text(text.replace('range(1,5)', 'range(1,33)').replace('range(1, 5)', 'range(1, 33)'))
    # Recall's assembler reads toolchains from <recall>/runtime/toolchains.
    link = RECALL / 'runtime/toolchains'
    link.parent.mkdir(exist_ok=True)
    if not link.is_symlink():
        link.symlink_to(TOOLS)
    check(None)


def check(_):
    problems = []
    def need(ok, what):
        print(('  ok   ' if ok else '  FALTA ') + what)
        if not ok: problems.append(what)

    print('Herramientas del runtime:')
    chains = LOCK['toolchains']
    need((TOOLS / chains['llvm-mingw']['directory'] / 'bin/x86_64-w64-mingw32-clang').exists(), 'llvm-mingw 20251216')
    need((TOOLS / chains['llvm-15']['directory'] / 'bin/clang').exists(), 'LLVM 15.0.7 x86_64')
    need((TOOLS / 'bison/bin/bison').exists(), 'bison 3.8.2')
    need((TOOLS / 'python/bin/meson').exists() and (TOOLS / 'python/bin/ninja').exists(), 'meson + ninja (venv)')
    apple = LOCK['apple']
    need(CLT_SDK.is_dir() and str(CLT_SDK) == apple['sdk'], 'Command Line Tools con MacOSX26.5.sdk')
    clt = subprocess.run(['/usr/sbin/pkgutil', '--pkg-info=com.apple.pkg.CLTools_Executables'],
                         capture_output=True, text=True).stdout
    need(f"version: {apple['command_line_tools']}" in clt, f"Command Line Tools {apple['command_line_tools']}")
    need(subprocess.run(['/usr/bin/arch', '-x86_64', '/usr/bin/true']).returncode == 0, 'Rosetta 2')
    pinned = apple['metal']
    metal_env = {k: v for k, v in os.environ.items() if k != 'SDKROOT'} | {'DEVELOPER_DIR': pinned['developer_dir']}
    xcode = subprocess.run(['/usr/bin/xcodebuild', '-version'], env=metal_env, capture_output=True, text=True)
    need(xcode.returncode == 0 and f"Build version {pinned['xcode_build']}" in xcode.stdout,
         f"Xcode {pinned['xcode']} ({pinned['xcode_build']}) en {pinned['developer_dir']}, para los shaders de DXMT")
    metal = subprocess.run(['/usr/bin/xcrun', 'metal', '--version'], env=metal_env, capture_output=True, text=True)
    need(metal.returncode == 0 and metal.stdout.startswith(pinned['metal_version']),
         f"Metal Toolchain {pinned['metal_toolchain']} de ese Xcode (DEVELOPER_DIR={pinned['developer_dir']} "
         'xcodebuild -downloadComponent MetalToolchain)')
    need((RECALL / '.git').exists(), f'Recall en {LOCK["recall"]["commit"][:8]}')
    need(' ' not in str(WORK), 'workspace sin espacios')
    if problems:
        raise SystemExit(f'{len(problems)} pendiente(s)')


def smoke(version):
    runtime = WORK / 'artifacts' / version
    if not (runtime / 'bin/wine').exists():
        raise SystemExit(f'No runtime at {runtime}; run runtime/assemble.py --version {version}')
    mingw = TOOLS / LOCK['toolchains']['llvm-mingw']['directory'] / 'bin'
    probes = WORK / 'probes'
    probes.mkdir(exist_ok=True)
    run(mingw / 'x86_64-w64-mingw32-clang', '-O2', '-Wall', ROOT / 'runtime/probes/d3d11_probe.c',
        '-ld3d11', '-ldxgi', '-ld3dcompiler', '-o', probes / 'd3d11_probe.exe')
    run(mingw / 'i686-w64-mingw32-clang', '-O2', '-Wall', ROOT / 'runtime/probes/wow64_probe.c', '-o', probes / 'wow64_probe.exe')
    run(mingw / 'x86_64-w64-mingw32-clang', '-O2', '-Wall', '-municode', ROOT / 'runtime/probes/media_probe.c',
        '-lmfplat', '-lmfreadwrite', '-lmfuuid', '-lole32', '-o', probes / 'media_probe.exe')
    run('swift', 'build', '--product', 'riftway', cwd=ROOT)
    cli = ROOT / '.build/debug/riftway'
    bottle = WORK / 'test-bottles' / ('smoke-' + version)
    if bottle.exists():
        shutil.rmtree(bottle)
    run(cli, 'bottle-create', '--runtime', runtime, '--at', bottle, '--name', 'Smoke ' + version)
    (bottle / 'prefix/drive_c/probes').mkdir()
    for exe in ('d3d11_probe.exe', 'wow64_probe.exe', 'media_probe.exe'):
        shutil.copy2(probes / exe, bottle / 'prefix/drive_c/probes' / exe)
    # 2 s of 0xCC6633 in H.264 (Main) with a 440 Hz AAC tone, 320x240.
    shutil.copy2(ROOT / 'runtime/probes/clip.mp4', bottle / 'prefix/drive_c/probes/clip.mp4')

    def wine(*args):
        out = subprocess.run([str(cli), 'bottle-wine', '--runtime', str(runtime), '--at', str(bottle), '--', *args],
                             capture_output=True, text=True)
        return out.returncode, out.stdout.replace('\r', '').strip()

    results = {}
    _, ver = wine('cmd.exe', '/c', 'ver')
    results['windows'] = ver
    results['z_drive_removed'] = not (bottle / 'prefix/dosdevices/z:').exists()
    for name, args in (('wow64_probe', []), ('d3d11_probe', []), ('media_probe', ['C:\\probes\\clip.mp4'])):
        code, out = wine('C:\\probes\\' + name + '.exe', *args)
        results[name] = json.loads(out.splitlines()[-1]) if code == 0 and out else {'exit': code, 'output': out}
    print(json.dumps(results, indent=2))
    ok = ('Windows' in ver and results['z_drive_removed'] and results['wow64_probe'].get('wow64') is True
          and results['d3d11_probe'].get('ok') is True and results['media_probe'].get('ok') is True)
    (bottle / 'smoke.json').write_text(json.dumps(results, indent=2) + '\n')
    raise SystemExit(0 if ok else 'Smoke test failed')


def recall_script(name, *extra):
    run(sys.executable, RECALL / 'scripts' / name, '--workspace', PHASE2, *extra, cwd=RECALL)


def recipe(name, *extra):
    run(sys.executable, ROOT / 'runtime/recipe' / name, '--workspace', PHASE2, '--toolchains', TOOLS, *extra)


def jobs():
    return str(min(32, os.cpu_count() or 4))


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('step', choices=['tools', 'check', 'fetch', 'deps', 'wine', 'dxmt', 'media', 'smoke'])
    parser.add_argument('version', nargs='?', help='runtime version, for smoke')
    parsed = parser.parse_args()
    step = parsed.step
    if step == 'tools':
        tools(None)
    elif step == 'check':
        check(None)
    elif step == 'fetch':
        recipe('wine.py', '--download-only')
    elif step == 'deps':
        recall_script('build_portable_dependencies.py', '--jobs', jobs())
    elif step == 'wine':
        recipe('wine.py', '--jobs', jobs())
    elif step == 'media':
        run(sys.executable, ROOT / 'runtime/media.py', jobs())
    elif step == 'smoke':
        if not parsed.version:
            parser.error('smoke needs the runtime version (work/runtime/artifacts/<version>)')
        smoke(parsed.version)
    elif step == 'dxmt':
        recipe('dxmt.py', '--jobs', jobs())


if __name__ == '__main__':
    main()
