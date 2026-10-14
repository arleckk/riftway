# PRD-03: Puente de URLs de macOS a Wine

| | |
|---|---|
| Estado | **M0 implementado** (CLI + `.app` puente); pendiente su integración en la app |
| Código | `Sources/RiftwayCore/URLBridge.swift`, `ShimBundle.swift`, `Sources/RiftwayShim/` |

## Problema

Muchos juegos se lanzan desde su sitio web: el login termina en un link
`dsropen:token;email;hash` que Windows entrega al launcher registrado. En macOS ese
esquema no existe, y el link no hace nada.

## Comportamiento (implementado)

1. Por juego existe `~/Applications/Riftway/<Juego>.app` con `CFBundleURLTypes`
   de los esquemas que la botella registró.
2. macOS le entrega el URL (Apple Event `kAEGetURL`, sin pasar por `URL` de Foundation).
3. El puente lee de nuevo el registro de la botella (`HKCR\<esquema>\shell\open\command`),
   sustituye `%1` como `ShellExecute` y lanza el programa en la botella, sin shell y
   con el URL como un solo argumento.
4. Con doble clic, sin URL, abre el programa del esquema.

**Reglas de seguridad (implementadas):** solo esquemas registrados por esa botella;
nunca los reservados de macOS (`http`, `https`, `mailto`, …); se rechazan comillas,
caracteres de control y URLs de más de 16 KB; los logs solo muestran esquema,
longitud y hash.

**Aprendizajes de M0**
- LaunchServices marca como `launch-disabled` los manejadores en carpetas temporales;
  los puentes deben vivir en `~/Applications/Riftway`.
- Al quitar un puente hay que moverlo a la Papelera primero y luego hacer
  `lsregister -u`; al revés, LaunchServices lo vuelve a indexar.

## Pendiente para la app (M3)

| ID | Requisito |
|---|---|
| R1 | La app genera y regenera los puentes a partir del descubrimiento ([PRD-01](PRD-01-instalar-con-doble-clic.md) §6). |
| R2 | El binario `riftway-shim` va dentro de `Riftway.app`; los puentes lo copian. Al actualizar Riftway, los puentes existentes se regeneran con el binario nuevo. |
| R3 | Si un esquema ya tiene otro manejador (el CrossOver del usuario, otra botella), Riftway pregunta antes de volverse predeterminado. |
| R4 | Un esquema registrado en dos botellas: el puente más reciente gana; Ajustes permite elegir. |
| R5 | El puente usa el perfil del juego (variables de entorno, Game Mode) al lanzar el launcher, para que el juego las herede. |
| R6 | Error visible y útil: "El launcher ya no está en la botella. ¿Reparar?" en vez de un fallo silencioso. |

## Métricas

- 100 % de los URLs del corpus llegan intactos al programa (verificable con el "wine"
  falso de las pruebas de M0).
- Tiempo desde el clic en Safari hasta el arranque del launcher: < 1.5 s (sin contar
  el arranque de Wine).
