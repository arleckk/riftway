# PRD-05: Perfiles de juego y compatibilidad

| | |
|---|---|
| Estado | Borrador |
| Hito | M4 |
| Relacionado | [PRD-07](PRD-07-compatibilidad-online.md) (compatibilidad online) |

## Problema

Lo genérico (Wine, el traductor, el descubrimiento) hace que un juego arranque. Que
corra bien, o saber de antemano que no correrá, requiere conocimiento por juego.
Recall lo tiene escrito a mano para Overwatch; Riftway lo necesita como datos.

## Objetivo

Perfiles declarativos que ajustan un juego sin cambiar el código, una base de
compatibilidad que avisa antes de instalar, y un camino para que comunidad y
estudios contribuyan.

## Perfil

Los perfiles viven en [`profiles/`](../../profiles/), un archivo por juego con nombre
`<id>.json`. El de DSR, con lo que aprendimos al hacerlo entrar en línea:

```json
{
  "schema": 1,
  "id": "digimon-super-rumble",
  "name": "Digimon Super Rumble",
  "revision": 1,
  "match": {
    "product": ["Digimon SuperRumble", "Digimon Super Rumble"],
    "company": ["Movegames", "Move Interactive Co., Ltd."],
    "signer": ["Move Interactive Co., Ltd."],
    "installer": ["SuperRumble Installer*.exe"],
    "executables": ["SuperRumble Launcher.exe", "Client-Win64-Shipping.exe"]
  },
  "status": "verified",
  "anticheat": { "vendor": "xigncode3", "kernel": false },
  "tested": { "date": "2026-10-13", "macos": "26.6", "hardware": "Mac15,10 (Apple M3 Max)",
              "runtime": "rw-0.1.2-spike", "online": true },
  "app_dpi": { "dpi": 192, "programs": ["SuperRumble Launcher.exe"] },
  "program_dll_overrides": { "SuperRumble Launcher.exe": { "winegstreamer": "" } },
  "registry": { "HKCU/Software/Movegames/Digimon SuperRumble": { "DirectX11Use": "1" } },
  "play_link": "dsropen",
  "notes": "Usa DirectX 11 (…)"
}
```

| Campo | Qué hace |
|---|---|
| `revision` | Sube con cada cambio; las botellas que aplicaron una anterior la vuelven a aplicar al cerrarse |
| `match` | `product` (con `company` si se da), `signer` (Authenticode del instalador, para instaladores sin cadenas de versión como el de DSR), `installer` (nombre del archivo, con `*`), `executables`, `sha256` |
| `anticheat` | Proveedor y si necesita driver de kernel, según las pruebas |
| `tested` | Evidencia; obligatoria para `verified` |
| `env`, `dll_overrides` | Entorno y overrides de DLL de la botella |
| `game` | Listas de ejecutables para los parches del runtime: `WINEMAC_MOUSELOOK` (mouse crudo), `WINE_GAME_MODE` (arrancan desde el bundle de Game Mode de la botella, con el nombre e ícono del juego) |
| `app_dpi`, `program_dll_overrides` | DPI propio de un launcher; overrides de DLL por ejecutable (`AppDefaults`) |
| `program_args` | Argumentos que el runtime agrega a un programa donde sea que arranque, por nombre de archivo (`{"steamwebhelper.exe": "--in-process-gpu"}`): Riftway los pasa en `RIFTWAY_APPEND_ARGS` y el parche `wine-append-args` los agrega al crear el proceso, también cuando lo arranca otro programa (Steam a su webhelper) o un enlace. Sin `;` ni `=`, y solo `.exe` |
| `registry` | Valores de texto o `dword:XXXXXXXX`; solo `HKCU` y `HKLM/Software`, nunca servicios, drivers ni la clave de identidad de Riftway |
| `dxmt_conf` | Líneas `clave = valor` de `C:\ProgramData\Riftway\dxmt.conf` |
| `d3d11` | `dxmt` (por defecto) o `wined3d`: experimental, para juegos D3D11 en feature level 9_x o para comparar al diagnosticar (RUNTIME-BUILD.md 4.3). El jugador puede cambiarlo (`riftway d3d11 <juego> dxmt\|wined3d\|profile`) |
| `play_link` | Esquema con el que Jugar abre el último enlace que mandó el sitio, en vez del sitio |
| `controller` | Configuración de control ([PRD-08](PRD-08-controles.md)): modo y mapeo por programa, el mismo formato que exporta el editor. Se escribe en la botella solo si no tiene una propia; se valida que cada capa que se mantiene exista |
| `notes` | Texto para el jugador |

Las opciones del jugador (modo diagnóstico, overrides propios) van encima de las del perfil
y se guardan aparte (`bottle.json`), así que cambiar o quitar el perfil no las pierde. Una
clave desconocida es un error: un error de dedo nunca descarta un ajuste en silencio. El campo
`graphics` del borrador original se quitó: DSR mostró que forzar DX11 es un valor de registro
del juego, no un argumento. Elegir el backend de D3D11 es `d3d11`, y wined3d en macOS no pasa
de shader model 3, así que DXMT es el backend de los juegos.

| ID | Requisito |
|---|---|
| R1.1 | Esquema JSON versionado y validado en CI. Todo campo es opcional salvo `id`, `name`, `match` y `status`. |
| R1.2 | Coincidencia por producto y empresa (`VS_VERSIONINFO`), por nombre de ejecutable y opcionalmente por hash. Prioridad: hash, producto con empresa, ejecutable. |
| R1.3 | El perfil se aplica al crear la botella y en cada lanzamiento (entorno, overrides, `dxmt.conf`), nunca modificando archivos del juego. |
| R1.4 | Argumentos para un programa que lanza otro programa (el launcher lanza el cliente): solo se soportan reescribiendo el comando del protocolo dentro de la botella, cuando el launcher usa uno. |
| R1.5 | Feed firmado (clave pública en la app), descargado al abrir la app y como mucho cada 24 h, con caché local. Sin conexión se usa la caché. |

## Estados de compatibilidad

| Estado | Significado | En la UI |
|---|---|---|
| `verified` | Probado de punta a punta con evidencia en hardware y versión de macOS indicados | Insignia verde |
| `playable` | Corre con problemas conocidos | Insignia amarilla y notas |
| `untested` | Sin datos | Sin insignia; se invita a reportar |
| `blocked` | Algo fuera del alcance de Riftway lo impide (anti-cheat de kernel, DRM) | Aviso antes de instalar |

## Detección de anti-cheat

Independiente de los perfiles: se ejecuta sobre el diff de instalación y sobre la
carpeta del juego en cada redescubrimiento (`AntiCheatDetector`). Solo lee nombres de
archivos y de drivers. Solo los indicadores de XIGNCODE3 están confirmados en una
instalación real; los demás salen de la documentación de los proveedores y faltan
juegos del corpus que los usen.

| Proveedor | Indicadores | Sin perfil |
|---|---|---|
| XIGNCODE3 | Carpeta `XIGNCODE`, `x3_x64.xem`, `xxd-0.xem` (confirmado en DSR); driver `xhunter1` | `untested` con aviso: DSR muestra que en modo usuario puede entrar |
| Easy Anti-Cheat | `EasyAntiCheat/`, `EasyAntiCheat_EOS_Setup.exe`, `start_protected_game.exe`; módulo de Linux `easyanticheat_x64.so` | `untested` con aviso: depende de si el estudio habilitó el modo Wine; el `.so` indica que lo hizo para Proton |
| BattlEye | `BattlEye/`, `BEService*.exe`; módulo de Linux `beclient_x64.so` | Igual que EAC |
| Riot Vanguard | `vgk.sys`, `vgc.exe`, carpeta `Riot Vanguard` | `blocked` |
| nProtect GameGuard | `GameGuard/`, `GameMon*.des`, `npgg*.erl` | `blocked` |

Cualquier driver de kernel de un anti-cheat instalado en la botella también da `blocked`.
El estado de un perfil manda sobre la detección: se probó con el anti-cheat presente.

El borrador ponía XIGNCODE3 como `blocked` por defecto; DSR lo desmintió (entra en línea,
sin driver), así que solo un perfil o un driver detectado lo bloquean.

Riftway informa y nunca intenta desactivar, engañar ni evadir un anti-cheat.

## Programa para estudios

Una página "Riftway para desarrolladores" con:
- Checklist de compatibilidad: anti-cheat con modo Wine, no exigir funciones solo
  de DX12 si hay ruta DX11, crear shaders antes de dibujar, entrada de mouse cruda,
  no verificar el fabricante de la GPU.
- Cómo enviar un perfil `verified` con evidencia.
- Opción de distribuir su juego como un `.app` envuelto con el runtime de Riftway
  (cumpliendo LGPL), para estudios que quieran un "port" sin portar.

## Métricas

- 100 % de los juegos del corpus con estado correcto antes de instalar.
- Tiempo de revisión de un perfil enviado: < 7 días.

## Estado de M4

Implementado (`Sources/RiftwayCore/Profiles/`):
- R1.1: esquema 1 con validación estricta (`GameProfile.load`); la prueba
  `shippedProfilesAreValid` valida cada archivo de `profiles/` y `riftway profiles --check`
  sirve para CI.
- R1.2: coincidencia por hash, producto con empresa, firmante, nombre del instalador y
  ejecutables, con puntaje; antes de instalar (`ProfileQuery(report:)`) y después, con lo
  que la botella registró y los programas que el launcher descargó.
- R1.3: el perfil se aplica al crear la botella (`settings.reg` en un solo `reg import`,
  `dxmt.conf`) y en cada lanzamiento (entorno y overrides calculados del perfil más las
  opciones del jugador). Una revisión nueva se aplica cuando la botella se cierra.
- Detección de anti-cheat en la instalación y en cada redescubrimiento; estado e insignia
  en la biblioteca, aviso antes de instalar y en la pantalla de resultado.
- App: insignia (Verificado, Jugable, Bloqueado; "Anti-cheat" si no hay datos pero se
  detectó uno), menú Perfil (aplicar el sugerido, volver a aplicar, quitar). CLI:
  `profiles`, `profile <juego> [ID|--auto|--none]`, `anticheat <carpeta>`; `inspect` e
  `install` muestran la compatibilidad.

Corpus antes de instalar: DSR `verified` (por firmante y nombre del instalador; no trae
cadenas de versión); Steam, Epic, Inno Setup y Visual C++ `untested` (sin datos: correcto).

Pendiente:
- R1.4 (argumentos de launcher a cliente reescribiendo el protocolo): ningún juego del
  corpus lo necesita todavía.
- R1.5 (feed firmado): `<home>/Profiles` se lee tal cual, con la misma prioridad por
  revisión que tendrá la caché del feed. La firma y la descarga van con las actualizaciones
  de la app (M5, PRD-06).
- Validar los indicadores de EAC, BattlEye, Vanguard y GameGuard con juegos reales
  gratuitos.
- Página para estudios y proceso de revisión de perfiles enviados.

