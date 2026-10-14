# PRD-01: Instalar con doble clic

| | |
|---|---|
| Estado | §1–3 **implementado en M1**; §4–7 pendiente (M3) |
| Hitos | M1 (§1–3), M3 (§4–7) |
| Depende de | [PRD-02](PRD-02-runtime-y-botellas.md) (botellas), [PRD-03](PRD-03-puente-de-urls.md) (puentes) |

## Problema

Hoy, instalar un juego de Windows en Mac exige crear un prefijo, elegir dónde vive,
correr el instalador desde un menú, buscar el `.exe` que quedó dentro de `drive_c`,
crear accesos directos a mano y, si el juego usa un protocolo de URL, configurarlo uno
mismo. En PC, el usuario solo le da doble clic al instalador.

## Objetivo

Doble clic en un `.exe` o `.msi` descargado → Riftway explica qué es → el usuario
confirma → corre el asistente del juego → el juego queda en la biblioteca y en
Launchpad, con su ícono, y sus links web funcionan.

**Métricas de éxito**
- 100 % del corpus abre la hoja de análisis correcta (M1).
- ≥ 5 de 6 instaladores del corpus terminan en la biblioteca sin pasos manuales (M3).
- Mediana de < 3 clics de Riftway entre el doble clic y el inicio del asistente.
- Cero casos de esquemas del sistema reclamados o de asociación cambiada sin permiso.

## Historias de usuario

1. Como jugador, descargo `DSR_Setup.exe` en Safari, le doy doble clic y se instala
   como en Windows.
2. Como jugador, arrastro un `.exe` a la ventana o al ícono de Riftway en el Dock y
   pasa lo mismo.
3. Como jugador, antes de instalar veo quién firmó el archivo, de dónde lo bajé y si
   el juego tiene un anti-cheat que no funciona en Mac.
4. Como jugador, instalo el cliente de Steam y después los juegos de Steam aparecen
   en mi biblioteca.
5. Como jugador, abro un `.exe` portable (sin instalador) y lo agrego a la biblioteca.
6. Como jugador, decido si Riftway abre todos los `.exe` o solo cuando lo elijo en
   "Abrir con".

## Requisitos

### 1. Asociación con macOS (M1)

| ID | Requisito |
|---|---|
| R1.1 | `Info.plist` declara `CFBundleDocumentTypes` con `LSItemContentTypes` = `com.microsoft.windows-executable` y `com.microsoft.msi-installer` (verificados en macOS 26.6), rol `Viewer`, `LSHandlerRank` = `Alternate`. |
| R1.2 | La app recibe archivos en `application(_:open:)`, al arrastrarlos a la ventana y al ícono del Dock. Varios archivos a la vez se encolan. |
| R1.3 | En el primer arranque, una pantalla ofrece "Abrir archivos de Windows con Riftway". Si el usuario acepta: `NSWorkspace.setDefaultApplication(at:toOpen:)` para ambos tipos (macOS pide confirmación). Se puede cambiar en Ajustes › General. |
| R1.4 | Riftway nunca se vuelve predeterminada sin una acción explícita del usuario. |
| R1.5 | Si otra app (CrossOver, Whisky) es la predeterminada, Ajustes lo muestra y ofrece cambiarlo; no se cambia en silencio. |
| R1.6 | Launchers comunes (Steam, Epic Games, GOG Galaxy, EA app, Ubisoft Connect, Battle.net): en una Mac sus sitios dan la app de macOS, así que la sección Launchers de la barra lateral (también desde la biblioteca vacía y el menú Archivo), con el ícono de cada uno (`app/Launchers`, marcas de sus dueños), descarga el instalador de Windows del enlace oficial del fabricante a `<home>/Installers/<launcher>/`. Se usa solo si la descarga termina en un dominio del fabricante por HTTPS y, si es `.exe`, la firma Authenticode es válida y es del fabricante (el MSI de Epic se acepta por el dominio mientras no se verifiquen firmas de MSI). Luego sigue el flujo normal: hoja de análisis e instalación. CLI: `riftway launchers`, `riftway launcher-download <launcher>`. |

### 2. Análisis del archivo (M1, solo lectura, sin ejecutar nada)

`InstallerAnalyzer` produce un `InstallerReport`:

| Campo | Fuente |
|---|---|
| Arquitectura (x86, x64, ARM64) | Header PE, campo `Machine` |
| Subsistema (GUI, consola) | Header opcional PE |
| Producto, empresa, versión, descripción | Recurso `VS_VERSIONINFO` |
| Ícono | Recurso `RT_GROUP_ICON` → `.icns` |
| Nivel de ejecución (`requireAdministrator`…) | Manifiesto incrustado (`RT_MANIFEST`) |
| Firma Authenticode: firmante, validez | Tabla de certificados PE (`IMAGE_DIRECTORY_ENTRY_SECURITY`) |
| Tipo de instalador | Firmas: NSIS (`NullsoftInst`, `Nullsoft.NSIS.exehead`), Inno Setup (`Inno Setup Setup Data`), InstallShield, WiX Burn (sección `.wixburn`), Squirrel, MSI (contenedor CFB) |
| Origen | `kMDItemWhereFroms` y atributo de cuarentena |
| Archivos acompañantes | `.bin`, `.cab`, `.7z` en la misma carpeta (instaladores de varias partes, típicos de GOG) |
| Perfil conocido | Búsqueda por producto, empresa y hash en el `ProfileStore` ([PRD-05](PRD-05-perfiles-y-compatibilidad.md)) |

| ID | Requisito |
|---|---|
| R2.1 | El análisis lee el archivo sin ejecutarlo y termina en < 1 s para archivos de hasta 200 MB (lectura de headers, recursos y overlay acotada). |
| R2.2 | Clasifica el archivo como **instalador**, **programa portable** o **no soportado** (DLL, driver `.sys`, ARM64 sin x64, archivo dañado). |
| R2.3 | Si el perfil conocido marca un anti-cheat incompatible, la hoja lo dice antes del botón Instalar ("Este juego usa XIGNCODE3, que no funciona con Wine"). El usuario puede continuar. |
| R2.4 | Archivos sin firma o con firma inválida muestran un aviso neutral, no un bloqueo. |

### 3. Hoja "Instalar" (M1 la muestra, M3 la ejecuta)

Contenido:
- Ícono, nombre del producto, empresa, versión, firmante y origen ("Descargado de
  digimonsuperrumble.com").
- Destino: **botella nueva** (predeterminado; nombre = producto) o una existente
  (para instalar en la de Steam, por ejemplo).
- Ubicación: disco interno o externo; mismas reglas que Recall (APFS o Mac OS
  Extended, no sensible a mayúsculas, no de red ni en la nube).
- Espacio libre en el destino.
- Avisos: anti-cheat, sin firma, instalador de varias partes con piezas faltantes.
- Botones: **Instalar** y Cancelar. "Opciones avanzadas" despliega backend gráfico,
  versión de Windows y runtime.

### 4. Ejecución del instalador (M3)

| ID | Requisito |
|---|---|
| R4.1 | Crear la botella ([PRD-02](PRD-02-runtime-y-botellas.md)) si es nueva, con `wineboot --init`, plantilla Windows 10 64 bits. |
| R4.2 | **Snapshot previo:** registro (claves y valores de `system.reg` y `user.reg`) e inventario de `drive_c` (ruta, tamaño, mtime), excluyendo `windows/`. |
| R4.3 | Copiar el instalador y sus archivos acompañantes a `drive_c/ProgramData/Riftway/Installers/<id>/` y ejecutarlo desde ahí. La botella no necesita acceso a `~/Downloads`. |
| R4.4 | `.exe`: `start /wait` con la ruta copiada. `.msi`: `msiexec /i`. El asistente del juego se muestra normal; Riftway no lo automatiza. |
| R4.5 | Mientras corre, Riftway muestra "Instalando <juego>…" con el log de Wine accesible y un botón Detener (`wineserver -k` de esa botella, con confirmación). |
| R4.6 | Fin de la instalación = el proceso del instalador terminó. Si el instalador dejó corriendo el launcher ("Ejecutar ahora"), Riftway lo detecta como proceso nuevo en la botella, no lo mata y lo marca como primera sesión. |
| R4.7 | Si el instalador termina con error o no deja nada nuevo, la botella nueva se conserva y se ofrece "Reintentar" o "Mover a la Papelera". |

### 5. Descubrimiento (diff) (M3)

`PrefixDiff(before, after)` produce un `InstallResult`:

| Hallazgo | Cómo se detecta | Qué hace Riftway |
|---|---|---|
| Programas | `.lnk` nuevos en el menú Inicio (común y de usuario) y en el escritorio de la botella → destino, argumentos, carpeta, ícono (formato MS-SHLLINK) | Entradas en la biblioteca; se excluyen los que apuntan a desinstaladores, readmes y URLs |
| Programa principal | Heurística: el `.lnk` cuyo nombre coincide con el producto; si no, el `.exe` más grande enlazado; el usuario puede cambiarlo | Botón Jugar |
| Desinstalador | `HKLM\…\CurrentVersion\Uninstall\*`: `DisplayName`, `DisplayIcon`, `UninstallString`, `InstallLocation`, `Publisher` | Acción "Desinstalar juego" |
| Protocolos de URL | Claves nuevas en `HKCR` con `URL Protocol` (`URLProtocolRegistration.discover`, ya existe) | Se agregan al `.app` puente del juego ([PRD-03](PRD-03-puente-de-urls.md)) |
| Asociaciones de archivo | `HKCR\.<ext>` nuevas | Se listan; no se registran en macOS en v1 |
| Drivers y servicios | `HKLM\System\CurrentControlSet\Services\*` con `Type` = 1 o 2 (kernel), y archivos `.sys` nuevos | Aviso de compatibilidad; se cruza con firmas de anti-cheat ([PRD-05](PRD-05-perfiles-y-compatibilidad.md)) |
| Dependencias | Runtimes de Visual C++, DirectX, .NET instalados | Se registran en `bottle.json` |

| ID | Requisito |
|---|---|
| R5.1 | El diff de una instalación típica (≤ 100 000 archivos) tarda < 10 s. |
| R5.2 | **Redescubrimiento:** se repite el diff al terminar cada sesión de la botella. Los launchers instalan el juego después del instalador (DSR descarga `Client`; Steam descarga juegos), y así aparecen programas y protocolos nuevos sin reinstalar. |
| R5.3 | Una pantalla de resultado muestra lo encontrado, con casillas para lo que se agrega a la biblioteca y a Launchpad. |

### 6. Puentes y biblioteca (M3)

| ID | Requisito |
|---|---|
| R6.1 | Por juego se genera `~/Applications/Riftway/<Juego>.app` con su ícono y los protocolos descubiertos (`ShimBundle`, ya existe). Abrirlo lanza el programa principal; los URLs van a la botella. |
| R6.2 | El puente se regenera cuando el redescubrimiento encuentra protocolos nuevos o cambia el programa principal. |
| R6.3 | Para hacer el puente predeterminado de un esquema se pregunta una vez por juego, no por URL. |

### 7. Programas portables (M3)

| ID | Requisito |
|---|---|
| R7.1 | Un `.exe` que no es instalador ofrece "Agregar a la biblioteca" (botella nueva o existente) y "Abrir una vez". |
| R7.2 | "Agregar" copia la carpeta del programa dentro de la botella (`drive_c/Games/<nombre>`), o la referencia en su lugar si el usuario lo elige (se monta como unidad `D:`, solo esa carpeta). |

## Estado de M1

Implementado en `Sources/RiftwayCore/Analysis/` y `Sources/RiftwayApp/`:
- R1.1–R1.5: tipos de documento (`app/Info.plist`), apertura desde Finder, el Dock,
  arrastrar y "Abrir instalador…", oferta en el primer arranque y Ajustes.
- §2: lector de PE propio (headers, recursos, versión por idioma, manifiesto, íconos),
  detección de NSIS, Inno, InstallShield, WiX Burn, Squirrel, 7-Zip SFX y MSI, lector de
  MSI (Compound File + Summary Information), origen y archivos acompañantes.
- Authenticode verificado sin `CMSDecoder` (que no acepta el contenido de Authenticode):
  hash de la imagen, `messageDigest`, firma RSA/ECDSA del firmante y cadena de macOS.
  Probado con los binarios firmados de DSR (Move Interactive, cadena GlobalSign R45) y con
  un archivo alterado.

Pendiente: verificar firmas de MSI (hoy se reportan como presentes sin verificar),
coincidencia con perfiles (M4) y el botón Instalar (M3).

## Estado de M3

Implementado (`Sources/RiftwayCore/Library/`, `Sources/RiftwayApp/LibraryModel.swift`):
- §4: botella nueva por instalación con línea base (`baseline.json`), instalador y sus
  archivos acompañantes copiados a `C:\ProgramData\Riftway\Installers\<id>\`, `.exe` directo
  y `.msi` con `msiexec /i`, botón Detener (`wineserver -k`). El descubrimiento espera a
  que Wine guarde el registro (el servidor lo escribe al salir; con un launcher abierto se
  usa lo guardado y el redescubrimiento completa).
- §5: `ShellLink` (MS-SHLLINK), accesos directos del menú Inicio y del escritorio,
  **accesos directos web** (`.url`: DSR abre su sitio, cuyo Start usa `dsropen`),
  desinstaladores, protocolos, extensiones, drivers de kernel, ejecutables nuevos; el
  redescubrimiento corre cuando la botella se cierra, la haya abierto quien sea
  (`WineServer.isRunning`: el candado del `wineserver`).
- §6: puente por juego con ícono, protocolos y Jugar; la pantalla de resultado pregunta
  una vez si el juego abre sus enlaces.
- §7: programas sin instalador (carpeta propia o solo el `.exe`).
- Biblioteca (PRD-04): Jugar/Detener, "Abierto" para cualquier sesión, otros programas,
  Configurar Jugar (lo descubierto, el último enlace que mandó el sitio o un comando),
  modo diagnóstico, overrides de DLL por programa, desinstalar, Papelera.

Corpus (2026-10-13, runtime `rw-0.1.2-spike`, instaladores en modo silencioso para la prueba):

| Instalador | Formato | Tiempo | Resultado |
|---|---|---|---|
| Digimon SuperRumble | NSIS | 35–50 s | Jugar abre su sitio (`.url`); `dsropen`; desinstalador; ícono |
| Steam 2.10.91.91 | NSIS | 36 s | `steam.exe`; `steam`/`steamlink` aparecen al cerrar la primera sesión (los registra Steam al arrancar, como `hex(1):`) |
| Inno Setup 7.1.0 (en lugar de un juego de GOG, que requiere cuenta) | Inno | 53 s | `ISIDE.exe`, su FAQ (web), `.iss`, desinstalador |
| Epic Games Launcher 20.3.3 | MSI | 58 s | `EpicGamesLauncher.exe`; `com.epicgames.launcher`; desinstalador MSI |
| Visual C++ 2015-2022 x64 14.44 | WiX Burn | 36 s | Componente: sus dos MSI y las DLL en `system32`, sin programas (resultado esperado) |

Pendiente para después: un instalador Inno de varias partes (`.bin`), con un juego de GOG.

## Fuera de alcance

- Automatizar asistentes de instalación (clics por el usuario), salvo dependencias
  silenciosas conocidas (`vcredist /quiet`).
- `.bat`, `.lnk` y `.reg` sueltos (se evaluarán después de v1).
- Instalar juegos de tiendas por API; se usan sus propios clientes (Steam, Epic).

## Diseño técnico

**Nuevos tipos en `RiftwayCore`**

```swift
struct InstallerReport { kind: .installer(InstallerType) | .portable | .unsupported(reason)
                         machine, product, company, version, icon, executionLevel,
                         signature: SignatureStatus, origin: [URL], companions: [URL],
                         profile: ProfileMatch? }
struct PrefixSnapshot { registry: [String: [String: String]], files: [String: FileStamp] }
struct InstallResult  { programs: [Shortcut], primary: Shortcut?, uninstall: UninstallEntry?,
                        protocols: [URLProtocolRegistration], associations: [String],
                        drivers: [DriverEntry], dependencies: [String] }
```

- `PEFile`: lector de PE propio (DOS header → NT headers → secciones → directorio
  de recursos y de seguridad), sin dependencias externas. La verificación de
  Authenticode se hace con `Security.framework` (CMS) sobre el blob PKCS#7.
- `ShellLink`: lector del formato MS-SHLLINK (`LinkTargetIDList`, `LinkInfo`,
  `StringData`). Las rutas de destino se convierten con `Bottle.unixURL(forWindowsPath:)`.
- `WineRegistry` ya existe; se amplía para exponer DWORD (`Type` de servicios).
- El análisis corre fuera del hilo principal; la hoja aparece con un estado de carga
  si tarda más de 150 ms.

**Seguridad**
- Wine no es un sandbox. Las botellas nuevas no tienen la unidad `Z:` (que expone todo
  el disco de la Mac) ([PRD-02](PRD-02-runtime-y-botellas.md) R2.4). Por eso el instalador se copia
  dentro de la botella.
- `winemenubuilder` se desactiva (`WINEDLLOVERRIDES=winemenubuilder.exe=d`); Riftway
  hace su propio descubrimiento.
- Ningún dato del instalador (nombres, rutas) se interpola en comandos de shell;
  todo se lanza con argumentos (`Process`/`posix_spawn`).

## Pruebas

- Unitarias: `PEFile` con ejecutables sintéticos (generados en CI con MinGW y
  `makensis`), `ShellLink` con `.lnk` de muestra, `PrefixDiff` con prefijos falsos
  (como las pruebas actuales de `BottleTests`).
- Integración: el corpus del [plan](../PLAN.md#corpus-de-prueba), en macOS 26.x,
  M1 y M3 o posterior.
- Manual: flujo completo de DSR, desde el sitio web hasta el launcher.

## Preguntas abiertas

1. ¿Una botella por juego siempre (aislamiento) o compartir cuando son del mismo
   cliente (todos los de Steam en la botella de Steam)? Propuesta: por juego, salvo
   que se instale "en la botella de…" explícitamente.
2. ¿El redescubrimiento tras cada sesión debe preguntar o agregar en silencio?
   Propuesta: agregar programas en silencio; preguntar solo para protocolos nuevos.
