# PRD-04: Biblioteca y lanzamiento

| | |
|---|---|
| Estado | Borrador |
| Hito | M3 |

## Objetivo

Una ventana principal donde están todos los juegos instalados, se lanzan con un
clic, se ajustan por juego y se diagnostican sin abrir Terminal.

## Requisitos

### Biblioteca

| ID | Requisito |
|---|---|
| R1.1 | Cuadrícula de juegos con ícono, nombre, estado de compatibilidad ([PRD-05](PRD-05-perfiles-y-compatibilidad.md)) y botón Jugar. |
| R1.2 | Estados por juego: listo, corriendo, actualizando (el launcher está abierto), disco desconectado, roto (falta el programa principal). |
| R1.3 | Menú por juego: Jugar, abrir otro programa de la botella, Ajustes, Abrir carpeta, Desinstalar juego (ejecuta su `UninstallString`), Mover botella a la Papelera. |
| R1.4 | Vacía: invita a arrastrar un instalador o a elegir uno. |
| R1.5 | Portada propia: una imagen arrastrada sobre la portada (o elegida desde el menú del juego o su pestaña Avanzado) reemplaza la que Riftway dibuja con el ícono, y sus colores tiñen la página del juego y el modo sillón. Riftway guarda una copia en la botella (`cover.png`, máx. 1200 px); quitarla vuelve a la dibujada. CLI: `riftway cover <juego> <imagen> \| --reset`. |
| R1.6 | Juegos de un launcher: cuando un launcher instala un juego (por ahora Steam: `steamapps/appmanifest_*.acf` instalados, en todas sus bibliotecas), Riftway pregunta cada vez si lo agrega a la biblioteca, al iniciar y al cerrar el launcher. Cada juego agregado es su propia entrada (`<botella>/Games/<appid>/`) con la portada del launcher, su análisis de anticheat y su app puente; Jugar abre `steam://rungameid/<appid>` en la botella del launcher, que lo arranca con sus actualizaciones y su nube. La botella corre siempre con el perfil del launcher (los argumentos del webhelper de Steam), también cuando la arranca Jugar, el acceso directo o un enlace del juego (desinstalar, controles). Los que no se agregan no se vuelven a ofrecer (`Games/declined.json`) y siguen en el resumen del launcher. El control lo maneja el launcher (Steam Input): Riftway no arranca su entrada de control para esos juegos y su pestaña Controles abre la configuración de Steam. "Corriendo" se detecta por los procesos de Wine cuyo nombre (`argv[0]`, ruta de Windows) está en la carpeta del juego. Desinstalar lo hace el launcher (`steam://uninstall/<appid>`) y Riftway quita la entrada en cuanto el launcher borra su manifiesto (lo revisa cada 10 s con el launcher abierto, al volver a la ventana de Riftway y al abrirla); mover a la Papelera solo quita la entrada. CLI: `riftway store-games <launcher>` y `riftway store-add <launcher> <appid>`. |

### Lanzamiento

| ID | Requisito |
|---|---|
| R2.1 | El `Supervisor` lanza el programa con el entorno del perfil y de la botella, y emite eventos (iniciado, ventana visible, salió, código de salida). Reutiliza el modelo de eventos JSON del worker de Recall. |
| R2.2 | Un juego está "corriendo" mientras la botella tenga procesos (wineserver vivo); termina cuando el wineserver de la botella sale. |
| R2.3 | Al salir el juego se lanza el redescubrimiento ([PRD-01](PRD-01-instalar-con-doble-clic.md) R5.2). |
| R2.4 | Terminar a la fuerza (`wineserver -k`) desde la biblioteca y desde el menú del Dock. |
| R2.5 | Un cierre en los primeros 30 s se marca como fallo de arranque y ofrece diagnóstico. |

### Ajustes por juego

- Backend gráfico (DXMT, wined3d, DX12 según la decisión), argumentos extra,
  variables de entorno, versión de Windows, modo Retina, HUD de Metal, Game Mode,
  mouse crudo.
- Cada ajuste muestra si viene del perfil o lo cambió el usuario, y se puede volver
  al valor del perfil.
- Tamaño de la interfaz (pestaña Avanzado): 100 %, 150 % o 200 %, como la escala de
  Windows, o lo que diga el perfil (Steam: 200 %). Es el DPI que ven los programas que
  nombra el perfil (`app_dpi`) o el programa principal (`WINE_APP_DPI`). Wine da 96 DPI
  en una pantalla Retina, así que los launchers se dibujan a la mitad. Al cambiarlo,
  o el perfil, se reconstruyen todas las apps puente de la botella, también las de
  los juegos de su launcher.

### Diagnóstico

| ID | Requisito |
|---|---|
| R3.1 | Logs por sesión en `~/Library/Logs/Riftway/<botella>/`, con `WINEDEBUG` configurable desde la UI. |
| R3.2 | "Exportar reporte": versión de macOS, chip, runtime, perfil, `bottle.json`, últimos logs. Se quitan rutas del usuario y se censuran tokens y correos con las mismas reglas que el puente. |
| R3.3 | Detector de causas comunes en los logs: DLL faltante, driver de kernel rechazado (anti-cheat), D3D12 no disponible, Rosetta ausente. |

## Fuera de alcance (v1)

- Medición de FPS propia (se usa el HUD de Metal).
- Sincronización de partidas guardadas en la nube.
