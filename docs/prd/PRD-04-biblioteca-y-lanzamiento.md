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

### Diagnóstico

| ID | Requisito |
|---|---|
| R3.1 | Logs por sesión en `~/Library/Logs/Riftway/<botella>/`, con `WINEDEBUG` configurable desde la UI. |
| R3.2 | "Exportar reporte": versión de macOS, chip, runtime, perfil, `bottle.json`, últimos logs. Se quitan rutas del usuario y se censuran tokens y correos con las mismas reglas que el puente. |
| R3.3 | Detector de causas comunes en los logs: DLL faltante, driver de kernel rechazado (anti-cheat), D3D12 no disponible, Rosetta ausente. |

## Fuera de alcance (v1)

- Medición de FPS propia (se usa el HUD de Metal).
- Sincronización de partidas guardadas en la nube.
