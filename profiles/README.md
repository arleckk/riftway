# Perfiles de juego

Un archivo `<id>.json` por juego, con el esquema de
[PRD-05](../docs/prd/PRD-05-perfiles-y-compatibilidad.md#perfil). Riftway los incluye en la
app (`Contents/Resources/Profiles`) y también lee `~/Library/Application Support/Riftway/Profiles`,
donde un perfil con la misma `id` y una `revision` igual o mayor gana.

Antes de enviar uno:

```bash
swift run riftway profiles --check profiles/mi-juego.json
```

Reglas:
- `verified` exige `tested` con fecha, versión de macOS, hardware y runtime, probado de
  punta a punta. Para juegos en línea, solo con cuentas desechables.
- Un perfil ajusta la botella (entorno, overrides de DLL, registro, `dxmt.conf`) y nunca los
  archivos del juego.
- Nada que oculte Wine o la Mac, que finja hardware o que desactive, intercepte o evada un
  anti-cheat ([PRD-07](../docs/prd/PRD-07-compatibilidad-online.md#la-línea-roja)). Por eso el
  registro solo admite `HKCU` y `HKLM/Software`, y nunca la clave `Software/Riftway`.
- Sube `revision` con cada cambio, para que las botellas lo vuelvan a aplicar.
- Notas sin tokens, correos ni identificadores de cuenta.
