#!/usr/bin/env python3
"""Riftway's Wine build: Wine (CrossOver 26.3 sources) and FreeType from pinned inputs,
for i386 + x86_64 (WoW64), into work/runtime/phase-2/install. Never installs anything.

Derived from Recall's scripts/build_portable_runtime.py (Apache 2.0,
github.com/AsherJN/recall, at the commit in runtime/sources.lock.json). Differences:
  - no Whisky Libraries.tar.gz: Wine links GnuTLS, inotify and SDL2 from the native
    dependencies built from source (clean-deps) and FreeType from its own build, the
    same libraries the runtime ships;
  - no Soju patches: ncrypt-persisted-keys.patch is GPL-3.0 (docs/RUNTIME-BUILD.md,
    "Licencia del código de Soju"); Soju's source is only read for the libinotify-kqueue
    headers (MIT);
  - paths in the binaries map to /build/riftway;
  - a source tree or build tree made with other patches or flags is rebuilt from scratch.

Recall's patches are read from its pinned clone (work/runtime/recall/patches) and
checked by hash.

  runtime/recipe/wine.py --workspace work/runtime/phase-2 --toolchains work/runtime/toolchains [--jobs N] [--download-only]
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tarfile

ROOT = Path(__file__).resolve().parents[2]
RECALL = ROOT / 'work/runtime/recall'
SOJU = '3a350b32bf906dd2a509b18c642a5a2676de022a'
INPUTS = {
    'wine.tar.gz': ('https://media.codeweavers.com/pub/crossover/source/crossover-sources-26.3.0.tar.gz', 'ac99c8ca4b3848f3e81784135f023df266b61c2345726ea55a50b3e030dd6872'),
    'freetype.tar.gz': ('https://download.savannah.gnu.org/releases/freetype/freetype-2.13.3.tar.gz', '5c3a8e78f7b24c20b25b54ee575d6daa40007a5f4eea2845861c3409b3021747'),
    'soju.tar.gz': ('https://codeload.github.com/BCD1210/soju/tar.gz/' + SOJU, 'e719e417fe92f2600ef4dc3896eb499c0933f05d785918cf7aa8f616cdd75e38'),
    'mono.tar.xz': ('https://github.com/wine-mono/wine-mono/releases/download/wine-mono-10.4.1/wine-mono-10.4.1-x86.tar.xz', 'a16606ef0724202e6a6848ece6e0cbba64d11e2f11aefe744af1d93c6d9f99bb'),
}
# Recall's Wine patches, in the order they apply (some share context).
PATCHES = [
    # Fixed canvas for native full screen, focus and keys when the window goes;
    # carries Soju's Dock icon options (LGPL-2.1+ per Soju's NOTICE).
    ('wine-v1-canvas.patch', '33d57c155761838988d98777a7cddb1b2d00417d07b2e19ca9533221aa9b6f65'),
    # Raw mouse input for the programs listed in WINEMAC_MOUSELOOK.
    ('wine-mouselook.patch', '4e9d4ab2aff6ec38b03100d4802d2764efe1e33caf151cdb4c5de7a8dfa3dfdb'),
    # The ABI of a BOOLEAN in NtQueryDirectoryObject.
    ('wine-portable-directory-boolean.patch', '9c7f811b1eb83d8c322d42509a82c1bcd786f101ce1b26fc1dc0c5badebe619b'),
    # Registry saves from a forked server, Unix library loads outside the
    # virtual-memory lock, per-program DPI, the window driver's activation.
    ('wine-server-registry-save.patch', '8f89556d5daff60c75ae60720ae5125c68021abc244a95df5f6352468323a1a3'),
    ('wine-ntdll-syscall-log.patch', 'beac5bba576e36a0971e6581e812817e87f5cb8c41003c2e4edfe0e8f269623a'),
    ('wine-win32u-display-log.patch', '2387fa06d76891b7b5981473bb06b3b939e2c7569f79b6e3a7cbf12c21297568'),
    ('wine-winemac-activation.patch', '5cce039910a420a16e7d9f8907e17206b1413c6cc4092248548d3d6b29f1138d'),
]
# Riftway's own Wine patches (runtime/patches, LGPL-2.1+ like Wine), after Recall's.
RIFTWAY_PATCHES = [
    # WINE_GAME_MODE_APP: Game Mode from the game's own bundle, in its bottle.
    ('wine-game-mode-app.patch', '46e097629cfa2063fc6d8d2dd0b6a91ce821b13b6d7606f17c4769c7b5a83bbb'),
]
# A string each patch adds, checked in the patched tree: a patch that silently did not
# apply fails the build instead of shipping without it.
APPLIED = {
    'wine-v1-canvas.patch': ('dlls/winemac.drv/window.c', 'WINE_CUSTOM_FRAME'),
    'wine-mouselook.patch': ('dlls/winemac.drv/cocoa_app.m', 'WINEMAC_MOUSELOOK_RAW'),
    'wine-portable-directory-boolean.patch': ('dlls/ntdll/unix/sync.c', 'restart_byte'),
    'wine-server-registry-save.patch': ('server/registry.c', 'WINESERVER_REGISTRY_LOG'),
    'wine-ntdll-syscall-log.patch': ('dlls/ntdll/unix/loader.c', 'game_mode_exec'),
    'wine-win32u-display-log.patch': ('dlls/win32u/sysparams.c', 'WINE_APP_DPI'),
    'wine-winemac-activation.patch': ('dlls/winemac.drv/gdi.c', 'WINEMAC_SCREEN_READBACK'),
    'wine-game-mode-app.patch': ('dlls/ntdll/unix/loader.c', 'WINE_GAME_MODE_APP'),
}
BUILD_PATH = '/build/riftway'
CONFIGURATION = 'riftway-wine-1'


def sha(path):
    with path.open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()


def run(command, **kwargs):
    subprocess.run([str(a) for a in command], check=True, **kwargs)


def fetch(work):
    downloads = work / 'downloads'
    downloads.mkdir(parents=True, exist_ok=True)
    for name, (url, expected) in INPUTS.items():
        target = downloads / name
        if not target.exists():
            part = target.with_suffix(target.suffix + '.part')
            run(['/usr/bin/curl', '--fail', '--location', '--retry', '2',
                 '--proto', '=https', '--proto-redir', '=https', '-o', part, url])
            if sha(part) != expected:
                raise RuntimeError('Downloaded input hash mismatch: ' + name)
            part.rename(target)
        if sha(target) != expected:
            raise RuntimeError('Input hash mismatch: ' + name)


def extract(work, name, prefix=None):
    destination = work / 'sources' / name
    marker = destination / '.extracted.json'
    filename = name + ('.tar.xz' if name == 'mono' else '.tar.gz')
    identity = INPUTS[filename][1]
    if marker.exists():
        if json.loads(marker.read_text())['sha256'] != identity:
            raise RuntimeError('Source identity changed: ' + name)
        return destination
    destination.mkdir(parents=True, exist_ok=True)
    with tarfile.open(work / 'downloads' / filename) as archive:
        members = [m for m in archive.getmembers() if not prefix or m.name.startswith(prefix)]
        archive.extractall(destination, members=members, filter='data')
    marker.write_text(json.dumps({'sha256': identity}) + '\n')
    return destination


def patched_wine(work):
    """The Wine source with PATCHES applied once. Recall's patches cannot be applied
    over a tree that has them, so a tree patched differently is extracted again."""
    patches = []
    for name, expected in PATCHES:
        patch = RECALL / 'patches' / name
        if sha(patch) != expected:
            raise RuntimeError('Recall patch changed: ' + name)
        patches.append(patch)
    for name, expected in RIFTWAY_PATCHES:
        patch = ROOT / 'runtime/patches' / name
        if sha(patch) != expected:
            raise RuntimeError('Riftway patch changed (update its hash): ' + name)
        patches.append(patch)
    marker = work / 'sources/wine-patches.json'
    wanted = json.dumps([p.name for p in patches]) + '\n'
    if (work / 'sources/wine').exists() and not (marker.exists() and marker.read_text() == wanted):
        shutil.rmtree(work / 'sources/wine')
    marker.unlink(missing_ok=True)
    wine = extract(work, 'wine', 'sources/wine/') / 'sources/wine'
    if not (marker.parent / 'wine/.patched').exists():
        # The workspace sits inside Riftway's repository: without a ceiling, git apply
        # takes the patch's paths from that repository's root and skips them all.
        env = dict(os.environ, GIT_CEILING_DIRECTORIES=str(work))
        for patch in patches:
            # Some patches overlap in context that git apply rejects; BSD patch takes them.
            if subprocess.run(['git', 'apply', '--check', str(patch)], cwd=wine, env=env, capture_output=True).returncode == 0:
                run(['git', 'apply', patch], cwd=wine, env=env)
            else:
                run(['/usr/bin/patch', '-N', '-F0', '-p1', '-s', '-i', patch], cwd=wine)
        for patch in patches:
            path, text = APPLIED[patch.name]
            if text not in (wine / path).read_text(errors='replace'):
                raise RuntimeError(f'{patch.name} did not apply ({text} missing from {path})')
        (marker.parent / 'wine/.patched').write_text(wanted)
    marker.write_text(wanted)
    return wine


def build(work, tools, jobs):
    fetch(work)
    wine = patched_wine(work)
    ft = extract(work, 'freetype') / 'freetype-2.13.3'
    soju = extract(work, 'soju') / ('soju-' + SOJU)
    mono = extract(work, 'mono') / 'wine-mono-10.4.1'
    clean = work / 'clean-deps'
    freetype = work / 'freetype-install'

    env = os.environ.copy()
    env.pop('DESTDIR', None)
    # The Command Line Tools clang and the macOS 26.5 SDK, so an Xcode update does
    # not switch compilers under an existing build tree.
    env['DEVELOPER_DIR'] = '/Library/Developer/CommandLineTools'
    env['SDKROOT'] = '/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk'
    env['PATH'] = ':'.join([str(tools / 'bison/bin'), str(tools / 'llvm-mingw-20251216-ucrt-macos-universal/bin'),
                            '/usr/bin', '/bin', '/usr/sbin', '/sbin'])
    env['MACOSX_DEPLOYMENT_TARGET'] = '26.0'
    flags = '-O2 -g0 -ffile-prefix-map=' + str(work) + '=' + BUILD_PATH
    logdir = work / 'build-logs'
    logdir.mkdir(exist_ok=True)

    with (logdir / 'freetype.log').open('w') as log:
        configured = ft / '.riftway-configured'
        if not configured.exists() or configured.read_text() != str(freetype) + '\n' + flags + '\n':
            if (ft / 'config.mk').exists():
                run(['make', 'distclean'], cwd=ft, env=env, stdout=log, stderr=subprocess.STDOUT)
            shutil.rmtree(freetype, ignore_errors=True)
            run(['/usr/bin/arch', '-x86_64', './configure', '--prefix=' + str(freetype),
                 '--without-harfbuzz', '--without-png', '--without-brotli', '--without-bzip2',
                 '--enable-shared', '--disable-static', 'CC=/usr/bin/clang -arch x86_64',
                 'CFLAGS=' + flags], cwd=ft, env=env, stdout=log, stderr=subprocess.STDOUT)
            configured.write_text(str(freetype) + '\n' + flags + '\n')
        run(['make', '-j' + str(jobs)], cwd=ft, env=env, stdout=log, stderr=subprocess.STDOUT)
        run(['make', 'install'], cwd=ft, env=env, stdout=log, stderr=subprocess.STDOUT)
    print('FreeType built from pinned source', flush=True)

    builddir = work / 'wine-build'
    configuration = builddir / '.riftway-configuration'
    signature = CONFIGURATION + '\n' + flags + '\n' + (work / 'sources/wine-patches.json').read_text()
    if builddir.exists() and not (configuration.exists() and configuration.read_text() == signature):
        print('Wine build tree from other patches or flags: building from scratch', flush=True)
        shutil.rmtree(builddir)
    builddir.mkdir(exist_ok=True)
    libs = '-L' + str(freetype / 'lib') + ' -L' + str(clean / 'lib')
    with (logdir / 'wine.log').open('w') as log:
        if not configuration.exists():
            run(['/usr/bin/arch', '-x86_64', wine / 'configure', '--prefix=/usr/local',
                 '--enable-archs=i386,x86_64', '--without-x', '--disable-tests',
                 '--without-gstreamer', '--with-vulkan',
                 'FREETYPE_CFLAGS=-I' + str(freetype / 'include/freetype2'),
                 'FREETYPE_LIBS=-L' + str(freetype / 'lib') + ' -lfreetype',
                 'GNUTLS_CFLAGS=-I' + str(clean / 'include'),
                 'GNUTLS_LIBS=-L' + str(clean / 'lib') + ' -lgnutls',
                 'INOTIFY_CFLAGS=-I' + str(soju / 'third_party/libinotify-kqueue'),
                 'INOTIFY_LIBS=-L' + str(clean / 'lib') + ' -linotify',
                 'SDL2_CFLAGS=-I' + str(clean / 'include/SDL2'),
                 'SDL2_LIBS=-L' + str(clean / 'lib') + ' -lSDL2',
                 'LDFLAGS=-Wl,-headerpad,0x1000 ' + libs, 'CFLAGS=' + flags, 'CROSSCFLAGS=' + flags,
                 'CC=/usr/bin/clang -arch x86_64', 'CXX=/usr/bin/clang++ -arch x86_64'],
                cwd=builddir, env=env, stdout=log, stderr=subprocess.STDOUT)
            configuration.write_text(signature)
        config = builddir / 'include/config.h'
        text = config.read_text()
        for required in ('#define HAVE_SYS_INOTIFY_H 1', '#define SONAME_LIBGNUTLS ', '#define SONAME_LIBFREETYPE ',
                         '#define SONAME_LIBSDL2 '):
            if required not in text:
                raise RuntimeError('Wine lacks a required dependency: ' + required)
        # Wine dlopens these by name: @rpath keeps the runtime relocatable.
        for name, library in [('GNUTLS', 'libgnutls.30.dylib'), ('FREETYPE', 'libfreetype.6.dylib'),
                              ('VULKAN', 'libMoltenVK.dylib'), ('MOLTENVK', 'libMoltenVK.dylib'),
                              ('SDL2', 'libSDL2-2.0.0.dylib')]:
            text = re.sub(r'#define SONAME_LIB' + name + r' .*',
                          '#define SONAME_LIB' + name + ' "@rpath/' + library + '"', text)
        if config.read_text() != text:
            config.write_text(text)
        print('Building Wine (two architectures)', flush=True)
        # PE modules take their own flags, so Windows assertion strings carry no host paths.
        run(['make', '-j' + str(jobs), 'LDFLAGS=-Wl,-headerpad,0x1000 ' + libs,
             'i386_CFLAGS=' + flags, 'x86_64_CFLAGS=' + flags],
            cwd=builddir, env=env, stdout=log, stderr=subprocess.STDOUT)
        shutil.rmtree(work / 'install', ignore_errors=True)
        run(['make', 'install', 'DESTDIR=' + str(work / 'install')], cwd=builddir,
            env=env, stdout=log, stderr=subprocess.STDOUT)
    installed = work / 'install/usr/local'
    shutil.copytree(mono, installed / 'share/wine/mono/wine-mono-10.4.1', dirs_exist_ok=True)
    record = {'recipe': 'runtime/recipe/wine.py', 'derived_from': 'Recall scripts/build_portable_runtime.py',
              'inputs': {n: {'url': v[0], 'sha256': v[1]} for n, v in INPUTS.items()},
              'recall_patches': dict(PATCHES), 'riftway_patches': dict(RIFTWAY_PATCHES), 'soju_patches': [],
              'gnutls_header_sha256': sha(clean / 'include/gnutls/gnutls.h'),
              'build_path': BUILD_PATH, 'minimum_macos': '26.0',
              'without_gstreamer': True, 'with_vulkan': True, 'with_sdl2': True,
              'native_linker_header_padding': '0x1000'}
    (work / 'wine-build-proof.json').write_text(json.dumps(record, indent=2) + '\n')
    print('Wine build complete; nothing installed on this Mac', flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--workspace', type=Path, required=True)
    parser.add_argument('--toolchains', type=Path, required=True)
    parser.add_argument('--download-only', action='store_true')
    parser.add_argument('--jobs', type=int, choices=range(1, 33), default=2)
    args = parser.parse_args()
    work = args.workspace.resolve()
    if work.name != 'phase-2':
        parser.error('Use the phase-2 workspace')
    work.mkdir(parents=True, exist_ok=True)
    if args.download_only:
        fetch(work)
    else:
        for needed in ('include/gnutls/gnutls.h', 'include/SDL2/SDL.h', 'lib/libgnutls.30.dylib', 'lib/libinotify.0.dylib'):
            if not (work / 'clean-deps' / needed).is_file():
                parser.error('Build the native dependencies first (runtime/build.py deps): missing ' + needed)
        if shutil.disk_usage(work.parent).free < 12 * 2**30:
            parser.error('A Wine build needs 12 GiB free')
        build(work, args.toolchains.resolve(), args.jobs)
