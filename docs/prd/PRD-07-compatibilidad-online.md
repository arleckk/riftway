# PRD-07: Compatibilidad con juegos en línea

| | |
|---|---|
| Estado | Exploración |
| Hito | M4 (investigación desde M2) |
| Relacionado | [PRD-05](PRD-05-perfiles-y-compatibilidad.md) (detección de anti-cheat), [RUNTIME-BUILD.md](../RUNTIME-BUILD.md) |

## Problema

Los juegos en línea son la razón principal por la que alguien quiere Riftway (DSR es uno),
y también los que más fallan. No suele ser por gráficos o rendimiento: es por
anti-cheats, DRM y controles de plataforma, diseñados para un Windows real.

## Objetivo

Que funcione **legítimamente** la mayor cantidad posible de juegos en línea, y que el
usuario sepa de antemano cuáles no y por qué. "Legítimamente" significa que el juego y
su anti-cheat funcionen como su desarrollador quiere, no que se engañen.

## La línea roja

Riftway **no**:
- oculta que el juego corre en Wine ni en una Mac ante un control de seguridad;
- finge hardware, drivers, identificadores de máquina o una plataforma para pasar un
  anti-cheat, DRM o verificación de plataforma;
- desactiva, bloquea, intercepta ni emula un anti-cheat;
- modifica binarios del juego o del anti-cheat.

Sí hace:
- implementar Windows con la mayor fidelidad posible (lo que hace Wine);
- identificarse honestamente para que proveedores y estudios puedan decidir;
- medir y explicar por qué un juego no funciona;
- trabajar con estudios y proveedores para que lo habiliten.

**Zona gris documentada:** presentar otra identidad de GPU para *habilitar una función
gráfica* (Recall se presenta como NVIDIA para ofrecer DLSS sobre MetalFX) no es un control
de seguridad. Se permite solo por perfil, nunca en juegos con anti-cheat, y se documenta.

Por qué importa: además de lo ético, evadir un anti-cheat pone en riesgo las cuentas de
los usuarios (bans) y convierte a Riftway en adversario de los estudios cuyo apoyo
necesita.

## Taxonomía de bloqueos

| Tipo | Ejemplos | ¿Lo puede resolver Riftway? |
|---|---|---|
| Anti-cheat con driver de kernel | XIGNCODE3 (confirmado en DSR), Riot Vanguard, nProtect GameGuard, EAC y BattlEye en modo kernel | No. Solo el proveedor (módulo para Wine o macOS) o el estudio (habilitarlo) |
| Anti-cheat de usuario con modo Wine opcional | EAC y BattlEye, que en Linux/Proton se habilitan por juego desde el portal del proveedor | Parcialmente: el estudio lo habilita, Riftway tiene que cumplir lo que ese modo espera. En macOS no está confirmado (ver Experimento 1) |
| Detección deliberada de Wine, VM o plataforma | Juegos que se cierran al ver `wine_get_version` | No (sería evasión). Sí: pedir al estudio una excepción |
| DRM | Denuvo, activaciones limitadas por hardware | Parcial: suele funcionar en Wine, pero cambios de runtime pueden contar como "otra máquina". Mantener estable la identidad del sistema dentro de la botella (no falsificarla) |
| APIs de Windows faltantes o incorrectas | Llamadas que el anti-cheat de usuario o el launcher hacen y Wine no implementa | **Sí**: es trabajo de Wine, se aporta upstream |
| Red y certificados | Raíces de certificados que el cliente exige (el caso coreano de Recall con DigiCert), proxies | Sí, con configuración honesta de la botella |

## Líneas de trabajo

### Experimento 1: ¿qué hace CrossOver 26 con los anti-cheats? (M2)

Las fuentes se contradicen: CodeWeavers dice que no da soporte a anti-cheats, y un sitio
de terceros afirma que CrossOver 26 ya corre algunos juegos con EAC, BattlEye y GameGuard.
Como el runtime de Riftway parte de las **fuentes publicadas de CrossOver 26**, la respuesta
está en el código:

1. Buscar en `crossover-sources-26.x` los cambios relacionados con anti-cheat (EAC, BattlEye, `ntoskrnl`, carga de drivers, módulos Unix).
2. Probar en CrossOver 26 un juego gratuito con EAC habilitado para Proton, con una cuenta desechable.
3. Documentar qué funciona, por qué y si el runtime de Riftway lo hereda.

#### Resultado: Digimon Super Rumble (XIGNCODE3) en `rw-0.1.1-spike` (2026-10-13)

**Entra al juego en línea** (File Island, canal 1, con otros jugadores) con cuenta desechable,
en una botella nueva del runtime propio, sin CrossOver y sin tocar el anti-cheat.

- Flujo: sitio web → `dsropen:` → puente → `SuperRumble Launcher.exe` (.NET 4.5 sobre Wine
  Mono) → `Client.exe` → `Client-Win64-Shipping.exe` (UE 5.4) sobre DXMT (D3D11 → Metal).
- **Requiere la casilla "DirectX 11 실행"** del launcher (`HKCU\…\DirectX11Use=1`). Sin ella
  el cliente usa D3D12, que el runtime deshabilita (`d3d12=`), y se queda en la pantalla de
  logos. El perfil del juego debe fijar ese valor.
- XIGNCODE3 corre en modo usuario: el cliente carga `XIGNCODE\x3_x64.xem` y lanza
  `xxd-0.xem` como proceso aparte de 32 bits (WoW64). No registró servicio ni driver
  (`ZwLoadDriver` solo aparece para `winebth`), y el servidor aceptó la sesión.
- Componentes (tres sesiones, mismo patrón): `x3_x64.xem` ("XIGNCODE3 SYSTEM" 3.5.0.63,
  firmado por Wellbia) se carga en el cliente ~9–10 s después de arrancar; `xxd-0.xem`
  ("XIGNCODE WatchDog K", 32 bits, firmado) corre como proceso aparte ~16–17 s después y
  vive toda la sesión; lo reescribe en cada arranque. `xmag_x64.xem` y `xnina_x64.xem`
  no son PE (datos cifrados); `xcorona_x64/arm64.xem` ("XIGNCODE3 SYSTEM" 5.0, x64 y
  **ARM64**) no se cargan como módulos y `xm.exe` nunca se lanzó. Que Wellbia ya publique
  un módulo ARM64 de Windows es relevante para la línea 4 (puente nativo).
- XIGNCODE escribe *alternate data streams* de NTFS (`XIGNCODE:{GUID}`,
  `Roaming:<hash>`); Wine en APFS los crea como archivos con `:` en el nombre. No impidió
  entrar. `XIGNCODE:{3629C49D…}` es una copia byte por byte de `xmag_x64.xem`, rehecha en
  cada arranque. También deja archivos `.dll` diminutos en `Temp` que no son DLLs.
- `xigncode.log` (cifrado) crece ~200 KB por sesión (680 KB tras cuatro): un perfil
  debería poder limpiarlo.
- Su `xigncode.log` está cifrado; la evidencia sale de `--wine-log`
  (`WINEDEBUG=fixme-all,+timestamp,+pid,+loaddll`, `DXMT_LOG_LEVEL=info`).
- Errores no bloqueantes: faltan los decodificadores de Media Foundation de
  `winegstreamer` (AAC `{e7889a8a…}`, H.264 `{1f1e273d…}`, separador MPEG-1 `{a8edbf98…}`):
  el runtime no incluía GStreamer, así que videos del juego y del launcher no se
  reproducían (resuelto en `rw-0.1.2-spike`, ver RUNTIME-BUILD.md fase 2, punto 8).
- Con decodificadores, la vista web del launcher (Wine Gecko 2.47) usa Media Foundation
  (pide AAC sin `codec_data`) y el launcher se cae en `mshtml` al cerrar su ventana,
  después de lanzar el cliente. El perfil de DSR apaga `winegstreamer` solo para
  `SuperRumble Launcher.exe` (`HKCU\Software\Wine\AppDefaults\…\DllOverrides`,
  `winegstreamer=""`); el cliente conserva los decodificadores. Los perfiles necesitan
  overrides de DLL por ejecutable.
  Kerberos ausente.
- DXMT: feature level 11_1, sin errores en toda la sesión (un solo aviso,
  `MakeWindowAssociation`). La primera corrida compiló 255 librerías Metal en la caché.
- Tiempos (desde 게임시작): proceso del cliente en 0.1 s, D3D11 a los 7 s, XIGNCODE a los
  10 s, su proceso auxiliar a los 17 s, audio a los 18 s, control a los 31 s.

Pendiente: estabilidad en sesiones largas, rendimiento (FPS, compilación de shaders en la
primera corrida) y si el resultado se mantiene tras actualizaciones de XIGNCODE.

### Línea 2: fidelidad de Windows

Registrar qué APIs fallan cuando arranca un anti-cheat de usuario (`WINEDEBUG` dirigido) y
aportar las implementaciones a Wine upstream. Es trabajo que también beneficia a Proton y a
CrossOver.

### Línea 3: identidad honesta de Riftway

| ID | Requisito |
|---|---|
| R3.1 | ✅ Cada botella expone `HKLM\Software\Riftway` (y su vista de 32 bits, `Wow6432Node`) con `Version`, `Runtime` y `Platform` = `macOS`, documentado públicamente. Se escribe al crear la botella y cada vez que se aplica su perfil; ningún perfil puede cambiarla. |
| R3.2 | Riftway no oculta `wine_get_version` ni ningún otro indicador de Wine. |
| R3.3 | Página para desarrolladores: cómo detectar Riftway y cómo habilitar el juego (whitelist), con el mismo modelo que Proton y Steam Deck. |

### Línea 4: puente nativo para anti-cheats (propuesta para proveedores)

En Linux, el modo Wine de EAC funciona porque el proveedor distribuye un módulo nativo que el
lado Windows carga a través de Wine. El equivalente en Mac sería:

- El proveedor distribuye un helper nativo de macOS, firmado y notarizado **con su propio
  Developer ID**.
- El runtime de Riftway carga del lado Unix solo bibliotecas firmadas por equipos de una
  lista permitida, y las expone al módulo Windows del anti-cheat.
- La integridad la aportan los mecanismos de macOS (SIP, hardened runtime, firma de código,
  notarización); el proveedor decide si le basta.

Riftway solo pone el mecanismo de carga, abierto y auditable. El anti-cheat lo pone el
proveedor. Esto requiere su interés; el objetivo de este PRD es dejar la propuesta lista y
documentada para presentarla.

### Línea 5: estudios y proveedores

- Plantilla de contacto: qué es Riftway, cuántos usuarios piden el juego, qué se necesita
  (modo Wine del anti-cheat, excepción en la detección de plataforma o el módulo de la Línea
  4) y evidencia técnica (logs y perfiles).
- **DSR, primer caso:** escribir a Move Interactive (desarrollador) y a Wellbia (XIGNCODE3)
  preguntando por un modo compatible con Wine o macOS. Documentar la respuesta.
- La base de compatibilidad ([PRD-05](PRD-05-perfiles-y-compatibilidad.md)) sirve de
  evidencia de demanda: votos y reportes por juego.

## Reglas para probar

- Nunca con cuentas principales: solo cuentas desechables y, cuando exista, servidores de
  prueba del estudio.
- Leer y respetar los términos de servicio de cada juego; si prohíben capas de compatibilidad,
  el juego queda `blocked` en la base.
- Ningún reporte público incluye tokens, correos ni identificadores de cuenta (mismas reglas
  de censura que el puente de URLs).

## Métricas

- Cada juego en línea del corpus con causa de bloqueo identificada (tipo de la taxonomía).
- Experimento 1 documentado antes de cerrar M2.
- Al menos un proveedor o estudio contactado con propuesta concreta antes de M4.
