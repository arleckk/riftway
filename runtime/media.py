#!/usr/bin/env python3
"""Video and audio decoding for the Riftway runtime: GLib, GStreamer and winegstreamer.

Wine decodes media (Media Foundation, DirectShow, WMV through wmvcore) in
winegstreamer, which hands streams to GStreamer. Recall builds Wine
--without-gstreamer, so games asking Media Foundation for H.264 or AAC get
"class not registered" and their videos never play.

Sources: GLib 2.78.0 and GStreamer 1.24.4 exactly as CodeWeavers ships them in
crossover-sources-26.3.0 (the tarball the Wine build already pins), plus the
three small GLib subprojects pinned in runtime/sources.lock.json ("media").

Decoders come from macOS, not FFmpeg: GStreamer's applemedia plugin wraps
VideoToolbox (H.264, HEVC) and AudioToolbox (AAC, MP3), which every Mac has and
licenses. Everything built here is LGPL; no GPL plugin and no codec library is
compiled in. Formats only FFmpeg decodes (WMV, WMA, Cinepak, Indeo, MPEG-1/2
video) stay unsupported until that decision is made.

  runtime/build.py media    (runs this script)

Outputs, under work/runtime/phase-2/:
  media-stage/riftway-media/   GLib + GStreamer libraries and plugins (prefix /riftway-media,
                               a path the sealed system volume makes impossible to create)
  media-wine-build/            a second Wine build tree configured with GStreamer, from
                               the same patched source and flags, that builds winegstreamer only
  media-build-proof.json
"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
LOCK = json.loads((ROOT / 'runtime/sources.lock.json').read_text())
WORK = ROOT / 'work/runtime'
# Another workspace (RIFTWAY_PHASE2=…/phase-2), to check that two clean builds match.
PHASE2 = Path(os.environ.get('RIFTWAY_PHASE2') or WORK / 'phase-2').resolve()
TOOLS = WORK / 'toolchains'
PY86 = TOOLS / 'python-x86_64'
SDK = '/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk'
CROSSOVER_TARBALL = PHASE2 / 'downloads/wine.tar.gz'
CROSSOVER_SHA = 'ac99c8ca4b3848f3e81784135f023df266b61c2345726ea55a50b3e030dd6872'
PREFIX = '/riftway-media'
SRC = PHASE2 / 'media-src'
BUILD = PHASE2 / 'media-build'
STAGE = PHASE2 / 'media-stage'
FLAGS = '-O2 -g0 -ffile-prefix-map=' + str(PHASE2.parent) + '=/build/riftway'


def sha(path):
    with Path(path).open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()


def run(args, log=None, **kwargs):
    print('+', ' '.join(str(a) for a in args), flush=True)
    if log:
        with open(log, 'a') as out:
            subprocess.run([str(a) for a in args], check=True, stdout=out, stderr=subprocess.STDOUT, **kwargs)
    else:
        subprocess.run([str(a) for a in args], check=True, **kwargs)


def x86(*args):
    """Runs under Rosetta, so meson, ninja and the compilers all target x86_64."""
    return ['/usr/bin/arch', '-x86_64', *args]


def environment():
    env = {
        'PATH': ':'.join([str(PY86 / 'bin'), str(TOOLS / 'bison/bin'), '/usr/bin', '/bin', '/usr/sbin', '/sbin']),
        'HOME': os.environ['HOME'],
        'DEVELOPER_DIR': '/Library/Developer/CommandLineTools',
        'SDKROOT': SDK,
        'MACOSX_DEPLOYMENT_TARGET': '26.0',
        'SOURCE_DATE_EPOCH': str(LOCK['source_date_epoch']['value']),
        'CC': '/usr/bin/clang -arch x86_64', 'CXX': '/usr/bin/clang++ -arch x86_64',
        'OBJC': '/usr/bin/clang -arch x86_64', 'OBJCXX': '/usr/bin/clang++ -arch x86_64',
        'CFLAGS': FLAGS, 'CXXFLAGS': FLAGS, 'OBJCFLAGS': FLAGS, 'OBJCXXFLAGS': FLAGS,
        # Only our own .pc files: nothing from Homebrew (arm64) may be found.
        'PKG_CONFIG_LIBDIR': str(PHASE2 / 'media-pkgconfig'),
        'PKG_CONFIG': '/opt/homebrew/bin/pkg-config',
    }
    return env


def sources():
    """Extracts CodeWeavers' GLib and GStreamer and puts every subproject in place,
    so meson runs with --wrap-mode=nodownload."""
    if sha(CROSSOVER_TARBALL) != CROSSOVER_SHA:
        raise SystemExit('crossover-sources-26.3.0 hash mismatch')
    marker = SRC / '.extracted.json'
    if not marker.exists():
        if SRC.exists():
            shutil.rmtree(SRC)
        SRC.mkdir(parents=True)
        with tarfile.open(CROSSOVER_TARBALL) as t:
            members = [m for m in t.getmembers() if m.name.startswith(('sources/gstreamer/', 'sources/glib/'))]
            t.extractall(SRC, members=members, filter='data')
        marker.write_text(json.dumps({'crossover_sources_sha256': CROSSOVER_SHA}) + '\n')
    tree = SRC / 'sources/gstreamer'
    subprojects = tree / 'subprojects'
    glib = subprojects / 'glib'
    if not glib.exists():
        shutil.move(SRC / 'sources/glib', glib)
        # The monorepo's glib.wrap names 2.78.3 from the network; a wrap whose
        # directory exists is used as is.
        wrap = (subprojects / 'glib.wrap').read_text()
        (subprojects / 'glib.wrap').write_text(wrap.replace('directory = glib-2.78.3', 'directory = glib'))

    # GLib finds proxy-libintl through dependency('intl'), which needs the
    # [provide] section GLib's own wrap has and the monorepo's lacks.
    wrap = subprojects / 'proxy-libintl.wrap'
    if '[provide]' not in wrap.read_text():
        wrap.write_text(wrap.read_text().rstrip('\n') + '\n\n[provide]\nintl = intl_dep\n')

    media = LOCK['media']
    cache = subprojects / 'packagecache'
    cache.mkdir(exist_ok=True)
    for name in ('pcre2', 'pcre2_patch'):
        spec = media[name]
        target = cache / spec['filename']
        if not target.exists():
            part = target.with_name(target.name + '.part')
            run(['/usr/bin/curl', '--fail', '--location', '--retry', '2', '--proto', '=https',
                 '--proto-redir', '=https', '-o', part, spec['url']])
            part.rename(target)
        if sha(target) != spec['sha256']:
            raise SystemExit(f'{name}: SHA-256 mismatch')
    # GLib's own subprojects directory holds gvdb (an empty folder in the tarball).
    for name, directory in (('proxy-libintl', subprojects / 'proxy-libintl'),
                            ('gvdb', glib / 'subprojects/gvdb')):
        spec = media[name]
        if not (directory / '.git').exists():
            if directory.exists():
                shutil.rmtree(directory)
            run(['git', 'clone', '--quiet', spec['repository'], directory])
        run(['git', 'checkout', '--quiet', '--detach', spec['commit']], cwd=directory)

    # libffi and zlib come from macOS (libffi.tbd and libz.tbd in the SDK).
    pc = PHASE2 / 'media-pkgconfig'
    pc.mkdir(exist_ok=True)
    (pc / 'libffi.pc').write_text(
        f'Name: libffi\nDescription: macOS system libffi\nVersion: 3.4.0\n'
        f'Cflags: -I{SDK}/usr/include/ffi\nLibs: -lffi\n')
    (pc / 'zlib.pc').write_text('Name: zlib\nDescription: macOS system zlib\nVersion: 1.2.12\nCflags:\nLibs: -lz\n')
    return tree


# What winegstreamer needs (dlls/winegstreamer: decodebin, parsebin, videoconvert,
# audioconvert, audioresample, videoflip, deinterlace, capsfilter) and what
# feeds the decoders: demuxers for MP4/QuickTime and MPEG streams, parsers.
OPTIONS = [
    '--wrap-mode=nodownload', '--buildtype=release', '-Ddefault_library=shared',
    # Build tools from the toolchain (bison 3.8.2, built from source), not the
    # prebuilt bison GStreamer downloads during configure (TLS checks off, and its
    # mirror is gone). That branch also made pcre2 static without JIT: kept here.
    '-Dbuild-tools-source=system', '-Dpcre2:default_library=static', '-Dpcre2:jit=disabled',
    '-Dprefix=' + PREFIX, '-Dlibdir=lib',
    '-Dauto_features=disabled',
    '-Dbase=enabled', '-Dgood=enabled', '-Dbad=enabled',
    '-Dugly=disabled', '-Dlibav=disabled', '-Dgpl=disabled',
    '-Ddevtools=disabled', '-Dges=disabled', '-Drtsp_server=disabled', '-Drs=disabled',
    '-Dvaapi=disabled', '-Dgst-examples=disabled', '-Dpython=disabled', '-Dsharp=disabled',
    '-Dtls=disabled', '-Dlibnice=disabled',
    '-Dtests=disabled', '-Dexamples=disabled', '-Dintrospection=disabled', '-Dnls=disabled',
    '-Dorc=disabled', '-Ddoc=disabled', '-Dtools=enabled',
    # GLib
    '-Dglib:tests=false', '-Dglib:installed_tests=false', '-Dglib:nls=disabled', '-Dglib:man=false',
    '-Dglib:dtrace=false', '-Dglib:systemtap=false', '-Dglib:sysprof=disabled', '-Dglib:xattr=false',
    '-Dglib:selinux=disabled', '-Dglib:libmount=disabled', '-Dglib:gtk_doc=false', '-Dglib:libelf=disabled',
    # GStreamer core: no PTP helper (a setuid tool), no debug viewer.
    '-Dgstreamer:ptp-helper=disabled', '-Dgstreamer:check=disabled', '-Dgstreamer:libunwind=disabled',
    '-Dgstreamer:libdw=disabled', '-Dgstreamer:bash-completion=disabled',
    # Base
    '-Dgst-plugins-base:app=enabled', '-Dgst-plugins-base:audioconvert=enabled',
    '-Dgst-plugins-base:audioresample=enabled', '-Dgst-plugins-base:playback=enabled',
    '-Dgst-plugins-base:typefind=enabled', '-Dgst-plugins-base:videoconvertscale=enabled',
    '-Dgst-plugins-base:pbtypes=enabled', '-Dgst-plugins-base:rawparse=enabled',
    # applemedia includes GstGL on macOS (CGL + Cocoa, both system frameworks).
    '-Dgst-plugins-base:gl=enabled', '-Dgst-plugins-base:gl_api=opengl',
    '-Dgst-plugins-base:gl_platform=cgl', '-Dgst-plugins-base:gl_winsys=cocoa',
    # Good
    '-Dgst-plugins-good:isomp4=enabled', '-Dgst-plugins-good:audioparsers=enabled',
    '-Dgst-plugins-good:videofilter=enabled', '-Dgst-plugins-good:deinterlace=enabled',
    '-Dgst-plugins-good:wavparse=enabled', '-Dgst-plugins-good:id3demux=enabled',
    '-Dgst-plugins-good:avi=enabled', '-Dgst-plugins-good:matroska=enabled',
    # Bad: macOS decoders, video parsers, MPEG program/transport stream demuxers.
    '-Dgst-plugins-bad:applemedia=enabled', '-Dgst-plugins-bad:videoparsers=enabled',
    '-Dgst-plugins-bad:mpegdemux=enabled', '-Dgst-plugins-bad:mpegtsdemux=enabled',
    '-Dgst-plugins-bad:gl=enabled', '-Dgst-plugins-bad:vulkan=disabled',
]


def gstreamer(tree, env, jobs):
    log = PHASE2 / 'build-logs/media.log'
    log.parent.mkdir(exist_ok=True)
    configured = BUILD / '.riftway-options'
    if BUILD.exists() and not (configured.exists() and configured.read_text() == '\n'.join(OPTIONS)):
        shutil.rmtree(BUILD)
    if not (BUILD / 'build.ninja').exists():
        run(x86(PY86 / 'bin/meson', 'setup', BUILD, tree, *OPTIONS), log=log, env=env)
        configured.write_text('\n'.join(OPTIONS))
    run(x86(PY86 / 'bin/ninja', '-C', BUILD, '-j', str(jobs)), log=log, env=env)
    if STAGE.exists():
        shutil.rmtree(STAGE)
    run(x86(PY86 / 'bin/meson', 'install', '-C', BUILD, '--no-rebuild', '--destdir', STAGE, '--quiet'),
        log=log, env=dict(env))


def winegstreamer(env, jobs):
    """Configures a second Wine tree with GStreamer and builds winegstreamer only.
    Same patched source and flags as the Wine build (runtime/recipe/wine.py); GStreamer
    changes no other module. A tree configured with other flags is built again from scratch."""
    wine = PHASE2 / 'sources/wine/sources/wine'
    tree = PHASE2 / 'media-wine-build'
    staged = STAGE / PREFIX.lstrip('/')
    log = PHASE2 / 'build-logs/media-wine.log'
    wine_flags = '-O2 -g0 -ffile-prefix-map=' + str(PHASE2) + '=/build/riftway'
    include = staged / 'include'
    gst_cflags = ' '.join(['-I' + str(include / 'gstreamer-1.0'), '-I' + str(include / 'glib-2.0'),
                           '-I' + str(staged / 'lib/glib-2.0/include')])
    gst_libs = ' '.join(['-L' + str(staged / 'lib'), '-lgstvideo-1.0', '-lgstaudio-1.0', '-lgsttag-1.0',
                         '-lgstbase-1.0', '-lgstreamer-1.0', '-lgobject-2.0', '-lglib-2.0'])
    wenv = {'PATH': ':'.join([str(TOOLS / 'bison/bin'), str(TOOLS / 'llvm-mingw-20251216-ucrt-macos-universal/bin'),
                              '/usr/bin', '/bin', '/usr/sbin', '/sbin']),
            'HOME': os.environ['HOME'], 'DEVELOPER_DIR': env['DEVELOPER_DIR'], 'SDKROOT': SDK,
            'MACOSX_DEPLOYMENT_TARGET': '26.0', 'SOURCE_DATE_EPOCH': str(LOCK['source_date_epoch']['value'])}
    configured = tree / '.riftway-media-configuration'
    signature = gst_cflags + '\n' + gst_libs + '\n' + wine_flags + '\n' + wenv['SOURCE_DATE_EPOCH'] + '\n'
    if tree.exists() and not (configured.exists() and configured.read_text() == signature):
        shutil.rmtree(tree)
    tree.mkdir(exist_ok=True)
    if not (tree / 'Makefile').exists() or not configured.exists() or configured.read_text() != signature:
        run(['/usr/bin/arch', '-x86_64', wine / 'configure', '--prefix=/usr/local',
             '--enable-archs=i386,x86_64', '--without-x', '--disable-tests',
             '--with-gstreamer', '--without-vulkan', '--without-sdl', '--without-freetype', '--without-gnutls',
             'GSTREAMER_CFLAGS=' + gst_cflags, 'GSTREAMER_LIBS=' + gst_libs,
             'LDFLAGS=-Wl,-headerpad,0x1000', 'CFLAGS=' + wine_flags, 'CROSSCFLAGS=' + wine_flags,
             'CC=/usr/bin/clang -arch x86_64', 'CXX=/usr/bin/clang++ -arch x86_64'],
            log=log, cwd=tree, env=wenv)
        configured.write_text(signature)
    if 'winegstreamer' not in (tree / 'Makefile').read_text():
        raise SystemExit('configure did not enable winegstreamer (see build-logs/media-wine.log)')
    targets = ['dlls/winegstreamer/winegstreamer.so', 'dlls/winegstreamer/x86_64-windows/winegstreamer.dll',
               'dlls/winegstreamer/i386-windows/winegstreamer.dll']
    run(['make', '-j' + str(jobs), 'i386_CFLAGS=' + wine_flags, 'x86_64_CFLAGS=' + wine_flags, *targets],
        log=log, cwd=tree, env=wenv)
    return {t: sha(tree / t) for t in targets}


def main():
    jobs = int(sys.argv[1]) if len(sys.argv) > 1 else os.cpu_count()
    if not (PY86 / 'bin/meson').exists():
        run(x86('/Library/Developer/CommandLineTools/usr/bin/python3', '-m', 'venv', PY86))
        run(x86(PY86 / 'bin/pip', 'install', '--quiet', *LOCK['toolchains']['python-x86_64']['packages']))
    if not (PHASE2 / 'wine-build-proof.json').exists():
        raise SystemExit('Build Wine first (runtime/build.py wine): winegstreamer uses its patched source')
    env = environment()
    tree = sources()
    gstreamer(tree, env, jobs)
    modules = winegstreamer(env, jobs)
    staged = STAGE / PREFIX.lstrip('/')
    proof = {
        'crossover_sources_sha256': CROSSOVER_SHA, 'glib': '2.78.0', 'gstreamer': '1.24.4',
        'subprojects': LOCK['media'], 'meson_options': OPTIONS, 'prefix': PREFIX,
        'decoders': 'applemedia (VideoToolbox, AudioToolbox); no FFmpeg, no GPL plugins',
        'libraries': sorted(p.name for p in (staged / 'lib').glob('*.dylib') if not p.is_symlink()),
        'plugins': sorted(p.name for p in (staged / 'lib/gstreamer-1.0').glob('*.dylib')),
        'winegstreamer': modules,
    }
    (PHASE2 / 'media-build-proof.json').write_text(json.dumps(proof, indent=2) + '\n')
    print(json.dumps({k: proof[k] for k in ('libraries', 'plugins')}, indent=2))


if __name__ == '__main__':
    main()
