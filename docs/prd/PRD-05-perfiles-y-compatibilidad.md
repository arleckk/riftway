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

```json
{
  "schema": 1,
  "id": "digimon-super-rumble",
  "name": "Digimon Super Rumble",
  "match": {
    "product": ["Digimon SuperRumble"],
    "company": ["Movegames"],
    "executables": ["SuperRumble Launcher.exe", "Client-Win64-Shipping.exe"]
  },
  "status": "blocked",
  "anticheat": { "vendor": "xigncode3", "kernel": true },
  "graphics": { "api": "d3d12", "translator": "d3dmetal", "fallback": { "translator": "dxmt", "args": ["-dx11"] } },
  "env": { "WINEMSYNC": "1" },
  "game": {
    "WINEMAC_MOUSELOOK": ["Client-Win64-Shipping.exe"],
    "WINE_GAME_MODE": ["Client-Win64-Shipping.exe"]
  },
  "dll_overrides": {},
  "registry": { "HKCU/Software/Wine/Mac Driver": { "RetinaMode": "Y" } },
  "dxmt_conf": {},
  "notes": "UE 5.4. El launcher lanza el cliente con TOKEN:EMAIL."
}
```

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
carpeta del juego en cada redescubrimiento. Solo los indicadores de XIGNCODE3 están
confirmados en una instalación real; los demás hay que validarlos con instalaciones
del corpus antes de M4.

| Proveedor | Indicadores | Estado por defecto |
|---|---|---|
| XIGNCODE3 | Carpeta `XIGNCODE`, `x3_x64.xem` y otros `.xem` (confirmado en DSR) | `blocked` |
| Easy Anti-Cheat | `EasyAntiCheat/`, `EasyAntiCheat_EOS_Setup.exe` | Depende de si el estudio habilitó el modo Wine |
| BattlEye | `BattlEye/`, `BEService*.exe` | Depende de si el estudio habilitó el modo Wine |
| Riot Vanguard | `vgk.sys`, servicio `vgc` | `blocked` |
| nProtect GameGuard | `GameGuard/`, `GameMon*.des` | `blocked` |

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
