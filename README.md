# Riftway

> Plan del producto y PRDs: [docs/PLAN.md](docs/PLAN.md). Hoy están implementados el
> hito M0 (puente de URLs) y M1 (app, asociación con `.exe`/`.msi` y análisis de
> instaladores). Licencia: [Apache 2.0](LICENSE).

## La app (M1)

```sh
scripts/build-app.sh          # arma build/Riftway.app (firma ad hoc)
open build/Riftway.app
```

Abre un `.exe` o `.msi` (doble clic si Riftway es la app predeterminada, "Abrir con",
arrastrándolo a la ventana o al Dock, o ⌘O) y Riftway lo analiza sin ejecutarlo: tipo de
instalador, producto, arquitectura, permisos, firma Authenticode, origen de la descarga y
archivos acompañantes. En el primer arranque ofrece volverse la app predeterminada para
archivos de Windows. La instalación llega en M3, sobre el runtime propio (M2).

Desde la terminal, lo mismo con `riftway inspect <archivo>...`.

## Puente de URLs (M0)

Lleva a una botella de Wine los URLs que macOS recibe (por ejemplo, un login web en
Safari que redirige a `dsropen:…`), y se los entrega al programa de Windows que
registró ese esquema, igual que lo haría `ShellExecute` dentro de Windows.

```
Safari ──dsropen:…──▶ macOS (LaunchServices)
                        │  CFBundleURLTypes
                        ▼
              ~/Applications/Riftway/DSR.app   (puente, firmado ad hoc)
                        │  lee HKCR\dsropen\shell\open\command de la botella
                        ▼
   wine --bottle DSR --workdir … --cx-app "SuperRumble Launcher.exe" "dsropen:…"
                        │  (dentro de Wine; Riftway no interviene)
                        ▼
        Launcher actualiza ──▶ Client-Win64-Shipping.exe TOKEN:EMAIL
```

Riftway nunca interpreta el contenido del URL. Lo valida (esquema permitido, sin
caracteres de control ni comillas, longitud máxima) y lo pasa como un solo
argumento, sin pasar por un shell. Los logs (`~/Library/Logs/Riftway/riftway.log`)
solo muestran el esquema, la longitud y un hash.

## Uso

```sh
swift build -c release
.build/release/riftway bottles                       # botellas y protocolos registrados
.build/release/riftway resolve 'dsropen:x' --bottle DSR   # qué comando se ejecutaría
.build/release/riftway make-shim --bottle DSR --name "Digimon Super Rumble" --default
.build/release/riftway remove-shim ~/Applications/Riftway/"Digimon Super Rumble.app"
```

- `make-shim` reclama todos los protocolos propios de la botella. Nunca reclama
  `http`, `https`, `mailto` ni otros esquemas del sistema, que Wine reenvía a
  `winebrowser.exe` y de vuelta a macOS. Toma el `.ico` que esté junto al launcher.
- `--register` lo añade a LaunchServices; `--default` además lo vuelve el
  manejador predeterminado de cada esquema.
- `--dry-run` genera un puente que solo escribe en el log el comando que ejecutaría.
- `--prefix DIR --wine PATH` usa un Wine propio (con `WINEPREFIX`) en vez de CrossOver.
- Abierto sin URL (doble clic, Launchpad), el puente abre el launcher.

El `.app` debe vivir fuera de carpetas temporales: LaunchServices marca como
`launch-disabled` los manejadores que están en `/tmp` o `/private/var/folders`.

## Pruebas

```sh
swift test
```
