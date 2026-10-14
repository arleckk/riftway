# PRD-08: Controles

| | |
|---|---|
| Estado | Capas 0 y 2 implementadas, con editor en la app (2026-10-14) |
| Hito | Después de M5 (propuesto como M6) |
| Relacionado | [PRD-05](PRD-05-perfiles-y-compatibilidad.md) (perfiles), [PRD-07](PRD-07-compatibilidad-online.md) (línea roja) |

## Problema

Jugar con control en la Mac tiene tres casos:

1. **El juego soporta control** (XInput, como la mayoría): solo hay que entregarle el
   control de la Mac como un control de Xbox.
2. **El programa no soporta control** (launchers, juegos viejos): hay que traducir el
   control a teclado y mouse, como Steam Input.
3. **Un juego son varios programas**: en DSR, `SuperRumble Launcher.exe` (.NET: se
   maneja con mouse) lanza `Client-Win64-Shipping.exe` (UE 5.4, se juega con teclado y
   mouse). Ninguno de los dos soporta control. El mapeo tiene que seguir al programa
   que está al frente.

## Lo que encontramos

Probado con un DualShock 4 por Bluetooth en `rw-0.1.2-spike` (sonda:
[`runtime/probes/input_probe.c`](../../runtime/probes/input_probe.c), lista los controles de
DirectInput y registra cada botón de XInput).

- **El runtime ya trae la pila completa**: `winebus.sys` con backends SDL2 e IOHID,
  `winexinput.sys`, XInput 1.1–1.4, DirectInput, `gameinput.dll` y
  `Windows.Gaming.Input`.
- **Cargar XInput no es soportar control**: `Client-Win64-Shipping.exe` carga
  `XINPUT1_4.dll` ~28 s después de arrancar (lo trae Unreal Engine), pero DSR no asigna
  acciones al control. Con la capa 0 activa, la sesión del 2026-10-14 carga
  `winexinput.sys` (el DS4 llega como control de Xbox) y el juego no reacciona, como ya
  sabía quien lo juega. La detección automática no puede basarse en las importaciones:
  el modo de cada programa lo dicen el perfil o el jugador.
- **Sin ajustes, el DS4 no llega a XInput**: Wine prefiere entregar los controles de
  PlayStation "crudos" (hidraw), igual que Windows, donde el DS4 tampoco es XInput
  (`winebus.sys/main.c`, `is_hidraw_enabled`). DirectInput lo ve; XInput no.
  `HKLM\System\CurrentControlSet\Services\WineBus\Devices\054c/09cc` con `Hidraw`=0 hace
  que SDL lo presente como gamepad y `winexinput.sys` lo exponga como control de Xbox.
- **Sin ajustes, tampoco llegan los botones**: SDL en macOS usa el framework
  GameController de Apple, que solo entrega eventos a la app al frente, y el bus de Wine
  corre en `winedevice.exe`, que nunca lo está. Con `SDL_JOYSTICK_MFI=0` y
  `SDL_JOYSTICK_ALLOW_BACKGROUND_EVENTS=1`, SDL lee el control por HID y todo llega:
  ✕→A, ○→B, □→X, △→Y, L1→LB, R2→RT, sticks.
- **Saber qué programa está al frente desde macOS es fácil y no toca secretos**: el
  proceso de Wine al frente (`NSWorkspace.frontmostApplication`) tiene como
  `proc_name` el `.exe` de Windows (`ISIDE.exe`) y como `proc_pidpath` su ruta dentro de
  la botella. No hace falta leer argumentos (donde van los tokens de `dsropen`).
- macOS ve el control con GameController (`GCController`, con
  `shouldMonitorBackgroundEvents`) aunque Riftway no esté al frente.

## Diseño propuesto

### Capa 0: el control llega al juego (implementada)

Toda botella: `SDL_JOYSTICK_MFI=0`, `SDL_JOYSTICK_ALLOW_BACKGROUND_EVENTS=1` y
`Hidraw`=0 para DualShock 4, DualSense y DualSense Edge (`settings.reg`). Los juegos con
XInput (DSR incluido) funcionan con controles de Xbox, PlayStation y los que SDL conoce,
sin configurar nada. Falta: una opción por juego "Presentar el control de PlayStation
como PlayStation", para los pocos juegos que lo soportan crudo (íconos de PS, gatillos
adaptativos).

### Capa 1: remapear el control de Xbox

Cambiar botones, invertir ejes o usar el diseño de Nintendo, para el juego que sí soporta
control. SDL ya lo permite con cadenas de mapeo (`SDL_GAMECONTROLLERCONFIG`, que winebus
lee también del registro). Alcance: por botella, no por programa. Suficiente para empezar.

### Capa 2: control → teclado y mouse por programa ("Steam Input")

Un ayudante nativo, `riftway-input`, que el puente o la app inician junto con la sesión del
juego y que termina con ella:

1. Lee el control con GameController (en segundo plano).
2. Mira el programa al frente: si es un proceso de **esta botella** (por su ruta dentro del
   prefijo), toma su `.exe` y elige el **conjunto de acciones** de ese programa.
3. Traduce según ese conjunto y envía eventos de teclado y mouse a macOS (`CGEvent`), que
   el driver de Mac de Wine recibe como cualquier teclado y mouse.

Conjuntos de acciones, por programa, en el perfil del juego o editados por el jugador
(una pantalla como la de Steam: el control dibujado y cada botón con su tecla):

| Modo | Para | Qué hace |
|---|---|---|
| `native` | Juegos con XInput | Nada: el control llega por la capa 0 |
| `desktop` | Launchers, menús | Stick derecho mueve el cursor, A = clic, B = clic derecho, cruceta = flechas, Start = Enter, stick izquierdo = scroll |
| `keyboard` | Juegos sin control | Cada botón o dirección a una tecla o botón del mouse; stick derecho como mouse |
| `off` | — | Nada |

Para DSR: `SuperRumble Launcher.exe` en `desktop` y `Client-Win64-Shipping.exe` en
`keyboard`, con XInput apagado para el cliente (así no recibe nada por las dos vías si
algún día lo lee). Al cambiar el programa al frente (el launcher lanza el cliente) cambia el
conjunto, sin que el jugador haga nada.

Para que un juego en modo `keyboard` que **también** lee XInput no reciba cada botón dos
veces, ese programa lleva XInput apagado con los overrides por programa que ya existen
(`program_dll_overrides`: `xinput1_1`…`xinput1_4`, `xinput9_1_0` = "").

Permisos: enviar eventos con `CGEvent` requiere que el jugador autorice a
`riftway-input` en Ajustes del Sistema › Privacidad › Accesibilidad. Se pide solo la
primera vez que un juego usa `desktop` o `keyboard`; `native` no lo necesita.

### Por qué del lado de macOS y no dentro de la botella

La alternativa es un `.exe` en la botella que lee XInput y llama a `SendInput` (como
JoyToKey). Es más simple, pero:
- Windows marca esos eventos como inyectados (`LLKHF_INJECTED`), y los anti-cheats los
  tratan como herramientas de macros: XIGNCODE3 en particular detecta y bloquea programas
  de macros, con riesgo de ban.
- Un proceso extra dentro de la botella es visible para el anti-cheat como un programa
  desconocido.

Del lado de macOS, el juego recibe eventos de teclado y mouse como los de cualquier
dispositivo, igual que con Steam Input en Windows (que presenta dispositivos virtuales).

### La línea roja (PRD-07)

- **Mapeo 1 a 1**: una pulsación produce una tecla. Sin macros, turbo, secuencias
  temporizadas ni "aim assist": eso sería automatizar el juego, no adaptar un control.
- Riftway no oculta nada: los eventos son los del sistema y el perfil documenta el modo.
- En juegos con anti-cheat, `keyboard` y `desktop` muestran un aviso la primera vez:
  algunos términos de servicio prohíben remapeadores. `native` (capa 0) es el control
  real del jugador y no lleva aviso.

### Perfil (PRD-05)

```json
"controller": {
  "programs": {
    "SuperRumble Launcher.exe": { "mode": "desktop" },
    "Client-Win64-Shipping.exe": { "mode": "keyboard", "bindings": { "…": "…" } }
  }
}
```

Con `keyboard`, `"bindings": {"a": "Space", "b": "Escape", "lt": "MouseRight", "rs": "Mouse", …}`.
Los conjuntos editados por el jugador se guardan en la botella, encima de los del perfil,
como las demás opciones.

## Preguntas abiertas

- ¿Steam para Mac puede hacer esto hoy si se agrega el puente como juego que no es de
  Steam? No verificado; si funciona, es una alternativa que documentar, no un reemplazo.
- Mouselook: los juegos que capturan el mouse usan el parche `WINEMAC_MOUSELOOK`, que lee
  movimiento crudo; hay que probar si el movimiento sintético de `CGEvent` le llega.
- Vibración y luz del DS4 con `Hidraw`=0 (SDL la soporta; falta probarla en un juego).
- Varios controles a la vez y juegos locales para dos jugadores.

## Plan

1. ✅ Capa 0 por defecto (este PRD).
2. ✅ DSR con la capa 0: el control llega (`winexinput.sys`), el juego no lo usa.
3. ✅ `Riftway Input` con `desktop` y `keyboard`, detección del programa al frente y
   permiso de Accesibilidad. Probado con un DualShock 4 en `ISIDE.exe` (corpus): las
   teclas llegan a Wine, el touchpad mueve el cursor y el ayudante se cierra al terminar
   la sesión. **DSR jugado con control (2026-10-14)**: launcher en `desktop`, cliente con
   el mapeo de Steam Input del jugador (cruceta = habilidades del Digimon 1 `Q W E R`;
   L1 + cruceta, Digimon 2 `A S D F`; R1 + cruceta, Digimon 3 `Z X C V`; caras con
   L1/R1 = `1`–`4`), más el stick derecho como mouse para la cámara
   (`--pointer touchpad,rightStick`).
4. ✅ Editor en la app (clic derecho › Configurar control…): controles conectados con
   familia y batería, modo por programa, botones con los nombres de cada control,
   asignar una tecla presionándola, clics, capas, qué mueve el mouse, importar de
   Steam Input y prueba en vivo (el botón presionado se ilumina y se selecciona).
   Capas renombrables (los botones que las mantienen se actualizan). **Exportar** guarda
   la configuración de todo el juego (`riftway.controller`, esquema 1: cada programa con
   su modo y mapeo, sin datos del jugador ni de la botella); **Importar** acepta ese
   archivo (se combina por programa) o un `.vdf` de Steam para el programa elegido. CLI:
   `riftway controller <juego> --export/--import archivo.json`.
5. ✅ Sección `controller` de los perfiles: el de DSR (revisión 2) trae el launcher en
   `desktop` y el cliente con el mapeo del jugador que lo probó (capas L1 y R1). Se
   escribe en botellas sin `controller.json`; el editor ofrece "Usar el del perfil".
6. Capa 1 (remapeo de SDL) y la opción de PlayStation crudo.

## Implementación (capa 2)

- `controller.json` en la botella: modo por programa (`native`, `desktop`, `keyboard`,
  `off`), conjuntos de acciones con capas y fuentes de puntero (`ControllerLayout`).
  `riftway controller <juego> --program EXE (--mode … | --import archivo.vdf)`.
- **Importar Steam Input** (`SteamInputImport`): lee `controller_*.vdf` (exportado o de
  `userdata`): botones, cruceta, sticks como cruceta o mouse, gatillos, `switches`,
  touchpad (clic por mitades, `absolute_mouse` como puntero) y capas `hold_layer`. Lo que
  solo Steam hace (salida XInput, giroscopio, acciones del sistema, paletas traseras) se
  informa y se omite. No guarda el `creator` (la cuenta de Steam).
- **Riftway Input** (`Sources/RiftwayInput`, `Contents/Helpers/Riftway Input.app`): app de
  fondo (sin Dock), abierta con LaunchServices para que el permiso de Accesibilidad sea
  suyo y no del puente. Una por botella (candado `input.lock`). Lee el control con
  GameController en segundo plano, identifica el programa al frente por el `argv[0]` que
  Wine le pone (la ruta del `.exe` dentro del prefijo; nunca lee los argumentos), aplica
  el modo de ese programa, suelta todo al cambiar de programa, recarga `controller.json`
  si cambia y se cierra cuando termina la sesión de Wine.
- La inician el puente (en cada lanzamiento) y la app (Jugar) si `controller.json` lo
  necesita.
- Firma ad hoc: macOS liga el permiso de Accesibilidad a la compilación (el `cdhash`). Al
  recompilar, la entrada de la lista deja de servir aunque siga activada, y quitarla con
  "–" no siempre basta: `tccutil reset Accessibility com.riftway.input` la borra de verdad;
  luego se abre el ayudante, se activa en Ajustes y se vuelve a abrir. Por eso Riftway se
  instala en `/Applications` y solo se reinstala cuando cambia el ayudante. Con Developer
  ID el permiso sobrevive a las actualizaciones.
- `argv[0]`: un programa abierto desde macOS lo tiene con su ruta dentro del prefijo; uno
  abierto por otro programa de Windows (el juego de DSR, que abre `Client.exe`), con su
  ruta de Windows (`C:\…`). En ese caso pertenece a la botella si su carpeta de trabajo
  está en el prefijo. Probado con `cmd /c start` en el corpus.

## Controles detectados

`ControllerFamily`: DualShock 4, DualSense (y Edge), Xbox, Switch Pro, Joy-Con y genérico,
por la categoría que da GameController o, en HID, por fabricante y producto. Cada familia
da los nombres de los botones (✕ ○ □ △ / A B X Y / B A Y X de Nintendo, L1 / LB / L…).
Los botones se guardan por posición (nombres de Xbox), así que un mapeo sirve con
cualquier control. GameController lee los controles que macOS soporta; los genéricos
solo se listan por HID (sin abrirlos, para no pedir Monitoreo de entrada): les llega a los
juegos con soporte de control por Wine (SDL), pero Riftway Input no puede traducirlos.

`scripts/build-app.sh` acepta `INPUT_HELPER_FROM=<Riftway Input.app instalado>` para
reutilizar un ayudante que no cambió y conservar su permiso de Accesibilidad.

