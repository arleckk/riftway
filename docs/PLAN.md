# Riftway: plan del producto

## Visión

Que instalar y jugar un juego de Windows en una Mac con Apple Silicon se sienta como en
una PC: descargas el instalador, le das doble clic, sigues el asistente del juego y
queda en tu biblioteca y en Launchpad, con su ícono. Los links de su sitio web
(`dsropen:…`, `steam://…`) abren el juego, y lanzarlo no requiere Terminal,
CrossOver ni configuración manual.

Riftway se apoya en Wine, Rosetta 2 y traductores de gráficos (DXMT, wined3d y, si la
licencia lo permite, D3DMetal), como Recall. La diferencia es que Recall está hecho
para un solo juego (Overwatch) y Riftway es genérico: un motor común más **perfiles
declarativos por juego**.

## Principios

1. **El juego no se toca.** Riftway corre los binarios originales; no modifica archivos
   del juego, no inyecta código y no intenta evadir anti-cheats.
2. **El launcher sigue al mando.** Autenticación, tokens y actualizaciones los maneja
   el launcher del juego dentro de Wine. Riftway solo garantiza que todo viva en el
   mismo prefijo y que lo que viene de macOS (URLs, archivos) llegue ahí.
3. **Descubrir, no programar a mano.** Lo que un instalador registra (accesos
   directos, protocolos, desinstaladores, drivers) se detecta comparando el prefijo
   antes y después de instalar. Los perfiles solo agregan lo que no se puede
   descubrir (ajustes de rendimiento, argumentos).
4. **Honestidad sobre la compatibilidad.** Si se detecta un anti-cheat de kernel, se
   avisa antes de que el usuario descargue 80 GB.
5. **Nunca secuestrar el sistema.** No se reclaman `http`, `https`, `mailto` ni otros
   esquemas de macOS, y la asociación con `.exe` no se vuelve predeterminada sin
   permiso.

## Usuarios

| Persona | Necesidad | Ejemplo |
|---|---|---|
| Jugador casual de Mac | Jugar un juego que solo existe en Windows, sin aprender Wine | Juegos en línea de nicho con launcher propio (DSR) |
| Jugador entusiasta | Control fino: backend gráfico, variables, logs, rendimiento | Usuarios actuales de CrossOver, Whisky o GPTK |
| Desarrollador de juegos | Ofrecer su juego viejo en Mac sin portarlo | Estudio que publica un perfil verificado y habilita el modo Wine de su anti-cheat |
| Contribuidor de perfiles | Afinar un juego y compartir la configuración | Comunidad, como protonfixes en Linux |

## Alcance

**Dentro (v1):**
- Asociación con `.exe` y `.msi`; instalación con doble clic o arrastrando el archivo.
- Botellas (prefijos) por juego, administradas por Riftway.
- Análisis del instalador antes de correrlo y descubrimiento de lo que instaló.
- Biblioteca con lanzamiento, ajustes por juego, logs y desinstalación.
- `.app` puente por juego en `~/Applications/Riftway` (ícono, Launchpad, esquemas de URL).
- Runtime propio (Wine + DXMT + wined3d) firmado y notarizado.
- Perfiles de juego y detección de anti-cheat.

- Compatibilidad con juegos en línea por la vía cooperativa: detección, fidelidad de
  Windows, identidad honesta y trabajo con estudios y proveedores
  ([PRD-07](prd/PRD-07-compatibilidad-online.md)).

**Fuera (v1):**
- Macs Intel.
- Evasión de anti-cheats, DRM o verificación de plataforma (ver la línea roja en
  [PRD-07](prd/PRD-07-compatibilidad-online.md)).
- Tienda de juegos y descarga de juegos por parte de Riftway.
- Juegos de 32 bits que requieran WoW64 antiguo (se evaluará).
- Distribución por la Mac App Store (el sandbox es incompatible con Wine).

## Arquitectura

```
Riftway.app (SwiftUI, Developer ID, notarizada)
├── UI: Biblioteca · Instalar · Ajustes · Diagnóstico
├── RiftwayCore (paquete Swift, ya existe)
│   ├── WineRegistry, WindowsCommandLine, URLBridge   ← hecho (M0)
│   ├── InstallerAnalyzer   (PE, versión, manifiesto, Authenticode, tipo de instalador)
│   ├── PrefixSnapshot/Diff (registro + archivos + accesos .lnk)
│   ├── BottleManager       (crear, aislar, clonar, borrar a la Papelera)
│   ├── Supervisor          (procesos de Wine por botella, eventos, logs)
│   ├── ProfileStore        (perfiles declarativos, feed firmado)
│   └── ShimBundle          (puentes .app: ícono, esquemas, Game Mode)  ← hecho (M0)
├── riftway (CLI para desarrollo y soporte)                              ← hecho (M0)
├── riftway-shim (binario del .app puente)                               ← hecho (M0)
└── Runtime/ (descargable y versionado)
    ├── wine-<versión>/ (fuentes de CrossOver + parches genéricos)
    ├── dxmt-<versión>/, wined3d
    └── game-mode/ (loader de Wine dentro de un bundle que se declara juego)

~/Library/Application Support/Riftway/
├── Bottles/<id>/       (prefijo + bottle.json)
├── Runtimes/<versión>/
├── Profiles/           (caché del feed)
└── Installers/         (copias de los instaladores ejecutados)
~/Applications/Riftway/<Juego>.app   (puentes)
~/Library/Logs/Riftway/
```

**Backends.** El producto usa solo el runtime propio ([RUNTIME-BUILD.md](RUNTIME-BUILD.md)).
`Bottle.Backend.crossover` queda como adaptador de desarrollo e importación de botellas
existentes; ninguna función de producto depende de CrossOver.

## Hitos

| Hito | Entregable | PRD | Criterio de salida |
|---|---|---|---|
| **M0** ✅ | Puente de URLs (CLI + `.app` puente) | [PRD-03](prd/PRD-03-puente-de-urls.md) | URL desde macOS llega intacto al launcher; probado de punta a punta |
| **M1** ✅ | App base + asociación `.exe`/`.msi` + análisis del instalador (solo lectura) | [PRD-01](prd/PRD-01-instalar-con-doble-clic.md) §1–3 | Doble clic o "Abrir con" en `.exe`/`.msi` abre Riftway con la hoja de análisis correcta |
| **M2** 🔶 | Runtime propio: reproducir la receta de Recall (✅ fase 1: `rw-0.1.0-spike` pasa la prueba de humo; ✅ DSR entra al juego en línea con `rw-0.1.1-spike`; fase 2: ✅ licencia de Soju, sin Whisky ni MetalFX, receta propia en `runtime/recipe/` desde `rw-0.1.4-spike`), generalizarla, compilar y firmar | [PRD-02](prd/PRD-02-runtime-y-botellas.md), [RUNTIME-BUILD.md](RUNTIME-BUILD.md) | Un `Runtimes/<versión>` reproducible que corre el corpus sin CrossOver; Experimento 1 de [PRD-07](prd/PRD-07-compatibilidad-online.md) documentado |
| **M3** ✅ | Botella nueva + ejecutar instalador + diff + biblioteca + puentes automáticos, sobre el runtime propio | [PRD-01](prd/PRD-01-instalar-con-doble-clic.md) §4–7, [PRD-04](prd/PRD-04-biblioteca-y-lanzamiento.md) | DSR, Steam, GOG (Inno) y un MSI instalan y quedan en la biblioteca sin pasos manuales |
| **M4** 🔶 | Perfiles + detección de anti-cheat + compatibilidad online (✅ perfiles, detección, estados en la app, identidad honesta; falta el feed firmado y validar más anti-cheats) | [PRD-05](prd/PRD-05-perfiles-y-compatibilidad.md), [PRD-07](prd/PRD-07-compatibilidad-online.md) | Cada juego del corpus tiene estado y causa de bloqueo correctos antes de instalar |
| **M5** 🔶 | Distribución: firma, actualizaciones, beta (✅ feed firmado Ed25519, actualizador de app, runtime y perfiles, DMG, desinstalar; falta dónde publicar y la beta) | [PRD-06](prd/PRD-06-distribucion-y-actualizaciones.md) | Beta pública que se actualiza sola (notarizada cuando haya Developer ID) |
| **M6** ✅ | Controles: el control llega al juego (capa 0) y se traduce a teclado y mouse por programa, launcher y juego, con editor en la app y mapeo en los perfiles (falta la capa 1, opcional) | [PRD-08](prd/PRD-08-controles.md) | DSR completo con control: launcher en modo escritorio, juego en modo teclado |

## Corpus de prueba

Cada hito se valida contra los mismos instaladores, que cubren los formatos comunes.

| Instalador | Formato | Qué ejercita |
|---|---|---|
| Digimon Super Rumble | NSIS 3.08, `requireAdministrator` | Protocolo propio (`dsropen`), launcher que actualiza, XIGNCODE3 |
| Steam (`SteamSetup.exe`) | NSIS | Protocolo `steam://`, cliente que se autoactualiza, juegos dentro del cliente |
| Un juego de GOG offline | Inno Setup | Instalador clásico con varios archivos `.bin` junto al `.exe` |
| Epic Games Launcher | MSI | `msiexec`, protocolo `com.epicgames.launcher` |
| Visual C++ Redistributable | WiX Burn | Dependencia silenciosa (`/quiet`) |
| Un juego portable (zip con `.exe`) | Sin instalador | "Agregar a biblioteca" sin instalar |

Los juegos y cuentas reales se prueban a mano; los tests automáticos usan
instaladores sintéticos (NSIS e Inno se pueden generar en CI).

## Riesgos

| Riesgo | Impacto | Mitigación |
|---|---|---|
| Anti-cheat de kernel (XIGNCODE3, Vanguard, nProtect) | El juego no corre o la cuenta se marca | Detectar y avisar antes; base de compatibilidad; programa para estudios ([PRD-05](prd/PRD-05-perfiles-y-compatibilidad.md)) |
| Licencia de D3DMetal para DX12 | No se puede incluir en Riftway | Decisión 2: DXMT + `-dx11`; D3DMetal solo si el usuario instala el Game Porting Toolkit de Apple |
| Código "Soju" dentro de `wine-v1-canvas.patch` (repositorio GPL-3.0) | Choque con Apache 2.0 y LGPL | Revisión legal antes de distribuir el runtime ([RUNTIME-BUILD.md](RUNTIME-BUILD.md) §6) |
| Sin Developer ID | Gatekeeper bloquea la app descargada; sin notarización | Decisión 5: firma ad hoc y compilación desde el código mientras tanto ([PRD-06](prd/PRD-06-distribucion-y-actualizaciones.md)) |
| Wine no es un sandbox | Un `.exe` malicioso puede leer archivos del usuario | Quitar el drive `Z:`, copiar el instalador dentro de la botella, mostrar firma y origen |
| Cambios de macOS (Rosetta, Game Mode, LaunchServices) | Regresiones tras actualizar macOS | Matriz de pruebas por versión de macOS; checks al arrancar como Recall |
| Cumplimiento LGPL (Wine, DXMT) | Riesgo legal | Publicar fuentes y parches del runtime; avisos de terceros en la app |

## Decisiones

Tomadas el 2026-10-13.

| # | Tema | Decisión |
|---|---|---|
| 1 | Runtime | **Runtime propio** (Wine de las fuentes de CrossOver + DXMT). CrossOver solo como adaptador de desarrollo e importación. |
| 2 | DX12 | **DXMT con `-dx11` por perfil** como camino principal (UE4/UE5 y la mayoría de motores con DX12 conservan modo D3D11). **D3DMetal solo "trae tu propio"**: si el usuario instaló el Game Porting Toolkit de Apple, Riftway lo detecta y lo ofrece; nunca se incluye, porque su licencia no aclara la redistribución. **vkd3d-proton + MoltenVK** como experimento, sin bloquear hitos. |
| 3 | Licencia | **Código abierto, Apache 2.0** (`LICENSE`). Wine y DXMT conservan las suyas (LGPL); se publican fuentes y parches del runtime. |
| 4 | Asociación | **Se pregunta en el primer arranque** (implementado en M1); Riftway queda como alternativa en "Abrir con" mientras tanto. |
| 5 | Identidad | Nombre **Riftway**; bundle id **`com.riftway.*` provisional** hasta tener dominio. **Sin Developer ID por ahora**: firma ad hoc, distribución desde el código y actualizaciones verificadas con firma propia (EdDSA), no con la de Apple. |
| 6 | Juegos en línea | Se explora la **compatibilidad cooperativa**, nunca la evasión ([PRD-07](prd/PRD-07-compatibilidad-online.md)). |
