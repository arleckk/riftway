# PRD-02: Runtime y botellas

| | |
|---|---|
| Estado | Borrador; plan de compilación en [RUNTIME-BUILD.md](../RUNTIME-BUILD.md) |
| Hito | M2 |

## Problema

Hoy Riftway usa las botellas y el Wine de CrossOver. Para que "doble clic e
instalar" funcione en cualquier Mac, Riftway necesita su propio runtime, firmado y
mantenido, y administrar botellas propias con reglas de aislamiento y ubicación.

## Objetivo

Un runtime propio que corre el corpus del [plan](../PLAN.md#corpus-de-prueba) sin
CrossOver instalado, y botellas que se crean, actualizan y borran sin que el
usuario vea Wine.

## Requisitos

### Runtime

| ID | Requisito |
|---|---|
| R1.1 | Wine compilado desde las fuentes publicadas de CrossOver (como Recall: `crossover-sources-<versión>.tar.gz`), x86_64 bajo Rosetta, con WoW64 para programas de 32 bits. |
| R1.2 | Parches genéricos tomados de Recall, activados por listas de ejecutables en el perfil y no fijos a un juego: mouse crudo (`WINEMAC_MOUSELOOK`), Game Mode (`WINE_GAME_MODE`), guardado del registro sin pausas, lock de ntdll, activación de ventanas, DPI por app (`WINE_APP_DPI`). |
| R1.3 | Gráficos: DXMT (D3D10/11 → Metal) por defecto; wined3d para D3D9 y anteriores, y para D3D11 solo como opción experimental de perfil (`d3d11: wined3d`; en macOS no pasa de shader model 3, ver RUNTIME-BUILD.md 4.3); DX12 según la [decisión 2](../PLAN.md#decisiones): `-dx11` por perfil, D3DMetal solo si el usuario instaló el Game Porting Toolkit, vkd3d-proton como experimento. |
| R1.4 | El runtime se descarga bajo demanda (no va dentro del DMG de la app), se verifica con SHA-256 fijado en la app firmada (como `release.json` en Recall) y vive en `Runtimes/<versión>/`. |
| R1.5 | Cada botella fija su versión de runtime. Actualizar el runtime es opcional por botella y reversible (se conserva la versión anterior hasta que ninguna botella la use). |
| R1.6 | Firma (ad hoc mientras no haya Developer ID, ver [decisión 5](../PLAN.md#decisiones)) con hardened runtime y los entitlements que Wine necesita: `cs.allow-jit`, `cs.allow-unsigned-executable-memory`, `cs.disable-executable-page-protection`, `cs.disable-library-validation`, `device.audio-input` (verificados en Recall). |
| R1.7 | Chequeo de Rosetta antes de cada lanzamiento, con pantalla para instalarlo (`softwareupdate --install-rosetta` lo dispara macOS). |
| R1.8 | Game Mode: un bundle `game-mode/<juego>.app` por botella con el loader de Wine, `LSApplicationCategoryType` de juegos y `LSSupportsGameMode` (técnica de Recall). |

### Botellas

| ID | Requisito |
|---|---|
| R2.1 | `Bottles/<uuid>/` contiene el prefijo y un `bottle.json`: nombre, runtime, backend gráfico, versión de Windows, perfil aplicado, programas, protocolos, fecha de creación. |
| R2.2 | Crear: `wineboot --init` con la plantilla Windows 10 64 bits y `RetinaMode` según el perfil. Objetivo: < 20 s en M1. |
| R2.3 | Ubicación interna por defecto; externa con las reglas de Recall (APFS o Mac OS Extended, no sensible a mayúsculas, no de red ni en la nube). Si el disco se desconecta, la biblioteca lo muestra y nunca crea una carpeta vacía en su lugar. |
| R2.4 | **Aislamiento:** sin unidad `Z:`. Solo `C:` y las carpetas que el usuario agregue explícitamente (como `D:`). Las carpetas especiales de usuario de Wine (Documentos, Escritorio) no se enlazan a las de macOS. |
| R2.5 | `winemenubuilder` desactivado y asociaciones de Wine con el host deshabilitadas, salvo `winebrowser` para `http`/`https`/`mailto` (abre el navegador de la Mac). |
| R2.6 | Borrar una botella la mueve a la Papelera (nunca borrado definitivo) y desregistra sus puentes (orden: mover y luego `lsregister -u`, ver [PRD-03](PRD-03-puente-de-urls.md)). |
| R2.7 | Importar botellas de CrossOver (copia, no se mueven) para quien ya tiene juegos instalados ahí. |
| R2.8 | Herramientas por botella: abrir `C:` en Finder, `regedit`, `winecfg`, terminar todo (`wineserver -k`), exportar diagnóstico. |

## Fuera de alcance

- Compilar el runtime en la Mac del usuario.
- Varias versiones de Windows por botella al mismo tiempo.

## Pruebas

- Matriz: macOS 26.5 y 26.6 (y 27 beta cuando exista), M1 y M3 o posterior.
- El corpus completo con el runtime propio, comparado contra CrossOver: debe
  funcionar todo lo que funciona en CrossOver.
- Rendimiento con las herramientas de Recall (captura de cuadros, conteo de tirones).
