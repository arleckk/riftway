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
