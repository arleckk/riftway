# PRD-06: Distribución y actualizaciones

| | |
|---|---|
| Estado | Borrador |
| Hito | M5 |

## Objetivo

Que el usuario descargue un DMG, arrastre Riftway a Aplicaciones y todo funcione
sin advertencias de Gatekeeper, con actualizaciones seguras de la app, el runtime
y los perfiles.

## Sin Developer ID (situación actual)

Hasta tener la cuenta de Apple Developer (99 USD al año):
- La app y el runtime se firman **ad hoc**. Sirve en la Mac donde se compilan; descargados,
  Gatekeeper los bloquea y el usuario tendría que permitirlos en Ajustes del Sistema ›
  Privacidad y seguridad. Por eso la vía principal es **compilar desde el código**
  (`scripts/build-app.sh`), que no marca cuarentena.
- Los `.app` puente se generan en la Mac del usuario, así que la firma ad hoc les basta
  siempre (probado en M0).
- Las actualizaciones (app, runtime, perfiles) se verifican con una **firma EdDSA propia**
  (como Sparkle), independiente de Apple, para que el día que haya Developer ID solo se
  agregue la notarización.
- R1 y R4 quedan en pausa; el resto aplica igual.

## Requisitos

| ID | Requisito |
|---|---|
| R1 | App firmada con Developer ID y notarizada; DMG firmado, notarizado y engrapado (*stapled*), como `build_release_dmg.py` de Recall. |
| R2 | Fuera de la Mac App Store: Wine necesita JIT, memoria ejecutable sin firmar y cargar librerías sin validación, incompatibles con el sandbox. |
| R3 | Requisitos mínimos: Apple Silicon (M1 o posterior), macOS 26.5 o posterior (versión mínima a confirmar con el runtime), Rosetta 2. |
| R4 | Abrir la app desde el DMG o con translocación: copiarse a `/Applications` (o `~/Applications`), verificar la copia y reabrir, como `AppLocation.swift` de Recall. |
| R5 | Actualizaciones de la app: feed de releases; descarga, verificación de SHA-256, notarización, equipo de Developer ID e identificador; reemplazo atómico y reapertura. Cualquier fallo no cambia nada. Sparkle 2 o el esquema propio de Recall (por decidir). |
| R6 | Actualizaciones del runtime y de los perfiles separadas de las de la app, con verificación de firma o hash fijado ([PRD-02](PRD-02-runtime-y-botellas.md) R1.4, [PRD-05](PRD-05-perfiles-y-compatibilidad.md) R1.5). |
| R7 | Al actualizar la app se regeneran los puentes de `~/Applications/Riftway` ([PRD-03](PRD-03-puente-de-urls.md) R2). |
| R8 | Desinstalar desde Ajustes: mueve a la Papelera la app, las botellas (con confirmación aparte, porque contienen los juegos) y los puentes, y desregistra los esquemas. Nada se borra definitivamente. |
| R9 | Privacidad: sin cuentas ni telemetría por defecto. Las únicas conexiones son las comprobaciones de actualización y del feed de perfiles. Los reportes los envía el usuario. |
| R10 | Licencias: avisos de terceros en "Acerca de"; código fuente y parches del runtime (Wine LGPL 2.1, DXMT) publicados para cada versión distribuida. |

## Estructura del repositorio para la app

- `RiftwayCore` sigue como paquete Swift (probado con `swift test`).
- `Riftway.app` se arma con `scripts/build-app.sh` a partir del producto `RiftwayApp`
  del paquete y de `app/Info.plist`, sin proyecto de Xcode (como Recall). `riftway-shim`
  y la CLI van en `Contents/Helpers/` y se firman antes que el bundle.
- Scripts de release: compilar, firmar el runtime antes que el bundle exterior,
  notarizar y empaquetar.

## Estado de M5

Implementado (`Sources/RiftwayCore/Updates/`, `Sources/RiftwayRelease/`, `scripts/release.sh`):
- **Feed firmado** (R5, R6): `feed.json` (esquema 1) con la app, los runtimes y los
  perfiles, y `feed.json.sig`, firma Ed25519 de sus bytes exactos. Las llaves públicas
  confiables están en `ReleaseKeys.trusted` (rotación: una llave nueva entra una versión
  antes de retirar la anterior). Se rechaza un feed más viejo que el último aceptado
  (sin rollbacks), un esquema desconocido, direcciones que no sean HTTPS (salvo
  `localhost` y archivos, para desarrollo) y descargas cuyo tamaño o SHA-256 no
  coincidan con el feed.
- **App** (R5): se descarga el zip, se desempaca junto a la app instalada (mismo disco),
  se verifica que sea el mismo identificador, la versión que dice el feed, más nueva, con
  firma de código válida (estricta, con código anidado) y del mismo equipo de Developer
  ID que la actual (hoy ninguno: ad hoc). La app se cierra y el `riftway apply-update` de
  la app nueva espera a que salga, intercambia los bundles con un solo `renamex_np`
  (`RENAME_SWAP`), manda la vieja a la Papelera y abre la nueva. Si algo falla, nada cambia.
- **Runtimes** (R6): el `.tar.gz` del ensamblado, verificado y desempacado en
  `Runtimes/<versión>` (debe traer `bin/wine` y un `runtime.json` con esa versión). Las
  botellas siguen con su runtime; las nuevas usan el más reciente.
- **Perfiles** (R6, PRD-05 R1.5): validados uno por uno; los del feed van a
  `Updates/Profiles`, entre los incluidos en la app y los propios del jugador.
- **R7**: al abrir una versión nueva por primera vez, la app reconstruye los puentes.
- **R8**: Ajustes › Desinstalar Riftway: cierra los juegos, desregistra y manda a la
  Papelera los puentes, los runtimes, las descargas y la app; las botellas solo si el
  jugador lo marca (si no, se quedan para reinstalar).
- **R9**: búsqueda automática como mucho una vez al día, desactivable en Ajustes; sin
  `RiftwayFeedURL` (compilando desde el código) no hay ninguna conexión.
- **R10**: "Acerca de" lista Apache 2.0 y los componentes del runtime con sus licencias.
- **R3**: la app pide macOS 26.0 (el mínimo del runtime) y avisa si falta Rosetta 2.
- Release: `scripts/release.sh [--runtime …tar.gz] [--notes …]` arma en
  `build/release/<versión>/` el DMG (arrastrar a Aplicaciones), el zip para el
  actualizador y el feed firmado. `riftway-release` (`keygen`, `sign`, `verify`, `feed`)
  no va dentro de la app; la llave privada vive fuera del repositorio
  (`~/.riftway/release-signing.key`).

Probado de punta a punta (2026-10-13): una copia de 0.1.0 actualizada a 0.1.1 desde un
feed servido en `localhost` (app, runtime `rw-0.1.2-spike` de 353 MB idéntico al
ensamblado, perfiles), con el intercambio esperando al proceso de la app; un feed con un
byte cambiado se rechaza.

Pendiente:
- Decidir dónde se publican las releases y poner esa dirección en `RiftwayFeedURL`.
- Publicar el código fuente y los parches de cada runtime distribuido (R10, LGPL).
- R1 y R4 (Developer ID, notarización, moverse a Aplicaciones) cuando haya cuenta.
- Actualizaciones delta del runtime (hoy se descarga completo).

