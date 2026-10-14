# Plan de compilación del runtime propio de Riftway

| | |
|---|---|
| Estado | **Fases 0 y 1 completadas el 2026-10-13** (ver "Resultados de la fase 1"); fase 2 en curso: receta propia en `runtime/recipe/`; `rw-0.1.5-spike` es el primero con todos los parches; `rw-0.1.7-spike` es reproducible |
| Hito | M2 ([PRD-02](prd/PRD-02-runtime-y-botellas.md)) |
| Referencia | Recall (`github.com/AsherJN/recall`), clon de solo lectura revisado el 2026-10-13 |

Este documento describe cómo construir el runtime de Riftway (Wine + DXMT + dependencias
nativas) tomando como modelo el pipeline de Recall. Las rutas `scripts/…`, `patches/…`,
`docs/…` y `config/…` son relativas al repositorio de Recall. Todo lo marcado
**[sin verificar]** no se pudo confirmar en las fuentes de Recall ni en esta máquina.

> Advertencia de partida: el propio Recall declara en `docs/SOURCES.json`
> (`toolchain.build_recipe_end_to_end_status`) que la receta completa "not yet
> reconstructed from clean source". Además, casi todas sus versiones de runtime desde
> `phase2-20260927.1` se *derivaron* cambiando componentes sueltos
> (`scripts/derive_runtime.py`, `scripts/build_wine_native.py`) en vez de recompilar todo
> (`docs/BUILDING.md`, sección "Release build pipeline"). El camino de compilación completa
> existe en los scripts, pero no hay evidencia de que se haya ejecutado de punta a punta en
> su forma actual. El primer entregable de Riftway debe ser justamente esa prueba.

## Resultados de la fase 1 (2026-10-13)

La receta de Recall **sí se reproduce de punta a punta desde fuentes limpias** en una Mac
con M3 Max (14 núcleos, macOS 26.6.2, Xcode 27), con las herramientas de
`runtime/sources.lock.json` y una sola desviación (el límite de `--jobs`).

| Paso | Comando | Tiempo | Resultado |
|---|---|---|---|
| Herramientas | `runtime/build.py tools` | ~10 min (descargas) | llvm-mingw, LLVM 15, bison, meson/ninja, Metal Toolchain; todo verificado por SHA-256 |
| Fuentes + dependencias | `fetch`, `deps` | ~12 min | pkgconf, GMP, nettle, GnuTLS, inotify, SDL2, MoltenVK (x86_64) |
| Wine | `wine` | 19 min | i386 + x86_64 (WoW64), todos los parches de Recall aplicados sin conflicto |
| DXMT | `dxmt` | 3 min | d3d11, dxgi, d3d10core, winemetal, shaders de Metal |
| Ensamblado | `runtime/assemble.py --version rw-0.1.0-spike` | 2.5 min | 4,890 archivos, 687 MB (240 MB en `.tar.gz`), 43 binarios nativos firmados ad hoc, escaneo de rutas privadas limpio |
| Prueba de humo | `runtime/build.py smoke rw-0.1.0-spike` | ~45 s | Ver abajo |

Prueba de humo en una botella nueva (`BottleSetup` de `RiftwayCore`):
- `wineboot` crea el prefijo en 61 s la primera vez (traducción de Rosetta) y 32 s después.
- `cmd /c ver` → `Microsoft Windows 10.0.19045`.
- **Sin unidad `Z:`**, y no reaparece al volver a usar la botella (R2.4 de PRD-02).
- `RetinaMode=Y` escrito con `reg.exe`.
- **WoW64**: un `.exe` de 32 bits corre con `IsWow64Process = true`.
- **D3D11 por DXMT**: dispositivo de hardware sobre "Apple M3 Max", nivel 11_0, shaders HLSL
  compilados, un triángulo dibujado y leído de vuelta con el color exacto
  (`runtime/probes/d3d11_probe.c`). Los `d3d11.dll`/`dxgi.dll` del runtime coinciden por hash
  con los de DXMT.

Pendiente de la fase 1 respecto a la receta de Recall: el bundle de Game Mode (paso 8) y
`libd3dshared.dylib` (excluido por decisión).

### Fase 2: generalización (en curso)

Desde `rw-0.1.4-spike` (2026-10-14) Wine y DXMT se compilan con la receta de Riftway,
`runtime/recipe/wine.py` y `runtime/recipe/dxmt.py`, derivada de los scripts de Recall
(Apache 2.0, con atribución); los parches de Recall se leen de su clon fijado y se verifican
por hash. Las dependencias nativas siguen saliendo del script de Recall
(`build_portable_dependencies.py`, que todavía mapea sus rutas a `/build/overwatch-2-mac`;
ningún binario del runtime lleva esa cadena).

**Incidente: parches que no se aplicaron (2026-10-14).** `work/` vive dentro del repositorio
de Riftway, y `git apply` corrido ahí toma las rutas del parche desde la raíz de ese
repositorio y **se salta en silencio** todo lo que cae fuera del directorio actual. En la
fase 1 el proyecto todavía no era un repositorio y todo se aplicó; después, no:
`rw-0.1.4-spike` salió sin los parches de ntdll, win32u, wineserver y la activación de
winemac (y `rw-0.1.2`/`rw-0.1.3` ya venían sin `wine-winemac-activation.patch`). La prueba
de humo no lo detecta. Arreglo: `runtime/recipe/wine.py` corre `git apply` con
`GIT_CEILING_DIRECTORIES` y revisa una cadena de cada parche en el árbol, y
`runtime/assemble.py` (`PATCH_MARKERS`) se niega a ensamblar un runtime cuyos binarios no
tengan alguna. `rw-0.1.4-spike` se desinstaló; ninguna botella lo usaba.

1. ✅ Sin `Libraries.tar.gz` de Whisky: Wine enlaza GnuTLS, inotify y SDL2 de `clean-deps` y
   FreeType de su propio build (`freetype-install`), las mismas librerías que se distribuyen.
   Probado borrando la descarga, `deps/` y el árbol extraído y recompilando.
2. ✅ DXMT sin MetalFX: sin `dxmt-metalfx-upscaling.patch`, con
   `-Denable_nvapi=false -Denable_nvngx=false`, sin certificado y sin instalar los programas
   de diagnóstico. El runtime ya no trae `nvapi64.dll` ni `nvngx.dll`; el `d3d12.dll` que
   queda es el de Wine (vkd3d), que Riftway apaga en cada botella.
3. ✅ Game Mode (`rw-0.1.5-spike`): parche propio `runtime/patches/wine-game-mode-app.patch`
   (`WINE_GAME_MODE_APP`) y un bundle **por juego** en su botella (opción B del paso 8,
   `GameModeApp` en RiftwayCore). Probado: con `--game-mode PING.EXE`, `ping.exe` corre desde
   `<botella>/GameMode/Game.app/Contents/MacOS/wine`; sin él, desde el loader. Falta ver a
   macOS activar Game Mode con un juego en pantalla completa.
4. ✅ Convivencia DXMT/wined3d para D3D11 de 64 bits (`rw-0.1.8-spike`, sección 4.3): el
   mecanismo funciona, pero wined3d en macOS no sirve como respaldo para juegos D3D11 reales.
5. ✅ Prefix-map `/build/riftway` en Wine, FreeType, DXMT y winegstreamer.
6. ✅ Reproducibilidad (2026-10-14, `rw-0.1.7-spike`): el workspace principal y uno limpio en
   otra ruta (`RIFTWAY_PHASE2=…/phase-2`: dependencias, Wine, DXMT y media desde cero) dan
   **los mismos 4,935 archivos, byte por byte**. Lo que hubo que fijar:
   - **Fecha de los PE**: lld escribía la hora del build en el `TimeDateStamp` del encabezado
     y de la tabla de exportaciones de cada módulo de Wine y DXMT. Ahora todos los builds
     llevan `SOURCE_DATE_EPOCH` (2026-10-01, `source_date_epoch` en el lock) y lo incluyen en
     su firma de configuración, porque ni make ni meson vuelven a enlazar si solo cambia.
   - **`LC_UUID` de los Mach-O**: ld lo calcula antes del `strip`, cuando la salida todavía
     nombra las rutas de los objetos, así que cambiaba con el workspace. `assemble.py` lo
     recalcula del contenido que se distribuye (`normalize_uuid`, UUID por nombre del
     SHA-256 con el campo en ceros y sin firma).
   - **bison de GStreamer**: con `build-tools-source=subproject` (el valor por defecto en
     macOS), el `configure` descargaba un bison precompilado de gstreamer.freedesktop.org con
     la verificación TLS apagada, y ese espejo ya no responde. `media.py` usa
     `-Dbuild-tools-source=system` (el bison 3.8.2 del toolchain, compilado desde código) y
     conserva lo demás de esa rama: pcre2 estático y sin JIT.
   - `media.py` mapea las rutas desde el padre del workspace, como las demás recetas.

   Pendiente: comparar con un build en otra Mac (CI). Un fallo del linker bajo Rosetta
   (segfault al enlazar `gst-device-monitor`, una herramienta que no se distribuye) se fue al
   reintentar; `build.py` no reintenta solo.
7. ✅ Revisión de licencia del código de Soju (2026-10-14, ver "Licencia del código de Soju"):
   se quita `ncrypt-persisted-keys.patch` (GPL-3.0) desde `rw-0.1.3-spike`.
8. ✅ Decodificadores de video y audio (`runtime/build.py media`, desde `rw-0.1.2-spike`):
   `winegstreamer` con el GLib 2.78.0 y el GStreamer 1.24.4 de las fuentes de CrossOver 26.3;
   H.264/HEVC por VideoToolbox y AAC/MP3 por AudioToolbox (plugin `applemedia`), sin FFmpeg
   ni plugins GPL. La prueba de humo decodifica un MP4 (H.264 + AAC) por Media Foundation.
   Pendiente: WMV, WMA, Cinepak, Indeo y video MPEG-1/2 (solo los decodifica FFmpeg;
   decidir con revisión de licencias y patentes) y `orc` (acelera `videoconvert`).
9. Video en texturas D3D11 (`rw-0.1.8-spike`, parche propio
   `runtime/patches/wine-video-memory-fallback.patch`). Unreal Engine 5 (Electra) le pasa al
   decodificador H.264 su dispositivo D3D11 por un `IMFDXGIDeviceManager`, y el asignador de
   muestras de Wine crea texturas NV12 en él. DXMT no tiene texturas NV12
   (`CreateMTLTextureDescriptorInternal: invalid format: 103`), así que cada muestra falla y
   el fondo de la selección de servidor de DSR (`Content/Movies/login.mp4`) no aparece. Lo
   reproduce `runtime/probes/movie_probe.c` en modo `d3d11` (sin dispositivo, el mismo video
   decodifica). Con el parche, el decodificador revisa `CheckFormatSupport(NV12)` y responde
   `E_NOTIMPL` a `MFT_MESSAGE_SET_D3D_MANAGER`, como documenta Microsoft para un MFT sin
   Direct3D, y sigue decodificando en memoria; el lector de Media Foundation (que con un
   dispositivo crea su propio asignador de texturas) entrega las muestras en memoria si ese
   asignador no se puede inicializar. `media.py` incluye la lista de parches en la
   firma de `media-wine-build`, porque un árbol extraído de nuevo conserva las fechas del
   archivo.

---

## 1. Entradas fijadas y herramientas

### 1.1 Fuentes (con SHA-256 que Recall verifica)

| Entrada | URL / identidad | SHA-256 o commit | Dónde se fija en Recall |
|---|---|---|---|
| Wine (CrossOver) | `https://media.codeweavers.com/pub/crossover/source/crossover-sources-26.3.0.tar.gz`, subárbol `sources/wine` | `ac99c8ca4b3848f3e81784135f023df266b61c2345726ea55a50b3e030dd6872` | `scripts/build_portable_runtime.py` (`INPUTS`) |
| DXMT (fork) | `https://github.com/NerRobDog/dxmt` | commit `c5dc3a0dfe9108e667da43de871324bd298c9c02` | `scripts/build_portable_dxmt.py` (`BASE`) |
| DirectX headers (submódulo de DXMT) | `https://github.com/misyltoad/mingw-directx-headers` | commit `9df86f2341616ef1888ae59919feaa6d4fad693d` | `scripts/build_portable_dxmt.py` (`HEADERS`) |
| NVAPI headers (submódulo, MIT) | `https://github.com/NVIDIA/nvapi` | commit `d08488fcc82eef313b0464db37d2955709691e94` | `scripts/build_portable_dxmt.py` (`NVAPI`) |
| Soju (receta y parche `ncrypt-persisted-keys.patch`) | `https://codeload.github.com/BCD1210/soju/tar.gz/3a350b32bf906dd2a509b18c642a5a2676de022a` | `e719e417fe92f2600ef4dc3896eb499c0933f05d785918cf7aa8f616cdd75e38`; parche `6283b3637b1d98bf43f68618c0991ee23e719c8bddaed05eff05e3989c954efe` | `scripts/build_portable_runtime.py` (`INPUTS`, `PATCHES`) |
| FreeType 2.13.3 | `https://download.savannah.gnu.org/releases/freetype/freetype-2.13.3.tar.gz` | `5c3a8e78f7b24c20b25b54ee575d6daa40007a5f4eea2845861c3409b3021747` | `scripts/build_portable_runtime.py` |
| Wine Mono 10.4.1 (binario x86) | `https://github.com/wine-mono/wine-mono/releases/download/wine-mono-10.4.1/wine-mono-10.4.1-x86.tar.xz` | `a16606ef0724202e6a6848ece6e0cbba64d11e2f11aefe744af1d93c6d9f99bb` | `scripts/build_portable_runtime.py` |
| Wine Mono 10.4.1 (fuente, para cumplimiento) | `…/wine-mono-10.4.1-src.tar.xz` | `128e335396689e466dff5e1aa0770a714dbe3d16397fc4ddbb8a80999c67323b` | `scripts/assemble_portable_runtime.py` (`MONO_SOURCE_SHA`) |
| Librerías de Whisky v3.1.1 | `https://github.com/frankea/Whisky/releases/download/v3.1.1/Libraries.tar.gz` | `01f3a1b43b98065fe20c529c1023b61dd79a6d2ad93bba6040865f646481ccf3` | `scripts/build_portable_runtime.py`; `docs/SOURCES.json` dice que su licencia por componente está "pending" |
| pkgconf 2.5.1 | `https://distfiles.dereferenced.org/pkgconf/pkgconf-2.5.1.tar.xz` | `cd05c958…c243` | `scripts/build_portable_dependencies.py` |
| nettle 3.10.2 | `https://ftp.gnu.org/gnu/nettle/nettle-3.10.2.tar.gz` | `fe9ff51c…19b5` | ídem |
| GnuTLS 3.8.13 | `https://www.gnupg.org/ftp/gcrypt/gnutls/v3.8/gnutls-3.8.13.tar.xz` | `ffed8ec1…c97e` | ídem |
| GMP 6.3.0 | Dentro del tarball de CrossOver (`sources/gnutls/gmp`) | mismo SHA del tarball | ídem (`WINE_SHA`) |
| libinotify-kqueue 20240724 | `https://github.com/libinotify-kqueue/libinotify-kqueue/releases/download/20240724/libinotify-20240724.tar.gz` | `5cc3fb7a…599c` | ídem |
| MoltenVK 1.2.9 (binario) | `https://github.com/KhronosGroup/MoltenVK/releases/download/v1.2.9/MoltenVK-macos.tar` | `93369586…68ea` | ídem (se adelgaza a x86_64 con `lipo`) |
| SDL2 2.32.10 | `https://github.com/libsdl-org/SDL/releases/download/release-2.32.10/SDL2-2.32.10.tar.gz` | `5f5993c530f084535c65a6879e9b26ad441169b3e25d789d83287040a9ca5165` | ídem (solo subsistemas de control) |
| Librería de soporte de Apple `libd3dshared.dylib` | "Apple's original package" en `<workspace>/apple-original/redist/lib/external/` | `5131e631eee8b542eadf48f4df9fd662d9aeeb59139137e0e6e14047dc434995` | `scripts/assemble_portable_runtime.py` (`APPLE_SHA`). **[sin verificar]** de qué paquete viene: ningún script lo descarga ni lo documenta; la estructura (`redist/`, `License.rtf`, `Read Me.rtf`, `Acknowledgements.rtf`) sugiere el Game Porting Toolkit |

Los hashes abreviados están completos en los scripts citados; Riftway debe copiarlos tal
cual a su propio `sources.lock.json`.

### 1.2 Herramientas

| Herramienta | Versión que usa Recall | Cómo obtenerla | Estado en esta Mac |
|---|---|---|---|
| Command Line Tools + SDK | clang de CLT 2100.1.1.101, `MacOSX26.5.sdk`; Recall fuerza `DEVELOPER_DIR=/Library/Developer/CommandLineTools` y `SDKROOT=…/MacOSX26.5.sdk` para que una actualización de Xcode no cambie el compilador (`scripts/build_portable_runtime.py`, `scripts/build_portable_dependencies.py`) | `xcode-select --install` | Presente: `/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk` existe; Xcode 27 está seleccionado con `xcode-select` |
| Metal Toolchain | componente aparte en Xcode 27 | `xcodebuild -downloadComponent MetalToolchain` (`docs/BUILDING.md`) | **[sin verificar]** si ya está instalado |
| llvm-mingw | `20251216`, UCRT, macOS universal (carpeta `llvm-mingw-20251216-ucrt-macos-universal`) | Releases de `github.com/mstorsjo/llvm-mingw`; nombre de asset esperado `llvm-mingw-20251216-ucrt-macos-universal.tar.xz` **[sin verificar la URL; Recall no la incluye]**. No sustituir por el formula `mingw-w64` de Homebrew (es GCC) | No instalado |
| LLVM 15.0.7 x86_64 | carpeta `clang+llvm-15.0.7-x86_64-apple-darwin21.0`, se pasa a DXMT como `-Dnative_llvm_path` (`scripts/build_portable_dxmt.py`) | Release `llvmorg-15.0.7` de `github.com/llvm/llvm-project`, asset `clang+llvm-15.0.7-x86_64-apple-darwin21.0.tar.xz` **[sin verificar la URL]**. El `llvm@21` de Homebrew no sirve (versión y arquitectura distintas) | No instalado |
| Bison | 3.8.2 (`docs/SOURCES.json`), en `toolchains/bison/bin` | `brew install bison` (keg-only, en `/opt/homebrew/opt/bison/bin`) o compilar `bison-3.8.2` | No instalado |
| Meson + Ninja | en `toolchains/python/bin` (venv) | `python3 -m venv` + `pip install meson ninja`, o `brew install meson ninja`. Recall no fija la versión de Meson **[sin verificar cuál usó]** | No instalados |
| Python | 3.10+ | Homebrew (`python@3.12` ya está) | Presente |
| OpenSSL 3 | Solo para firmar `nvngx.dll` (`scripts/sign_pe.py`) | `brew install openssl@3` | Ya no hace falta: Riftway no compila MetalFX |
| flex, make, git, curl, lipo, otool, install_name_tool, codesign | Del sistema / CLT | CLT | Presentes |
| Rosetta 2 en la máquina de compilación | Los `configure` corren con `/usr/bin/arch -x86_64` | `softwareupdate --install-rosetta` | **[sin verificar]** |

Otros requisitos de Recall: 12 GiB libres para una compilación completa y 3 GiB para
recompilar (`scripts/build_portable_runtime.py`, `__main__`); el workspace de autoconf no
puede tener espacios (`scripts/build_portable_dependencies.py`).

---

## 2. Pipeline paso a paso

Orden de Recall (`docs/BUILDING.md`, "Release build pipeline"):
`build_portable_runtime.py --download-only` → `build_portable_dependencies.py` →
`build_portable_runtime.py` → `build_portable_dxmt.py` → `build_portable_setup.py` →
`assemble_portable_runtime.py` → `build_native_app.py` → `build_release_dmg.py`.

Riftway debe reescribirlo como un solo `Tools/runtime/build.py` (o varios scripts con el
mismo contrato) que lea un `sources.lock.json` y un `patches/series` propios.

### Paso 1. Descargar y verificar

- Recall: `fetch()` en `scripts/build_portable_runtime.py` y el bucle de
  `scripts/build_portable_dependencies.py`. `curl --fail --proto =https --proto-redir =https`,
  descarga a `.part`, compara SHA-256 y solo entonces renombra. La extracción usa
  `tarfile.extractall(filter='data')` y un marcador `.extracted.json` con el hash.
- Riftway: igual, pero con un único archivo de bloqueo. Cachear `downloads/` en CI por
  hash. ✅ Sin la descarga de Whisky (`runtime/recipe/wine.py`).

### Paso 2. Dependencias nativas (x86_64)

- Recall: `scripts/build_portable_dependencies.py` compila en `<ws>/clean-deps` con
  `CC='/usr/bin/clang -arch x86_64'`, `--host=x86_64-apple-darwin`,
  `MACOSX_DEPLOYMENT_TARGET=26.0`, `CFLAGS='-O2 -g0 -ffile-prefix-map=<ws>=/build/overwatch-2-mac'`:
  pkgconf → gmp (`--disable-cxx`) → nettle → gnutls (sin p11-kit, idn, tpm, zlib, brotli,
  zstd; `--with-included-libtasn1 --with-included-unistring`) → libinotify
  (`ac_cv_func_fdclosedir=no` para mantener el target 26.0) → SDL2 (`--disable-joystick-mfi
  --disable-audio --disable-video --disable-render --disable-sensor --disable-power
  --disable-hidapi-libusb`). MoltenVK se toma del binario y se adelgaza con `lipo -thin x86_64`.
  Copia los `COPYING*/LICENSE*` de cada componente a `clean-deps/licenses`.
- Riftway: cambiar el prefix-map a `/build/riftway`. Decidir el target mínimo
  (Recall compila con 26.0 pero la app exige 26.5, `scripts/build_portable_setup.py`).

### Paso 3. Parchar Wine

- Recall: `apply_once()` en `scripts/build_portable_runtime.py`: `git apply --check`; si
  ya está aplicado (`--reverse --check`) lo salta; si no, cae a `/usr/bin/patch -N -F0 -p1`
  (sin *fuzz*) porque algunos parches de Soju tienen contexto solapado. Cada parche se
  compara con su SHA-256 antes de aplicarse. Orden obligatorio (`patches/README.md`):
  1. `wine-v1-canvas.patch` 2. `wine-mouselook.patch` 3. `wine-portable-directory-boolean.patch`
  4. `ncrypt-persisted-keys.patch` (de Soju) 5. `wine-server-registry-save.patch`
  6. `wine-ntdll-syscall-log.patch` 7. `wine-win32u-display-log.patch` 8. `wine-winemac-activation.patch`.
- Riftway: copiar los parches a `Runtime/patches/wine/` con un archivo `series` y sus
  SHA-256; generalizar los que lo necesitan (sección 3) como parches *nuevos* encima de
  los de Recall, para poder seguir haciendo *rebase* contra sus versiones.

### Paso 4. FreeType y configure de Wine

- FreeType: `arch -x86_64 ./configure --without-harfbuzz --without-png --without-brotli
  --without-bzip2 --enable-shared --disable-static` hacia `<ws>/deps`.
- Wine (`scripts/build_portable_runtime.py`, función `build`):
  ```
  arch -x86_64 <wine>/configure --prefix=/usr/local \
    --enable-archs=i386,x86_64 --without-x --disable-tests --without-gstreamer --with-vulkan \
    FREETYPE_CFLAGS/LIBS, GNUTLS_CFLAGS/LIBS, INOTIFY_CFLAGS(-I soju/third_party/libinotify-kqueue)/LIBS,
    SDL2_CFLAGS/LIBS, LDFLAGS='-Wl,-headerpad,0x1000 -L<deps>/lib',
    CFLAGS=CROSSCFLAGS='-O2 -g0 -ffile-prefix-map=…', CC/CXX='/usr/bin/clang[++] -arch x86_64'
  ```
  `PATH` = bison de toolchains + `llvm-mingw/bin` + sistema. Después del configure, Recall
  exige en `include/config.h` `HAVE_SYS_INOTIFY_H`, `SONAME_LIBGNUTLS`, `SONAME_LIBFREETYPE`,
  `SONAME_LIBSDL2` y reescribe los `SONAME_LIB*` (GnuTLS, FreeType, Vulkan/MoltenVK, SDL2) a
  `@rpath/<lib>.dylib` para que el runtime sea reubicable.
- **WoW64**: `--enable-archs=i386,x86_64` es el modo WoW64 nuevo de Wine: un solo lado Unix
  x86_64 y módulos PE de 32 y 64 bits compilados con llvm-mingw (`i686` y `x86_64`). El
  instalador de Recall exige ambos árboles (`lib/wine/x86_64-windows` e `i386-windows`, ver
  `verifyRuntime` en `scripts/portable_setup.m`) y crea botellas con `WINEARCH=win64`. No
  hay Wine de 32 bits en el lado Unix (macOS no ejecuta i386). Esto cubre R1.1 del PRD-02.
- Riftway: ✅ sin `Libraries.tar.gz` de Whisky (en Recall solo se copiaba a `<ws>/deps/lib`
  para enlazar). `runtime/recipe/wine.py` apunta `GNUTLS_LIBS`, `INOTIFY_LIBS` y `SDL2_LIBS` a
  `clean-deps/lib` y FreeType a `freetype-install`; basta, y se cierra el pendiente de
  licencias de Whisky.

### Paso 5. Compilar e instalar Wine

- `make -j N LDFLAGS=… i386_CFLAGS=<flags> x86_64_CFLAGS=<flags>` (los flags PE van aparte
  para no filtrar rutas en los `.dll`), luego `make install DESTDIR=<ws>/install`. Wine Mono
  se copia a `share/wine/mono/wine-mono-10.4.1`. Se escribe `wine-build-proof.json` con
  entradas, hashes de parches y opciones.
- Riftway: sin cambios de fondo; registrar también la versión de CLT/SDK en la prueba.

### Paso 6. Compilar DXMT

- Recall (`scripts/build_portable_dxmt.py`): `git clone --no-checkout`, `checkout --detach
  c5dc3a0…`, `submodule update --init --recursive`, verifica los commits de los submódulos;
  aplica `dxmt-v1-private` → `dxmt-v1-performance` → `dxmt-portable-metal` →
  `dxmt-metalfx-upscaling`; copia `scripts/portable_metal.py` al árbol (envuelve `xcrun metal`
  para que el AIR no lleve rutas locales; `DXMT_METAL_CACHE` permite reutilizar salidas si
  falta el Metal Toolchain). Luego:
  ```
  meson setup <build> <src> --cross-file <src>/build-win64.txt --buildtype=release --strip \
    -Dnative_llvm_path=<clang+llvm-15.0.7-x86_64> -Dwine_build_path=<ws>/wine-build \
    -Denable_tests=false -Denable_nvapi=true -Denable_nvngx=true -Denable_d3d12=false
  meson compile … && meson install --no-rebuild
  ```
  Firma `nvngx.dll` con Authenticode (`scripts/sign_pe.py`) porque el cargador de NVIDIA del
  juego exige firma.
- Salida que entra al runtime (`scripts/derive_runtime.py`, `DXMT_FILES`):
  `x86_64-windows/{d3d11,dxgi,d3d10core,winemetal}.dll` y `x86_64-unix/winemetal.so`.
  DXMT solo se compila para 64 bits (`build-win64.txt`).
- Riftway: para v1, omitir `dxmt-metalfx-upscaling.patch` y compilar con
  `-Denable_nvapi=false -Denable_nvngx=false` (así lo hace la configuración de desarrollo de
  Recall, `docs/BUILDING.md`); eso elimina la necesidad de certificado Authenticode y de
  OpenSSL.

### Paso 7. Ensamblar el layout

- Recall (`scripts/assemble_portable_runtime.py`):
  1. Copia `bin/wine`, `bin/wineserver`, todo `lib/wine` salvo `.a`, y `share/wine`.
  2. **Sobrescribe** en `lib/wine` los `.dll`/`.so` de DXMT (los `d3d11/dxgi/d3d10core` de
     64 bits de Wine desaparecen; los de 32 bits siguen siendo wined3d).
  3. Copia `config/dxmt-source60-1200.conf` como `config/dxmt.conf` (sección `[Overwatch.exe]`).
  4. Copia `libd3dshared.dylib` de Apple sin modificar (verifica `codesign -R=anchor apple`).
  5. Licencias (sección 6).
  6. Resuelve el cierre de dependencias con `otool -L` (más cuatro que se cargan con
     `dlopen`: gnutls, freetype, MoltenVK, SDL2) y las copia a `lib/`.
  7. `llvm-strip --strip-debug` a los PE de Wine/DXMT; `strip -S -x` a los Mach-O;
     `install_name_tool` para cambiar dependencias a `@rpath/…` y dejar rpaths
     `@loader_path`, `@loader_path/../lib`, `@loader_path/../lib/wine/x86_64-unix` (en `bin/`)
     o `@loader_path/../..` (en `lib/wine`).
  8. Rechaza el payload si contiene la ruta del repo, del workspace, `/opt/homebrew/` o
     `/Users/` (salvo la ruta de CI de llvm-mingw), en UTF-8 y UTF-16LE.
- Riftway: igual, pero antes de sobrescribir guarda los DLL de Wine en
  `lib/wine/wined3d/x86_64-windows` para la opción `d3d11: wined3d` (ver sección 4.3). `config/dxmt.conf` debe quedar
  vacío o genérico; las secciones por juego las genera Riftway desde el perfil.

### Paso 8. Bundle de Game Mode

- Recall (`scripts/game_mode_app.py`): copia `lib/wine/x86_64-unix/wine` a
  `lib/wine/game-mode/Overwatch.app/Contents/MacOS/wine`, cambia solo su `LC_UUID`
  (uuid5 del original + identificador, para que la privacidad de red local no se comparta
  con Battle.net), escribe un `Info.plist` = el embebido del loader +
  `CFBundleIdentifier=org.overwatch2mac.overwatch`, `LSApplicationCategoryType=public.app-category.action-games`,
  `LSSupportsGameMode`, `GCSupportsGameMode`, textos de red local y micrófono, y firma el
  bundle con los entitlements del loader y hardened runtime. El parche de ntdll
  (`game_mode_exec`) hace `execv` de `<dll_dir>/game-mode/<Exe sin .exe>.app/Contents/MacOS/wine`
  cuando el programa está en `WINE_GAME_MODE` (lista separada por comas).
- Riftway: el mecanismo ya es genérico (el nombre del bundle sale del ejecutable), pero el
  runtime es inmutable y verificado por hash, así que no se pueden agregar bundles por
  juego dentro de `Runtimes/<versión>/`. Dos opciones:
  - **A (recomendada para v1):** un parche pequeño encima de `wine-ntdll-syscall-log.patch`
    que lea `WINE_GAME_MODE_APP=<ruta del ejecutable>` y, si existe, la use en vez de
    `<dll_dir>/game-mode/<nombre>.app`. El runtime trae un bundle genérico
    `lib/wine/game-mode/Riftway Game.app` (id `com.riftway.game`, provisional) firmado con
    Developer ID. Todos los juegos comparten identidad (permisos de red local y micrófono).
  - **B (elegida, 2026-10-14):** `Bottles/<id>/GameMode/Game.app` por botella, hecho en la
    Mac del usuario y firmado *ad hoc* con los entitlements del loader y hardened runtime
    (`GameModeApp`, derivado de `game_mode_app.py`). Lleva el nombre y el ícono del juego (el
    del puente), id `com.riftway.game.<botella>` (permisos de red local y micrófono por
    juego) y un `LC_UUID` propio. Se hace al construir el puente y solo se rehace si cambia
    el loader del runtime o el nombre: cada firma ad hoc nueva haría que macOS volviera a
    pedir los permisos. `WINE_GAME_MODE_APP` solo se pasa si el bundle es del runtime
    actual. Hoy todo el runtime se firma ad hoc, así que no se pierde nada frente a la A.
    **[sin verificar]** que macOS active Game Mode con esa firma.
  - Cambiar `IDENTIFIER`, `BUNDLE`, `CFBundleName` y los textos que mencionan Overwatch.

### Paso 9. Firma (hardened runtime + entitlements)

- Recall firma **cada** Mach-O (incluidas las `.dylib` del cierre y los `.so`) con
  `codesign --force --options runtime --timestamp --sign <ID>`; solo `wine` y `wineserver`
  (`bin/` y `lib/wine/x86_64-unix/`) llevan el plist de entitlements
  (`scripts/assemble_portable_runtime.py`):
  `com.apple.security.cs.allow-jit`, `…cs.allow-unsigned-executable-memory`,
  `…cs.disable-executable-page-protection`, `…cs.disable-library-validation`,
  `com.apple.security.device.audio-input` (este último agregado en 1.3,
  `scripts/derive_runtime.py`, `derive_microphone`). Luego verifica con
  `codesign --verify --strict`.
- Orden: firmar Mach-O sueltos → crear el bundle de Game Mode **a partir del loader ya
  firmado** (hereda sus entitlements, `game_mode_app.entitlements_of`) → manifiesto → archivo.
  En la app (`scripts/build_native_app.py`): primero helpers, luego el bundle exterior con
  sus entitlements, `codesign --verify --deep --strict`; el DMG se firma, se notariza con
  `notarytool --wait` y se engrapa (`scripts/build_release_dmg.py`).
- Riftway: el runtime se descarga aparte (R1.4), así que no queda cubierto por la
  notarización del DMG. Propuesta: además de firmar, enviar el runtime empaquetado como
  `.zip` a `notarytool` en cada release **[sin verificar si es estrictamente necesario
  cuando la descarga la hace la app sin atributo de cuarentena]**. La firma de la app
  (`com.riftway.*`) debe declarar `NSMicrophoneUsageDescription` genérico.

### Paso 10. Manifiesto y archivo versionado

- Recall escribe `runtime.json` (`schema`, `version`, `minimum_macos`, `files` con
  `sha256`+`bytes` o `symlink`, pruebas de compilación, `native_dependency_inputs`), lo
  empaqueta como `<versión>.tar.gz` (los symlinks deben quedar dentro del payload) y escribe
  `<versión>.tar.json` con `archive_sha256`. El trabajador (`scripts/portable_setup.m`,
  `installRuntime`/`verifyRuntime`/`extract`) solo instala si el hash del archivo coincide con
  el fijado en la app (`app/Resources/release.json`, `runtimeSHA256`), rechaza rutas
  absolutas, `..`, hardlinks, archivos especiales, symlinks que escapan, nombres duplicados
  sin distinguir mayúsculas, más de 20 000 entradas u 8 GiB, y cualquier archivo que no
  liste el manifiesto. Conserva el runtime activo y el anterior (`pruneRuntimes`).
- Riftway: mismo formato (renombrar `schema` → `riftway_runtime_schema`), versión tipo
  `rw-wine26.3-dxmt<commit corto>-<fecha>.<n>`, y un `runtimes.json` firmado o fijado en la
  app con versión, URL, SHA-256 y tamaño (cubre R1.4 y R1.5).

### Nombres de Recall que hay que cambiar

| Dónde | Valor en Recall | En Riftway |
|---|---|---|
| `scripts/build_portable_runtime.py` | el workspace debe llamarse `phase-2` | sin esa restricción |
| prefix-map de CFLAGS (`build_portable_*`, `build_wine_native.py`, `build_mouselook_driver.py`) | `/build/overwatch-2-mac` | `/build/riftway` |
| `scripts/game_mode_app.py` | `lib/wine/game-mode/Overwatch.app`, `org.overwatch2mac.overwatch` | `Riftway Game.app`, `com.riftway.game` |
| `scripts/build_native_app.py` | `org.overwatch2mac.launcher`, `org.overwatch2mac.rosetta-check`, `ow2-setup`, `ow2-pipeline` | `com.riftway.*` |
| `app/Sources/InstallLocation.swift`, `scripts/portable_setup.m` | carpeta `Overwatch2Mac`, marcador `.overwatch-2-mac-owner` | `Riftway`, `.riftway-owner` |
| `scripts/build_release_dmg.py` | perfil de notarización `overwatch-2-mac-notary` | `riftway-notary` |
| `docs/candidate-parity-contract.json` | `DXMT_PIPELINE_CACHE_NAMESPACE=ow2-source-v1`, `WINEMAC_MOUSELOOK=Overwatch.exe`, `WINE_GAME_MODE=Overwatch.exe` | valores por perfil |
| `config/dxmt-source60-1200.conf` | sección `[Overwatch.exe]` | generado desde `dxmt_conf` del perfil |
| `scripts/build_portable_dxmt.py` | certificado `runtime/signing/recall-nvngx` | ✅ no aplica: `runtime/recipe/dxmt.py` no compila MetalFX |

---

## 3. Parches de Recall

Listas: `WINEMAC_MOUSELOOK`, `WINE_NO_DOCK_ICON` y `WINE_CUSTOM_FRAME` usan `;`;
`WINE_GAME_MODE` usa `,`; `WINE_APP_DPI` es `<dpi>:<a.exe>;<b.exe>`. Riftway debe
serializar cada lista desde el perfil (`game.<VAR>` como arreglo, PRD-05) con su separador.

| # | Parche (líneas) | Qué hace | Clase | Recomendación |
|---|---|---|---|---|
| 1 | `dxmt-v1-private.patch` (6072) | Canvas de pantalla completa, presentación y caché de shaders/pipelines; opciones `d3d11.shaderCompilerThreads`, `…NormalPriority`, `dxgi.fullscreenCanvas*`, `dxgi.nativeFullscreen`, `dxgi.maxFrameLatency`, `dxgi.sharpPresentation`; caché por `DXMT_PIPELINE_CACHE_*`; logs por env | MIXTO: mecanismos genéricos, activados por `dxmt.conf`/env, afinados para Overwatch (`patches/README.md`) | Conservar y generalizar: valores por defecto de upstream; activar por perfil; `DXMT_PIPELINE_CACHE_NAMESPACE` por juego. Depende del #5 |
| 2 | `dxmt-v1-performance.patch` (10014) | Conserva la compresión sin pérdida de Apple en render targets marcados UAV hasta su primer uso real; esperas CPU/GPU por evento; *frame pacing* (`dxgi.presentPacing*`); `DXMT_PREPARE_SHADERS=1`; grabador/replay y benchmarks por env; `d3d12stub` | MIXTO (mayormente genérico) | Conservar; probar con el corpus. La compresión parece siempre activa **[sin verificar si tiene interruptor]**: agregar uno si un juego falla |
| 3 | `dxmt-portable-metal.patch` (18) | Pasa `metal`/`metallib` por `portable_metal.py` para no incrustar rutas | GENÉRICO (build) | Conservar |
| 4 | `dxmt-metalfx-upscaling.patch` (1413) | Con `DXMT_ENABLE_NVEXT=1` se reporta una RTX 4090, NVAPI/NGX simulados, DLSS sobre MetalFX, `d3d12.dll` nulo para Streamline; requiere `nvngx.dll` firmado con Authenticode | ESPECÍFICO DE OVERWATCH (calibrado a su Streamline y rango DLSS) | **Quitado desde `rw-0.1.4-spike`**. Evaluar después por perfil; hacerse pasar por NVIDIA puede chocar con anti-cheats |
| 5 | `wine-v1-canvas.patch` (1070) | Canvas fijo en pantalla completa nativa del Mac driver, foco y teclas al perder la ventana; solo actúa si DXMT registra una vista; trae opciones de Soju `WINE_NO_DOCK_ICON`, `WINE_DOCK_REOPEN_CMD`, `WINE_CUSTOM_FRAME`; `DXMT_CANVAS_DRAWABLES`/`OVERLAY`/`LOG` | GENÉRICO (opt-in) | Conservar. Su código marcado "Soju" viene de `winemac-no-dock-icon.patch`, que Soju ofrece con LGPL-2.1+ (ver "Licencia del código de Soju") |
| 6 | `wine-mouselook.patch` (1223) | Mouse crudo con Game Controller framework para los ejecutables en `WINEMAC_MOUSELOOK` mientras ocultan y confinan el cursor; trackpads sin cambios | GENÉRICO (lista) | Conservar; lista desde el perfil |
| 7 | `wine-portable-directory-boolean.patch` (16) | Corrige el ABI de un `BOOLEAN` en `NtQueryDirectoryObject` (bytes altos no definidos) | GENÉRICO (siempre activo) | Conservar |
| 8 | Soju `ncrypt-persisted-keys.patch` (401) | Llaves CNG con nombre que sobreviven al proceso (`%APPDATA%\Microsoft\Crypto\Keys`, RSA y ECDSA P-256/P-384); lo necesita el Epic Games Launcher para su prueba DPoP, sin la cual agota el límite de sesiones de la cuenta | GENÉRICO | **Quitado desde `rw-0.1.3-spike`**: es GPL-3.0 (ver "Licencia del código de Soju"). Volver a incluirlo si Soju lo ofrece con LGPL o llega a Wine |
| 9 | `wine-server-registry-save.patch` (203) | El guardado periódico del registro se hace en un `fork` del wineserver (sin pausas de ~0.1 s cada 30 s); `WINESERVER_REGISTRY_LOG` | GENÉRICO (siempre activo) | Conservar |
| 10 | `wine-ntdll-syscall-log.patch` (832) | Carga la librería Unix de un DLL sin `virtual_mutex` (quita congelamientos de 150–400 ms bajo Rosetta); `WINE_GAME_MODE`; diagnósticos `WINE_SYSCALL_LOG`, `WINE_IO_ERROR_LOG` | GENÉRICO | Conservar y generalizar: `WINE_GAME_MODE_APP` (paso 8) |
| 11 | `wine-win32u-display-log.patch` (202) | `WINE_APP_DPI` da un DPI propio a los programas listados; `WINE_DISPLAY_LOG` | GENÉRICO (lista) | Conservar; útil para launchers Qt/CEF en Retina |
| 12 | `wine-winemac-activation.patch` (770) | No resincroniza pantallas en cada clic; barras negras; resoluciones 1080p/1440p/4K 16:9 y 16:10 y cualquier tamaño que quepa; responde movimientos en pantalla completa con el marco del canvas; se queda minimizado tras Cmd-Tab; `WINEMAC_SCREEN_READBACK=1` devuelve imagen negra a lecturas de pantalla (para el anti-cheat de la versión coreana); `WINEMAC_INPUT_STATS` | MIXTO | Conservar y generalizar. `WINEMAC_SCREEN_READBACK` solo por perfil y con revisión: falsear capturas a un anti-cheat choca con el principio 1 del plan |

Conteo: 8 genéricos (#3, #5, #6, #7, #8, #9, #10, #11; 7 sin el de Soju, que se quitó),
3 mixtos (#1, #2, #12) y 1 específico de Overwatch (#4).

---

## 4. Layout en disco e invocación

### 4.1 Layout propuesto

```
~/Library/Application Support/Riftway/
├── Runtimes/<versión>/                 (inmutable; verificado contra runtime.json)
│   ├── runtime.json
│   ├── bin/wine, bin/wineserver
│   ├── lib/*.dylib                     (gnutls, nettle, hogweed, gmp, freetype, MoltenVK, SDL2, inotify…)
│   ├── lib/wine/x86_64-unix/           (ntdll.so, win32u.so, winemac.so, winemetal.so, wine…)
│   ├── lib/wine/x86_64-windows/        (PE de 64 bits)
│   ├── lib/wine/i386-windows/          (PE de 32 bits, WoW64)
│   ├── lib/dxmt/x86_64-windows/, lib/dxmt/x86_64-unix/   (propuesta, ver 4.3)
│   ├── lib/wine/game-mode/Riftway Game.app
│   ├── share/wine/                     (wine.inf, nls, fuentes, mono/wine-mono-10.4.1)
│   ├── config/dxmt.conf                (genérico)
│   └── licenses/
└── Bottles/<uuid>/
    ├── bottle.json                     (runtime fijado, perfil, prepared_runtime…)
    ├── prefix/                         (WINEPREFIX: system.reg, user.reg, drive_c, dosdevices)
    ├── home/, tmp/, logs/, cache/shaders/, cache/pipelines/
```

`lib/external/libd3dshared.dylib` solo entra si se decide usar D3DMetal (sección 5): el
trabajador de Recall lo exige (`verifyRuntime`), pero Riftway no debe hacerlo hasta tener
la revisión legal.

### 4.2 Cómo debe lanzar `Bottle.Backend.wine(wine:)`

Hoy `Bottle.launchPlan` (`Sources/RiftwayCore/Bottle.swift`) ejecuta `wine <exe>` y solo
agrega `WINEPREFIX`. Propuesta: `wine` = `Runtimes/<versión>/bin/wine` y un
`RuntimeEnvironment` que arme el entorno como `wineEnv()` + `candidateEnvironment()` de
Recall (`scripts/portable_setup.m`, `scripts/candidate_contract.generated.h`), y que
**reemplace** el entorno heredado en vez de mezclarse con él:

| Variable | Valor | Origen en Recall |
|---|---|---|
| `PATH` | `/usr/bin:/bin:/usr/sbin:/sbin` | `wineEnv` |
| `HOME`, `USER`, `TMPDIR` | `Bottles/<id>/home`, `riftway`, `Bottles/<id>/tmp` (aísla las carpetas de usuario de Wine; ayuda a R2.4) | `wineEnv` (`USER=player`) |
| `WINEPREFIX`, `WINEARCH` | `Bottles/<id>/prefix`, `win64` | `wineEnv` |
| `WINELOADER`, `WINESERVER` | `<rt>/bin/wine`, `<rt>/bin/wineserver` | `wineEnv` |
| `WINEDEBUG` | `-all` (el modo diagnóstico lo cambia) | `wineEnv` |
| `WINEMSYNC`, `WINEESYNC` | `1`, `0` | contrato |
| `WINEDLLOVERRIDES` (DXMT) | `d3d11,dxgi,d3d10core,winemetal=b;d3d12,nvapi64,nvngx=` + overrides del perfil | contrato |
| `DXMT_CONFIG_FILE` | ruta **Windows** al `dxmt.conf` (Recall usa `Z:\…`) | `wineEnv` |
| `DXMT_SHADER_CACHE_PATH`, `DXMT_PIPELINE_CACHE_PATH` | `Bottles/<id>/cache/…` | `wineEnv` |
| `DXMT_LOG_LEVEL`, `DXMT_LOG_PATH` | `error`, `none` | `wineEnv` |
| `DXMT_PREPARE_SHADERS`, `DXMT_USE_DEFAULT_METAL_CACHE`, `DXMT_CANVAS_DRAWABLES` | `1`, `1`, `3` | contrato |
| `CX_GRAPHICS_BACKEND`, `CX_ACTIVE_GRAPHICS_BACKEND` | `dxmt` **[sin verificar qué hace en el Wine de CrossOver]** | contrato |
| `ROSETTA_ADVERTISE_AVX`, `WINE_SIMULATE_WRITECOPY` | `1`, `1` **[sin verificar su implementación]** | contrato |
| `WINEMAC_MOUSELOOK`, `WINE_GAME_MODE`, `WINE_APP_DPI` | desde `game.*` del perfil | contrato / `battleNetSize` |
| `WINE_GAME_MODE_APP` | ruta al bundle genérico (parche nuevo, paso 8) | — |

Al quitar `Z:` (R2.4) se rompe `DXMT_CONFIG_FILE=Z:\…`: Riftway debe escribir el
`dxmt.conf` generado dentro del prefijo (por ejemplo `C:\ProgramData\Riftway\dxmt.conf`) y
pasar esa ruta. Recall no quita `Z:` ni desactiva `winemenubuilder`; lo que piden R2.4 y
R2.5 es trabajo nuevo (por ejemplo `winemenubuilder.exe=d` en `WINEDLLOVERRIDES` y borrar
`dosdevices/z:` después del `wineboot`) **[sin verificar en este Wine]**.

Herramientas que usa Recall con el mismo entorno: `wineserver -w` (esperar; con plazo de 5 s
al detectar si hay sesión porque el primer arranque bajo Rosetta tarda) y `wineserver -k`
(terminar, R2.8).

### 4.3 DXMT y wined3d en el mismo runtime

Recall sobrescribe `d3d11/dxgi/d3d10core.dll` de 64 bits con los de DXMT, así que en su
runtime no hay wined3d para D3D11 de 64 bits; D3D9 y anteriores, y todo lo de 32 bits,
siguen en wined3d.

**Decisión (2026-10-14, `rw-0.1.8-spike`): opción (a), con un parche propio.**
`assemble.py` guarda los tres DLL de Wine en `lib/wine/wined3d/x86_64-windows` antes de
sobrescribirlos con los de DXMT. El loader de Wine busca primero en su propio directorio de
DLL y después en `WINEDLLPATH`, así que `WINEDLLPATH` no basta: el parche
`runtime/patches/wine-dll-path-first.patch` agrega `WINEDLLPATH_FIRST`, un directorio que va
antes que el de Wine. Con `"d3d11": "wined3d"` en el perfil (o `riftway d3d11 <juego>
wined3d`, o `--d3d11 wined3d`), `RuntimeEnvironment` lo apunta a `lib/wine/wined3d`.

Probado con `runtime/probes/d3d11_probe.c`: con `wined3d` el juego carga el `d3d11` de Wine
(sus mensajes `d3d11:` aparecen en el log), pero **no crea shaders de modelo 4 ni 5**. Con
OpenGL (el renderer por defecto, OpenGL 4.1 en macOS) wined3d reporta como máximo
feature level 10_1; con Vulkan (MoltenVK, sin geometry shaders) 9_3. En ambos casos
`wined3d_shader_extract_from_dxbc` omite el bytecode SM4+ y `CreateVertexShader` devuelve
`E_INVALIDARG`; DXMT dibuja el mismo probe en 11_0. Por eso:

- DXMT queda como el único backend de D3D10/11 de 64 bits para los juegos.
- `d3d11: wined3d` se conserva como opción experimental de perfil, sin interfaz: sirve para
  juegos D3D11 que funcionan en feature level 9_x y para comparar contra DXMT al
  diagnosticar. Cuesta tres DLL (1.1 MB).
- Un respaldo real para D3D11 necesitaría otro traductor (D3DMetal del Game Porting
  Toolkit, que no se puede redistribuir, o DXVK sobre MoltenVK, que tampoco tiene geometry
  shaders). Queda fuera de la fase 2.

### 4.4 Crear una botella (según `prepare()` de `scripts/portable_setup.m`)

1. Validar el volumen: APFS o HFS+, no de solo lectura, no sensible a mayúsculas
   (`supportedVolume`); crear carpetas con permisos 0700 (`ownRoot`).
2. Verificar el runtime contra `runtime.json` (`verifyRuntime`) y que no haya otra sesión
   (`wineserver -w`, `busy`).
3. `<rt>/bin/wine wineboot.exe -u -r` con el entorno completo (plazo 180 s); Wine crea el
   prefijo si no existe. Luego `wineserver -w` (60 s) y confirmar que existe `system.reg`.
   El PRD-02 pide `wineboot --init`; Recall usa `-u -r` tanto para crear como al cambiar de
   runtime (`prepared_runtime` en `state.json`). Riftway debe repetir `-u` cuando una
   botella pasa a otra versión de runtime.
4. Registro solo con `wine reg.exe add … /f` y después `wineserver -w`, nunca editando los
   `.reg` con el servidor vivo (`configureRetina`, `portable_network.h`, `portable_voice.h`):
   `HKCU\Software\Wine\Mac Driver` `RetinaMode=Y` (Recall lo exige para el canvas), más el
   `registry` del perfil. Verificar leyendo `user.reg` y respaldarlo antes del primer cambio.
5. Trabajo nuevo de Riftway: versión de Windows 10 (`winecfg -v win10` **[sin verificar
   en este build]**), quitar `Z:`, desactivar `winemenubuilder`, escribir `dxmt.conf`.

---

## 5. Opciones para DX12

| Opción | Lo que respaldan las fuentes | Pendiente |
|---|---|---|
| **DXMT + `-dx11` por perfil** | Es lo que Recall usa para D3D11 (`docs/HOW-IT-WORKS.md`). DXMT se compila con `-Denable_d3d12=false`; Recall desactiva `d3d12` con `WINEDLLOVERRIDES` porque el `d3d12.dll` del runtime "is Apple's D3DMetal shim, which crashes next to DXMT's DXGI" (comentario de `patches/dxmt-v1-performance.patch`, `src/d3d12stub/d3d12.cpp`) | Solo sirve para juegos con modo D3D11 |
| **D3DMetal** | El Wine de CrossOver trae `d3dmetal.c`/`d3dmetal_objc.m` en el Mac driver (contexto de `patches/wine-v1-canvas.patch`) y un `d3d12.dll` *shim*; Recall copia solo `libd3dshared.dylib` de un paquete de Apple, sin modificar, con su `License.rtf` (`scripts/assemble_portable_runtime.py`) y pasa `CX_APPLEGPTK_LIBD3DSHARED_PATH`. No hay rastro en Recall de que distribuya el framework D3DMetal ni de que lo use para jugar | **Licencia: requiere revisión legal** (componente propietario de Apple; `THIRD_PARTY_NOTICES.md` separa "source availability" del permiso para redistribuir). También falta saber de dónde sale el paquete y qué más necesita D3DMetal |
| **vkd3d-proton + MoltenVK** | Recall compila Wine `--with-vulkan` y distribuye MoltenVK 1.2.9 (`scripts/build_portable_dependencies.py`, reescritura de `SONAME_LIBVULKAN`/`MOLTENVK`). vkd3d-proton no aparece en Recall | **[sin verificar]** compatibilidad de vkd3d-proton con MoltenVK; licencias de vkd3d-proton (revisión legal) |

Recomendación: v1 con DXMT y `-dx11` por perfil (`graphics.fallback` de PRD-05); un spike
aparte por cada camino DX12, sin bloquear M3.

---

## 6. Cumplimiento de licencias

Lo que Recall hace (`scripts/assemble_portable_runtime.py`, `THIRD_PARTY_NOTICES.md`,
carpeta `licenses/`):

- **Wine**: LGPL-2.1-or-later; copia `COPYING.LIB` del tarball como `licenses/Wine-LGPL-2.1`.
- **DXMT**: LGPL-2.1-or-later, "Copyright (c) 2023-2026 Feifan He for CodeWeavers"
  (`licenses/DXMT-LICENSE`, `licenses/DXMT-LGPL-2.1`).
- **Wine Mono**: guarda el tarball de fuente fijado y copia todos los `COPYING/LICENSE/NOTICE/
  AUTHORS/THIRDPARTYNOTICES` a `licenses/wine-mono/`.
- **Dependencias nativas**: los avisos de cada una (`clean-deps/licenses`: pkgconf, GMP,
  nettle, GnuTLS, libinotify, SDL2 [Zlib], MoltenVK) y FreeType (`FTL.TXT`, `GPLv2.TXT`).
- **Toolchain**: `LICENSE.TXT` de llvm-mingw y `COPYING` de MinGW i686/x86_64 (el runtime de
  MinGW queda dentro de los PE); `licenses/LLVM-15-LICENSE.txt` (Apache 2.0 con excepción LLVM).
- **DirectX headers**: `COPYING.MinGW-w64.txt`; **NVAPI**: MIT (solo con MetalFX; Riftway no lo compila).
- **Soju**: copia su `LICENSE` como `licenses/Soju-GPL-3.0`.
- **Apple**: `License.rtf`, `Read Me.rtf`, `Acknowledgements.rtf` en `licenses/apple/`.
- Los avisos se copian también a `Contents/Resources/Licenses` de la app (`scripts/build_native_app.py`).

Obligaciones para Riftway por cada versión distribuida (PRD-06 R10):

1. Publicar la **fuente correspondiente** de Wine y DXMT: el tarball de CrossOver exacto (o
   un espejo con su hash), el commit de DXMT con submódulos, **todos** los parches en orden,
   los scripts de compilación y el `sources.lock.json`. La LGPL incluye "los scripts usados
   para controlar la compilación".
2. Ofrecer la fuente de las demás piezas LGPL/GPL que se distribuyen (GnuTLS, nettle, GMP,
   FreeType bajo GPLv2 si se elige esa opción, Wine Mono) o un enlace estable y fijado.
3. **Revisión legal** de la tensión entre LGPL 2.1 (el usuario debe poder modificar y
   reemplazar la librería) y la verificación estricta de `runtime.json` que rechaza
   cualquier archivo cambiado. Propuesta: un modo "runtime personalizado" que permita usar un
   runtime sin verificar, con advertencia.
4. ✅ Código de Soju: revisado (ver "Licencia del código de Soju"); el único parche GPL-3.0
   se quitó.
5. No distribuir `libd3dshared.dylib` ni nada de D3DMetal hasta la revisión legal.
6. El código propio de Riftway puede tener cualquier licencia si solo se comunica con Wine
   como proceso aparte, pero eso también es una conclusión a confirmar con un abogado.

### Licencia del código de Soju (revisión del 2026-10-14)

No es una opinión legal; es lo que dicen las fuentes fijadas (Soju en `3a350b32`, Recall en
el commit de `sources.lock.json`).

- El repositorio de Soju es **GPL-3.0** (`LICENSE`; su README: "Scripts and docs in this
  repo: GPL-3.0"). Su `NOTICE` ofrece **un solo parche con la licencia de Wine**:
  "`patches/winemac-no-dock-icon.patch` … the patch itself is offered under LGPL-2.1+ to
  match". Los otros tres (`ncrypt-persisted-keys`, `chromium-flags-append`,
  `winemac-release-keys-on-focus-loss`) no tienen otra licencia, así que quedan en GPL-3.0.
- Los tres bloques marcados "Soju" de `wine-v1-canvas.patch` (`WINE_NO_DOCK_ICON`,
  `WINE_DOCK_REOPEN_CMD`, `WINE_CUSTOM_FRAME`) vienen de `winemac-no-dock-icon.patch`:
  **LGPL-2.1+, sin problema**.
- Los parches propios de Recall conservan la licencia de lo que parchan: "Existing Wine
  LGPL-2.1-or-later terms retained" y DXMT LGPL-2.1-or-later (`THIRD_PARTY_NOTICES.md`).
- Recall aplica `ncrypt-persisted-keys.patch` (`PATCHES` de `build_portable_runtime.py`), y
  estaba en el `ncrypt.dll` de `rw-0.1.0` a `rw-0.1.2-spike`. Wine es LGPL-2.1-**or-later**,
  así que la combinación se podría distribuir como GPL-3.0, pero todo el runtime quedaría en
  GPL-3.0, con la cláusula de "información de instalación" chocando con la verificación
  estricta de `runtime.json`.

Decisión: **Riftway no aplica `ncrypt-persisted-keys.patch`** (`EXCLUDED_SOJU_PATCHES` en
`runtime/build.py`; desviación registrada en el lock) y el runtime queda en LGPL-2.1+. El
costo: el Epic Games Launcher vuelve a perder su llave DPoP en cada arranque (Wine sin
parchar). Ningún juego del corpus lo necesita, salvo Epic. DSR con `rw-0.1.3-spike` (2026-10-14): el prefijo se actualizó solo (`wineboot`), el launcher, el cliente y XIGNCODE3 (`x3_x64.xem`, `xxd-0.xem`) cargan y el jugador lo reporta bien; la partida en línea se confirma cuando termine el mantenimiento del juego.
Para recuperarlo: pedir a Soju que lo ofrezca con LGPL-2.1+ como el del Dock, o que lo
envíe a Wine. El runtime lleva `licenses/Soju-NOTICE` en lugar del texto de la GPL-3.0.

---

## 7. Esfuerzo, riesgos y orden de trabajo

### Orden sugerido (estimaciones para una persona, sin verificar)

| Fase | Trabajo | Criterio de salida | Estimado |
|---|---|---|---|
| 0. Herramientas | Instalar llvm-mingw, LLVM 15 x86_64, bison, meson/ninja, Metal Toolchain; script `check` que liste lo que falta (como `scripts/build_dxmt_local.py --check`) | `check` en verde en esta Mac | 1–2 días |
| 1. Spike | Reproducir la receta de Recall **tal cual** (sin cambios de nombre) en un workspace aparte; correr `winecfg` y un programa D3D11 de prueba en una botella nueva | Runtime ad hoc que arranca; `wine-build-proof.json` y `dxmt-build-proof.json` generados | 1–2 semanas |
| 2. Generalización | Cambiar nombres, quitar Whisky y MetalFX, parche `WINE_GAME_MODE_APP`, `dxmt.conf` genérico, decidir 4.3 | Corpus de M2 arranca con el runtime propio sin CrossOver | 2–3 semanas |
| 3. Build reproducible en CI | Runner macOS arm64 con Rosetta y CLT 26.5 fijado; caché de descargas por hash; comparar dos builds limpios (hashes de `runtime.json`) | Dos ejecuciones dan el mismo manifiesto, salvo diferencias documentadas | 1–2 semanas |
| 4. Firma y notarización | Developer ID, entitlements, bundle de Game Mode, notarización del runtime | `codesign --verify --strict` en todo; runtime aceptado por `notarytool` | ~1 semana |
| 5. Integración | `RuntimeStore` (descarga, verificación, instalación atómica, conservar la versión anterior), `RuntimeEnvironment`, creación de botellas (4.4), `Bottle.Backend.wine` apuntando a `Runtimes/<versión>` | R1.4, R1.5 y R2.2 del PRD-02 cumplidos | 1–2 semanas |

Total aproximado: 6–10 semanas.

### Riesgos

| Riesgo | Impacto | Mitigación |
|---|---|---|
| La receta completa nunca se ejecutó de punta a punta en su forma actual (`docs/SOURCES.json`) | El spike puede fallar en configure/link | Fase 1 primero, en un workspace aislado; registrar cada desviación |
| Parches grandes (≈4 300 líneas en Wine, ≈17 500 en DXMT) fijados a CrossOver 26.3.0 y a un fork de DXMT | Cada actualización de CrossOver o DXMT exige *rebase* manual | Mantener los parches de Recall intactos y los de Riftway encima; seguir los releases de Recall |
| Fork `NerRobDog/dxmt` en vez de upstream | Divergencia con DXMT oficial **[sin verificar cuánta]** | Comparar con upstream durante el spike |
| Toolchain fijado a CLT + `MacOSX26.5.sdk` y compilación bajo Rosetta | Actualizaciones de CLT o un CI sin Rosetta rompen el build | Fijar la imagen de CI; `check` que falle si el SDK no es el esperado |
| Origen no documentado de `libd3dshared.dylib` y licencia de Apple | Bloquea D3DMetal | No incluirlo en v1; revisión legal |
| Código de Soju con GPL-3.0 dentro de parches de Wine | Riesgo de licencia, sobre todo con Riftway cerrado | Revisión legal antes de la primera distribución |
| Parches validados solo con Overwatch y Battle.net (registro con `fork`, compresión, canvas) | Regresiones en otros juegos | Probar todo el corpus; interruptores por perfil donde falten |
| Game Mode con runtime inmutable | El bundle por juego no cabe en el runtime verificado | Opción A del paso 8; spike de la opción B |
| Respaldo wined3d para D3D11 (4.3) | Sin respaldo si DXMT falla en un juego: wined3d en macOS no pasa de shader model 3 | Aceptado; DXMT es el backend; el corpus de M2 dirá si hace falta otro traductor |
| Notarización y cuarentena del runtime descargado aparte | Gatekeeper podría bloquearlo | Notarizar el runtime como `.zip`; probar en una Mac limpia |
| `WINEMAC_SCREEN_READBACK` y la identidad NVIDIA falsa | Choque con el principio de no evadir anti-cheats | Fuera de v1; solo por perfil y con revisión |
