# Runtime de Riftway

Herramientas para compilar el runtime propio (Wine de las fuentes de CrossOver + DXMT).
El plan completo está en [docs/RUNTIME-BUILD.md](../docs/RUNTIME-BUILD.md).

## Fase 2: receta propia

Desde `rw-0.1.4-spike`, Wine y DXMT salen de [`recipe/wine.py`](recipe/wine.py) y
[`recipe/dxmt.py`](recipe/dxmt.py), derivados de los scripts de Recall (Apache 2.0) sin
las librerías de Whisky, sin MetalFX (ni sustitutos de NVAPI, NGX o D3D12) y sin el parche
GPL-3.0 de Soju, con las rutas mapeadas a `/build/riftway`. Los parches de Recall se leen de
su clon fijado y se verifican por hash; las dependencias nativas siguen saliendo de su
script. Los pasos de abajo son los mismos.

## Fase 1: reproducir la receta de Recall

Antes de generalizar nada, se compila exactamente lo que compila Recall, con sus
scripts y parches, fijados en [`sources.lock.json`](sources.lock.json). Todo vive en
`work/runtime/` (fuera de git) y no toca Homebrew, CrossOver ni ningún runtime instalado.

```sh
runtime/build.py tools   # llvm-mingw, LLVM 15 x86_64, bison, meson/ninja; clona Recall
runtime/build.py check   # qué falta (el Metal Toolchain se instala con
                         # xcodebuild -downloadComponent MetalToolchain)
runtime/build.py fetch   # fuentes de Wine (CrossOver 26.3), Soju, FreeType, Wine Mono…
runtime/build.py deps    # dependencias nativas x86_64 (GnuTLS, SDL2, MoltenVK…)
runtime/build.py wine    # Wine i386 + x86_64 (WoW64), bajo Rosetta
runtime/build.py dxmt    # DXMT contra el Wine recién compilado
runtime/build.py media   # GLib + GStreamer + winegstreamer (video y audio)
```

`media` usa el GLib 2.78.0 y el GStreamer 1.24.4 que vienen dentro de las fuentes de
CrossOver 26.3. Los decodificadores son los de macOS (VideoToolbox para H.264/HEVC,
AudioToolbox para AAC/MP3) a través del plugin `applemedia`; no se compila FFmpeg ni
ningún plugin GPL. WMV, WMA, Cinepak, Indeo y video MPEG-1/2 siguen sin soporte.

Requisitos: Apple Silicon con Rosetta, Command Line Tools con `MacOSX26.5.sdk`, Xcode con
el Metal Toolchain y unos 15 GB libres. La ruta del repositorio no puede tener espacios
(autoconf).

Después:

```sh
runtime/assemble.py --version rw-0.1.0-spike   # ensambla, firma (ad hoc) y empaqueta
runtime/build.py smoke rw-0.1.0-spike          # botella nueva + sondas (Windows, Z:, WoW64, D3D11, video)
```

Las desviaciones respecto a Recall se registran en `deviations_from_recall` del lock.
Resultados y tiempos de la fase 1: [docs/RUNTIME-BUILD.md](../docs/RUNTIME-BUILD.md#resultados-de-la-fase-1-2026-10-13).
