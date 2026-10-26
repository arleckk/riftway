# Riftway

> **🚧 Trabajo en progreso.** Riftway está en desarrollo activo y todavía no es para uso
> general: no hay releases ni descargas, la mayoría de los juegos no se han probado y
> cualquier cosa puede cambiar o romperse entre commits. Si lo pruebas, hazlo con juegos y
> cuentas que no te importe perder, y reporta lo que encuentres.

Juegos e instaladores de Windows en una Mac con Apple Silicon, con doble clic: descargas el
instalador, lo abres, sigues el asistente del juego y queda en tu biblioteca y en Launchpad
con su ícono. Los links de su sitio (`dsropen:…`, `steam://…`) abren el juego, sin Terminal,
CrossOver ni configuración manual.

Riftway se apoya en Wine, Rosetta 2 y DXMT (Direct3D 11 sobre Metal), con un runtime propio
y reproducible. A diferencia de las herramientas hechas para un solo juego, es genérico: un
motor común más **perfiles declarativos por juego** ([`profiles/`](profiles)).

## Estado

| | |
|---|---|
| Hardware probado | Mac con Apple Silicon (M3 Max), macOS 26.6 |
| Releases | Ninguna todavía: se compila desde el código, runtime incluido |
| Firma | Ad hoc (sin Developer ID ni notarización) |
| Hitos | M0, M1, M3 y M6 hechos; M2, M4 y M5 a medias ([plan](docs/PLAN.md#hitos)) |

### Juegos probados

Solo esto se ha probado de verdad. Todo lo demás está **sin probar**: puede funcionar, a
medias o nada.

| Juego | Estado | Notas |
|---|---|---|
| Digimon Super Rumble | ✅ Verificado | En línea, con control (launcher en modo escritorio, juego en teclado). Usa XIGNCODE3 en modo usuario |
| Steam (cliente) | ✅ Verificado | Inicia sesión, instala juegos y Riftway los agrega a la biblioteca |
| Palworld (Steam) | ⚠️ Jugable con problemas | **El personaje del jugador no se ve** (en investigación). El control necesita desactivar Steam Input para el juego. ~20 FPS a 4K en Épico |
| Epic, GOG Galaxy, EA app, Ubisoft Connect, Battle.net | ❔ Sin probar | Riftway descarga sus instaladores de Windows, pero no se han probado |

¿Probaste otro? Abre un issue con el juego, tu Mac, la versión de macOS y qué pasó.

### Lo que hay

- **Instalar con doble clic**: análisis del `.exe`/`.msi` sin ejecutarlo (tipo de instalador,
  firma Authenticode, anti-cheat), botella nueva por juego y descubrimiento de lo que instaló.
- **Biblioteca** con portadas, modo sillón con control y acceso directo por juego en
  `~/Applications/Riftway`.
- **Puente de URLs**: los links del sitio del juego llegan al programa de Windows que
  registró el esquema.
- **Juegos de Steam** en la biblioteca, cada uno con su acceso directo.
- **Controles**: el control llega al juego como uno de Xbox, o se traduce a teclado y mouse
  por programa (editor en la app, importa configuraciones de Steam Input).
- **Por juego**: perfil, Direct3D 11 por DXMT o wined3d, límite de FPS, HUD de Metal,
  tamaño de la interfaz, modo diagnóstico, y elegir o cambiar el disco donde vive.

### Lo que no

- **Anti-cheats de kernel** (Vanguard, EAC/BattlEye con driver, etc.): no funcionan y Riftway
  no intenta evadirlos ni ocultar que corre en Wine ([PRD-07](docs/prd/PRD-07-compatibilidad-online.md)).
  Los juegos en línea con anti-cheat pueden violar sus términos: pruébalos solo con cuentas
  desechables.
- Direct3D 12, MetalFX y DLSS no están soportados.
- No hay descargas, actualizaciones automáticas publicadas ni beta todavía.

## Compilar

Requiere una Mac con Apple Silicon, Rosetta 2 y las Command Line Tools de Xcode.

```sh
swift build
swift test
scripts/build-app.sh          # arma build/Riftway.app (firma ad hoc)
open build/Riftway.app
```

La app necesita un runtime de Wine. Todavía no se publica uno: se compila con la receta de
[`runtime/`](runtime) siguiendo [docs/RUNTIME-BUILD.md](docs/RUNTIME-BUILD.md) (Wine, DXMT y
sus dependencias, desde fuentes fijadas) y se instala desde la app (Archivo › Instalar
runtime…) o con `riftway runtime-install <carpeta>`.

Casi todo también se puede hacer desde la terminal: `swift run riftway help`.

## Documentación

- [Plan del producto](docs/PLAN.md): visión, principios, arquitectura, hitos y corpus de prueba.
- PRDs: [instalar](docs/prd/PRD-01-instalar-con-doble-clic.md),
  [runtime y botellas](docs/prd/PRD-02-runtime-y-botellas.md),
  [puente de URLs](docs/prd/PRD-03-puente-de-urls.md),
  [biblioteca](docs/prd/PRD-04-biblioteca-y-lanzamiento.md),
  [perfiles](docs/prd/PRD-05-perfiles-y-compatibilidad.md),
  [distribución](docs/prd/PRD-06-distribucion-y-actualizaciones.md),
  [juegos en línea](docs/prd/PRD-07-compatibilidad-online.md),
  [controles](docs/prd/PRD-08-controles.md).
- [Cómo se construye el runtime](docs/RUNTIME-BUILD.md).
- [Perfiles de juego](profiles/README.md): cómo escribir uno y sus reglas.

## Contribuir

Los reportes de juegos (funcione o no) son lo más útil ahora mismo. Un perfil nuevo o
corregido es un PR a [`profiles/`](profiles); revísalo con
`swift run riftway profiles --check profiles/<juego>.json`. Nada de tokens, correos ni
identificadores de cuenta en logs, notas o capturas.

## Licencia

[Apache 2.0](LICENSE). El runtime incluye software de terceros con sus propias licencias
(Wine es LGPL; ver [docs/RUNTIME-BUILD.md](docs/RUNTIME-BUILD.md)). Los íconos de los
launchers son marcas de sus dueños ([app/Launchers/NOTICE.md](app/Launchers/NOTICE.md)).
Riftway no está afiliado a Apple, Valve, CodeWeavers ni a los estudios de los juegos.
