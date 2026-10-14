#!/usr/bin/env python3
"""Assemble, sign and package a versioned Riftway runtime from the phase-2 builds.

Derived from Recall's scripts/assemble_portable_runtime.py (Apache 2.0,
github.com/AsherJN/recall). Differences:
  - Wine and DXMT come from Riftway's recipe (runtime/recipe/): no Whisky
    libraries, no MetalFX (no NVAPI, NGX or D3D12 stand-ins), no GPL-3.0 code;
  - no Apple component (libd3dshared.dylib): D3DMetal is never redistributed;
  - config/dxmt.conf is generic: each bottle writes its own from the game profile;
  - ad hoc signing (identity "-") is supported, for builds without a Developer ID;
  - no Game Mode bundle yet (Recall's ntdll patch names it after one executable);
  - Wine Gecko is included (programs that embed a web view, such as .NET
    launchers, need it; Recall's games don't), pinned to the hashes in Wine's
    own source (dlls/appwiz.cpl/addons.c);
  - video and audio decoding: winegstreamer, GLib and GStreamer with macOS's
    decoders (runtime/media.py), in lib/gstreamer-1.0 and libexec/gstreamer-1.0;
  - the manifest says riftway_runtime_schema.

  runtime/assemble.py --version rw-0.1.0 [--identity "Developer ID Application: …"]
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tarfile
from concurrent.futures import ThreadPoolExecutor

ROOT = Path(__file__).resolve().parents[1]
WORK = ROOT / 'work/runtime'
# Another workspace (RIFTWAY_PHASE2=…/phase-2), to check that two clean builds match.
PHASE2 = Path(os.environ.get('RIFTWAY_PHASE2') or WORK / 'phase-2').resolve()
TOOLS = WORK / 'toolchains'
MINGW = TOOLS / 'llvm-mingw-20251216-ucrt-macos-universal'
SOJU = '3a350b32bf906dd2a509b18c642a5a2676de022a'
MEDIA = PHASE2 / 'media-stage/riftway-media'
# A string each Wine patch adds to a module (runtime/recipe/wine.py, APPLIED).
PATCH_MARKERS = [
    ('lib/wine/x86_64-unix/winemac.so', 'WINE_CUSTOM_FRAME'),          # wine-v1-canvas
    ('lib/wine/x86_64-unix/winemac.so', 'WINEMAC_MOUSELOOK_RAW'),      # wine-mouselook
    ('bin/wineserver', 'WINESERVER_REGISTRY_LOG'),                     # wine-server-registry-save
    ('lib/wine/x86_64-unix/ntdll.so', 'WINE_SYSCALL_LOG'),             # wine-ntdll-syscall-log
    ('lib/wine/x86_64-unix/win32u.so', 'WINE_APP_DPI'),                # wine-win32u-display-log
    ('lib/wine/x86_64-unix/winemac.so', 'WINEMAC_SCREEN_READBACK'),    # wine-winemac-activation
    ('lib/wine/x86_64-unix/ntdll.so', 'WINE_GAME_MODE_APP'),           # wine-game-mode-app (Riftway)
    ('lib/wine/x86_64-unix/ntdll.so', 'WINEDLLPATH_FIRST'),            # wine-dll-path-first (Riftway)
    ('lib/wine/x86_64-windows/winegstreamer.dll', 'cannot hold NV12 frames'),     # wine-video-memory-fallback (Riftway)
    ('lib/wine/x86_64-windows/mfreadwrite.dll', 'delivering them in memory'),     # wine-video-memory-fallback (Riftway)
    ('lib/wine/x86_64-windows/winegstreamer.dll', 'Offering NV12 output format last'),  # wine-h264-nv12-last (Riftway)
    ('lib/wine/x86_64-windows/kernelbase.dll', 'RIFTWAY_APPEND_ARGS: appending'),      # wine-append-args (Riftway)
    ('lib/wine/i386-windows/kernelbase.dll', 'RIFTWAY_APPEND_ARGS: appending'),        # wine-append-args (Riftway)
]
PROOFS = ['wine-build-proof.json', 'dxmt-build-proof.json', 'native-build-proof.json', 'media-build-proof.json']
MONO_SOURCE_SHA = '128e335396689e466dff5e1aa0770a714dbe3d16397fc4ddbb8a80999c67323b'
MONO_SOURCE_URL = 'https://github.com/wine-mono/wine-mono/releases/download/wine-mono-10.4.1/wine-mono-10.4.1-src.tar.xz'
GECKO = {  # Wine's dlls/appwiz.cpl/addons.c, GECKO_VERSION 2.47.4
    'wine-gecko-2.47.4-x86.msi': '26cecc47706b091908f7f814bddb074c61beb8063318e9efc5a7f789857793d6',
    'wine-gecko-2.47.4-x86_64.msi': 'e590b7d988a32d6aa4cf1d8aa3aa3d33766fdd4cf4c89c2dcc2095ecb28d066f',
}
GECKO_URL = 'https://dl.winehq.org/wine/wine-gecko/2.47.4/'
GECKO_SOURCE_URL = GECKO_URL + 'wine-gecko-2.47.4.tar.xz'
MINIMUM_MACOS = '26.0'
ENTITLEMENTS = [
    'com.apple.security.cs.allow-jit',
    'com.apple.security.cs.allow-unsigned-executable-memory',
    'com.apple.security.cs.disable-executable-page-protection',
    'com.apple.security.cs.disable-library-validation',
    'com.apple.security.device.audio-input',
]
GENERIC_DXMT_CONF = """# Riftway: generic DXMT configuration.
# Each bottle writes its own dxmt.conf (C:\\ProgramData\\Riftway\\dxmt.conf) from the
# game's profile; this file only documents the format. Sections are per executable:
#
# [Game.exe]
# d3d11.preferredMaxFrameRate = 0
"""


def run(*args, **kwargs):
    return subprocess.run([str(a) for a in args], check=True, **kwargs)


def sha(p):
    with p.open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()


def macho(p):
    if p.is_symlink() or not p.is_file():
        return False
    with p.open('rb') as f:
        return f.read(4) in (b'\xcf\xfa\xed\xfe', b'\xce\xfa\xed\xfe', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca')


def links(p):
    text = subprocess.check_output(['otool', '-L', str(p)], text=True)
    return [line.strip().split(' (')[0] for line in text.splitlines()[1:]]


def rpaths(p):
    text = subprocess.check_output(['otool', '-l', str(p)], text=True)
    return re.findall(r'cmd LC_RPATH\n\s+cmdsize \d+\n\s+path (.*?) \(offset', text)


def normalize_uuid(p):
    """Sets a thin 64-bit Mach-O file's LC_UUID to a name-based UUID of its content
    (signature removed, LC_UUID zeroed), so the same code gets the same UUID."""
    data = p.read_bytes()
    if data[:4] != b'\xcf\xfa\xed\xfe':
        return  # universal (MoltenVK's prebuilt library): left as shipped upstream
    if b'\xfa\xde\x0c\xc0' in data:
        run('codesign', '--remove-signature', p, stderr=subprocess.DEVNULL)
        data = p.read_bytes()
    offset = 32
    for _ in range(int.from_bytes(data[16:20], 'little')):
        command, size = int.from_bytes(data[offset:offset + 4], 'little'), int.from_bytes(data[offset + 4:offset + 8], 'little')
        if command == 0x1b:  # LC_UUID
            at = offset + 8
            zeroed = data[:at] + bytes(16) + data[at + 16:]
            uuid = bytearray(hashlib.sha256(zeroed).digest()[:16])
            uuid[6] = (uuid[6] & 0x0f) | 0x50
            uuid[8] = (uuid[8] & 0x3f) | 0x80
            p.write_bytes(data[:at] + bytes(uuid) + data[at + 16:])
            return
        offset += size


def copy(source, target):
    target.parent.mkdir(parents=True, exist_ok=True)
    if source.is_symlink():
        link = os.readlink(source)
        if os.path.isabs(link):
            raise ValueError('Absolute source link: ' + str(source))
        target.symlink_to(link)
    else:
        shutil.copy2(source, target)


def sign(p, identity, entitlements=None):
    args = ['codesign', '--force', '--options', 'runtime', '--sign', identity]
    args += ['--timestamp=none'] if identity == '-' else ['--timestamp']
    if entitlements:
        args += ['--entitlements', entitlements]
    run(*args, p, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    run('codesign', '--verify', '--strict', p, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def fetch(url, target, expected):
    if not target.exists():
        part = Path(str(target) + '.part')
        run('/usr/bin/curl', '-fL', '--proto', '=https', '--proto-redir', '=https', '--retry', '2', '-o', part, url)
        part.rename(target)
    if sha(target) != expected:
        raise SystemExit(f'Hash mismatch for {target.name}; delete it and retry')
    return target


def assemble(version, identity):
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]{0,63}', version):
        raise SystemExit('Invalid runtime version')
    for name in PROOFS:
        if not (PHASE2 / name).is_file():
            raise SystemExit('Complete the source builds first (runtime/build.py): missing ' + name)
    dest = WORK / 'artifacts' / version
    if dest.exists():
        raise SystemExit('Use a new version; an existing artifact is never overwritten')
    dest.mkdir(parents=True)

    # Wine: loader, server, every module (not import archives) and share/wine.
    wine = PHASE2 / 'install/usr/local'
    for name in ['bin/wine', 'bin/wineserver']:
        copy(wine / name, dest / name)
    for p in (wine / 'lib/wine').rglob('*'):
        if p.is_file() and p.suffix != '.a':
            copy(p, dest / p.relative_to(wine))
    shutil.copytree(wine / 'share/wine', dest / 'share/wine', symlinks=True)

    # Wine's own 64-bit d3d11/dxgi/d3d10core (wined3d) stay in lib/wine/wined3d, for a game
    # whose profile asks for them (WINEDLLPATH_FIRST, runtime/patches/wine-dll-path-first.patch).
    for name in ('d3d11.dll', 'dxgi.dll', 'd3d10core.dll'):
        copy(dest / 'lib/wine/x86_64-windows' / name, dest / 'lib/wine/wined3d/x86_64-windows' / name)
    # DXMT over Wine's 64-bit d3d11/dxgi/d3d10core (32-bit stays wined3d).
    for p in (PHASE2 / 'dxmt-install').rglob('*'):
        if p.is_file() and p.suffix in ('.dll', '.so'):
            target = dest / 'lib/wine' / p.relative_to(PHASE2 / 'dxmt-install')
            if target.exists() or target.is_symlink():
                target.unlink()
            copy(p, target)
    # Wine Gecko, installed into each prefix by wineboot from share/wine/gecko.
    for name, expected in GECKO.items():
        msi = fetch(GECKO_URL + name, PHASE2 / 'downloads' / name, expected)
        copy(msi, dest / 'share/wine/gecko' / name)
    # Video and audio decoding (runtime/media.py): winegstreamer, GStreamer's
    # plugins and its plugin scanner. Their libraries join the closure below.
    media_tree = PHASE2 / 'media-wine-build/dlls/winegstreamer'
    copy(media_tree / 'winegstreamer.so', dest / 'lib/wine/x86_64-unix/winegstreamer.so')
    for architecture in ('x86_64-windows', 'i386-windows'):
        copy(media_tree / architecture / 'winegstreamer.dll', dest / 'lib/wine' / architecture / 'winegstreamer.dll')
    for p in (MEDIA / 'lib/gstreamer-1.0').glob('*.dylib'):
        if p.name != 'libgstopengl.dylib':  # GL elements: built for applemedia, not used
            copy(p, dest / 'lib/gstreamer-1.0' / p.name)
    copy(MEDIA / 'libexec/gstreamer-1.0/gst-plugin-scanner', dest / 'libexec/gstreamer-1.0/gst-plugin-scanner')
    (dest / 'config').mkdir()
    (dest / 'config/dxmt.conf').write_text(GENERIC_DXMT_CONF)

    # Licenses.
    licenses = dest / 'licenses'
    copy(PHASE2 / 'sources/wine/sources/wine/COPYING.LIB', licenses / 'Wine-LGPL-2.1')
    copy(ROOT / 'LICENSE', licenses / 'Riftway-Apache-2.0')
    recall = WORK / 'recall/licenses'
    for name in ['DXMT-LICENSE', 'DXMT-LGPL-2.1', 'LLVM-15-LICENSE.txt']:
        copy(recall / name, licenses / name)
    copy(WORK / 'recall/LICENSE', licenses / 'Recall-Apache-2.0')
    copy(MINGW / 'LICENSE.TXT', licenses / 'compiler-runtime/LLVM-MinGW-LICENSE.txt')
    for architecture in ('x86_64', 'i686'):
        copy(MINGW / (architecture + '-w64-mingw32/share/mingw32/COPYING'),
             licenses / ('compiler-runtime/MinGW-' + architecture + '-COPYING'))
    # Soju's code in the runtime is its Dock icon patch (inside wine-v1-canvas.patch),
    # which its NOTICE offers under Wine's LGPL-2.1+; its GPL-3.0 patches are left out
    # (runtime/build.py).
    copy(PHASE2 / 'sources/soju' / ('soju-' + SOJU) / 'NOTICE', licenses / 'Soju-NOTICE')
    copy(PHASE2 / 'dxmt-source/include/native/directx/COPYING.MinGW-w64.txt', licenses / 'DirectX-Headers-COPYING')
    mono_source = PHASE2 / 'downloads/wine-mono-10.4.1-src.tar.xz'
    if not mono_source.exists():
        part = Path(str(mono_source) + '.part')
        run('/usr/bin/curl', '-fL', '--proto', '=https', '--proto-redir', '=https', '--retry', '2', '-o', part, MONO_SOURCE_URL)
        part.rename(mono_source)
    if sha(mono_source) != MONO_SOURCE_SHA:
        raise SystemExit('Wine Mono source hash mismatch')
    with tarfile.open(mono_source) as tar:
        for entry in tar:
            path = Path(entry.name)
            if path.is_absolute() or '..' in path.parts:
                raise SystemExit('Unsafe Mono source path')
            if entry.isfile() and (path.name.upper().startswith(('COPYING', 'LICENSE', 'NOTICE', 'AUTHORS', 'THIRDPARTYNOTICES'))
                                   or 'ICSharpCode.SharpZipLib/README' in entry.name):
                target = licenses / 'wine-mono' / path
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(tar.extractfile(entry).read())
    shutil.copytree(PHASE2 / 'clean-deps/licenses', licenses / 'native')
    (licenses / 'wine-gecko').mkdir()
    (licenses / 'wine-gecko/NOTICE').write_text(
        'Wine Gecko 2.47.4 is distributed under the Mozilla Public License 2.0.\n'
        'Corresponding source: ' + GECKO_SOURCE_URL + '\n')
    for name in ['FTL.TXT', 'GPLv2.TXT']:
        copy(PHASE2 / 'sources/freetype/freetype-2.13.3/docs' / name, licenses / 'freetype' / name)
    media_src = PHASE2 / 'media-src/sources/gstreamer/subprojects'
    copy(media_src / 'gstreamer/COPYING', licenses / 'gstreamer/LGPL-2.1')
    copy(media_src / 'glib/LICENSES/LGPL-2.1-or-later.txt', licenses / 'glib/LGPL-2.1-or-later.txt')
    copy(media_src / 'pcre2-10.42/LICENCE', licenses / 'pcre2/LICENCE')
    copy(media_src / 'proxy-libintl/COPYING', licenses / 'proxy-libintl/COPYING')

    # Every Wine patch is in the binaries (a patch that silently did not apply once
    # shipped a runtime without it, and the smoke test cannot tell).
    for module, marker in PATCH_MARKERS:
        if marker.encode() not in (dest / module).read_bytes():
            raise SystemExit(f'{module} lacks {marker}: a Wine patch is missing (runtime/recipe/wine.py)')

    # Native dependency closure: what the runtime links, plus four libraries
    # Wine dlopens (GnuTLS, FreeType, MoltenVK, SDL2 for controllers).
    available = {p.name: p for p in (PHASE2 / 'clean-deps/lib').glob('*.dylib')}
    available['libfreetype.6.dylib'] = PHASE2 / 'freetype-install/lib/libfreetype.6.dylib'
    available.update({p.name: p for p in (MEDIA / 'lib').glob('*.dylib')})
    needed = {'libgnutls.30.dylib', 'libfreetype.6.dylib', 'libMoltenVK.dylib', 'libSDL2-2.0.0.dylib'}
    chosen = {}
    for p in [p for p in dest.rglob('*') if macho(p)]:
        for dep in links(p):
            if Path(dep).name in available:
                needed.add(Path(dep).name)
    while needed:
        name = needed.pop()
        if name in chosen:
            continue
        p = available[name]
        chosen[name] = sha(p)
        shutil.copy2(p.resolve(), dest / 'lib' / name)
        for dep in links(p):
            base = Path(dep).name
            if base in available and base != name:
                needed.add(base)

    native = [p for p in dest.rglob('*') if macho(p)]
    strip = MINGW / 'bin/llvm-strip'
    pe = [p for p in (dest / 'lib/wine').rglob('*') if p.is_file() and not p.is_symlink()
          and p.suffix in ('.exe', '.dll', '.drv', '.sys', '.acm', '.cpl', '.ocx', '.ax')]
    with ThreadPoolExecutor(max_workers=os.cpu_count()) as pool:
        list(pool.map(lambda p: run(strip, '--strip-debug', p, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL), pe))
    for p in native:
        run('/usr/bin/strip', '-S', '-x', p, stderr=subprocess.DEVNULL)
        for dep in links(p):
            if dep.startswith(('/usr/lib/', '/System/Library/', '@loader_path/', '@rpath/', '@executable_path/')):
                continue
            name = Path(dep).name
            if name == p.name:  # a library's own id, set below
                continue
            if name == 'libpcap.dylib':
                run('install_name_tool', '-change', dep, '/usr/lib/libpcap.A.dylib', p, stderr=subprocess.DEVNULL)
            elif name in chosen or name in ('ntdll.so', 'win32u.so'):
                run('install_name_tool', '-change', dep, '@rpath/' + name, p, stderr=subprocess.DEVNULL)
            else:
                raise SystemExit('Unresolved non-system dependency: ' + dep)
        if p.suffix == '.dylib':
            run('install_name_tool', '-id', '@rpath/' + p.name, p, stderr=subprocess.DEVNULL)
        desired = ['@loader_path']
        if p.parent == dest / 'bin':
            desired += ['@loader_path/../lib', '@loader_path/../lib/wine/x86_64-unix']
        elif (dest / 'lib/wine') in p.parents:
            desired += ['@loader_path/../..']
        elif p.parent == dest / 'lib/gstreamer-1.0':
            desired += ['@loader_path/..']
        elif p.parent == dest / 'libexec/gstreamer-1.0':
            desired += ['@loader_path/../../lib']
        old = rpaths(p)
        for path in old:
            if path not in desired:
                run('install_name_tool', '-delete_rpath', path, p, stderr=subprocess.DEVNULL)
        for path in desired:
            if path not in old:
                run('install_name_tool', '-add_rpath', path, p, stderr=subprocess.DEVNULL)

    # The linker derives LC_UUID from the output before strip, when it still names the
    # objects' paths, so it changes with the workspace; derive it from what ships instead.
    for p in native:
        normalize_uuid(p)

    # No build machine path may ship (the pinned llvm-mingw's public CI path is known).
    private = [value.encode(encoding) for value in (str(ROOT), str(WORK), '/opt/homebrew/')
               for encoding in ('utf-8', 'utf-16-le')]
    for p in [*(dest / 'bin').rglob('*'), *(dest / 'lib').rglob('*'), *(dest / 'libexec').rglob('*')]:
        if p.is_file() and not p.is_symlink():
            data = p.read_bytes()
            if any(value in data for value in private):
                raise SystemExit('Development path remains in payload: ' + str(p.relative_to(dest)))
            for encoding in ('utf-8', 'utf-16-le'):
                needle, upstream = '/Users/'.encode(encoding), '/Users/runner/work/llvm-mingw/'.encode(encoding)
                start = 0
                while (start := data.find(needle, start)) >= 0:
                    if not data.startswith(upstream, start):
                        raise SystemExit('Unrecognized home path in payload: ' + str(p.relative_to(dest)))
                    start += len(needle)

    entitlements = PHASE2 / 'riftway-wine-entitlements.plist'
    entitlements.write_bytes(plistlib.dumps({name: True for name in ENTITLEMENTS}))
    with ThreadPoolExecutor(max_workers=os.cpu_count()) as pool:
        list(pool.map(lambda p: sign(p, identity, entitlements if p.name in ('wine', 'wineserver') else None), sorted(native)))
    print('Signed native components:', len(native), '(ad hoc)' if identity == '-' else '', flush=True)

    files = {}
    for p in sorted(dest.rglob('*')):
        if p.is_symlink():
            if not p.resolve().is_relative_to(dest.resolve()):
                raise SystemExit('Runtime symlink escapes payload')
            files[str(p.relative_to(dest))] = {'symlink': os.readlink(p)}
        elif p.is_file():
            files[str(p.relative_to(dest))] = {'sha256': sha(p), 'bytes': p.stat().st_size}
    lock = json.loads((ROOT / 'runtime/sources.lock.json').read_text())
    manifest = {
        'riftway_runtime_schema': 1, 'version': version, 'minimum_macos': MINIMUM_MACOS,
        'signature': 'ad hoc' if identity == '-' else identity,
        'files': files,
        'source_builds': {n: json.loads((PHASE2 / n).read_text()) for n in PROOFS},
        'recall_commit': lock['recall']['commit'], 'deviations_from_recall': lock['deviations_from_recall'],
        'native_dependency_inputs': chosen, 'development_path_scan_passed': True,
        'wine_mono_corresponding_source_sha256': MONO_SOURCE_SHA,
        'wine_gecko': {'version': '2.47.4', 'files': GECKO, 'source': GECKO_SOURCE_URL},
        'status': 'phase 2: Riftway recipe derived from Recall; not for distribution',
    }
    (dest / 'runtime.json').write_text(json.dumps(manifest, indent=2) + '\n')
    archive = Path(str(dest) + '.tar.gz')
    with tarfile.open(archive, 'w:gz', compresslevel=3) as tar:
        for p in sorted(dest.rglob('*')):
            tar.add(p, arcname=str(p.relative_to(dest)), recursive=False)
    proof = {'version': version, 'archive_sha256': sha(archive), 'archive_bytes': archive.stat().st_size,
             'unpacked_file_bytes': sum(v.get('bytes', 0) for v in files.values()), 'files': len(files),
             'signed_native_components': len(native), 'dependency_names': sorted(chosen)}
    archive.with_suffix('.json').write_text(json.dumps(proof, indent=2) + '\n')
    print(json.dumps(proof, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--version', required=True)
    parser.add_argument('--identity', default='-', help='codesign identity; "-" (default) signs ad hoc')
    args = parser.parse_args()
    assemble(args.version, args.identity)
