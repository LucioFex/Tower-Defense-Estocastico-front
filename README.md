# Tower Defense Estocástico — Frontend (Godot 4, 2D)

Repo 3 de 3 del TP de **Simulación de Sistemas** (UCEMA). Reproductor visual **2D estricto** de la
simulación de colas. **Cero lógica de cálculo**: lee `output.json` (contrato v1.0 generado por el
backend SimPy) e interpola estados, posiciones y colores en una línea de tiempo.

> Modelo y contrato de datos: ver el repo `Tower-Defense-Estocastico-rag-karpathy`.
> Generación de `output.json`: ver el repo `Tower-Defense-Estocastico-back`.

## Qué se ve

- **Torres = servidores.** Su color interpola **azul (frío) → rojo (caliente)** según la
  temperatura (variable continua del modelo). En `cooldown` se ven **grises** (apagadas, no atienden).
- **Enemigos = clientes.** Amarillos cuando son atendidos/encolados; rojos si se **fugan** a la base.
- **Línea de fuego:** une la torre con el enemigo que está atacando (servicio en curso).
- **Cola:** contador de enemigos esperando; **base** con barra de vida (baja con cada fuga).
- **HUD:** modelo Kendall-Lee, λ, μ, ρ, estabilidad, fuga simulada, Wq y Lq.

## Controles

| Tecla | Acción |
|---|---|
| `Espacio` | play / pausa (reinicia si terminó) |
| `←` / `→` | velocidad de reproducción (÷ / ×) |
| `R` | reiniciar la reproducción |

## Ejecutar (editor / escritorio)

1. Abrir el proyecto con **Godot 4.3+** (botón *Import* → seleccionar `project.godot`).
2. Asegurarse de que `output.json` esté en la raíz del proyecto (`res://output.json`).
   Para regenerarlo: correr `python main.py` en el repo backend y copiar el archivo acá.
3. *Play* (F5).

## Exportar a Web (HTML5) — hosting gratuito

El proyecto incluye `export_presets.cfg` con un preset **Web** listo:

```bash
# desde la carpeta del proyecto, con Godot en el PATH:
godot --headless --export-release "Web" builds/web/index.html
```

### SharedArrayBuffer / aislamiento de origen
Godot 4 Web usa `SharedArrayBuffer`, que requiere los headers de **cross-origin isolation**:

```
Cross-Origin-Opener-Policy: same-origin
Cross-Origin-Embedder-Policy: require-corp
```

El preset tiene activado `progressive_web_app/enabled` con
`ensure_cross_origin_isolation_headers`, de modo que el **service worker** inyecta esos headers
automáticamente. Esto permite hostear **sin costo** en sitios estáticos que no dejan configurar
headers (p. ej. **itch.io** o **GitHub Pages**):

- **itch.io:** subir el ZIP de `builds/web/`, marcar *"This file will be played in the browser"* y
  activar *"SharedArrayBuffer support"*.
- **GitHub Pages:** publicar `builds/web/` (el service worker del PWA aplica el aislamiento).

Prueba local rápida (con los headers correctos):
```bash
python - <<'PY'
import http.server, functools
class H(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header("Cross-Origin-Opener-Policy","same-origin")
        self.send_header("Cross-Origin-Embedder-Policy","require-corp")
        super().end_headers()
http.server.test(HandlerClass=functools.partial(H, directory="builds/web"), port=8060)
PY
```

## Arquitectura

```
project.godot         configuración (2D, GL Compatibility, 1280x720)
main.tscn             escena raíz (Node2D + World.gd)
scripts/World.gd      carga output.json, línea de tiempo, interpolación y render 2D
output.json           datos de la simulación (copiado del backend; contrato v1.0)
export_presets.cfg    preset de exportación Web (PWA con cross-origin isolation)
icon.svg              ícono
```

Todo el dibujo es **procedural** (`_draw`): sin assets externos, mínimo peso, ideal para web y para
correr en máquinas de bajos recursos.

## Cómo lee el contrato (resumen)

- `events[]` → línea de tiempo de `spawn / enqueue / start_service / kill / leak / overheat /
  cooldown_done`. Se precomputa una tabla por enemigo (cuándo aparece, quién lo atiende, cuándo
  muere o se fuga).
- `samples[]` y `series` → temperatura y longitud de cola interpoladas en la grilla `dt_sample`.
- `layout` → posiciones de spawn, base, camino y torres.
- `stats` / `analytical` → valores del HUD.
