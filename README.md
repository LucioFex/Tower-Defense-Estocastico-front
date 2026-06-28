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
| `H` | mostrar / ocultar todo el HUD |
| `L` | leyenda de colores y símbolos |
| `T` | panel de validación **Teoría (M/M/c/K) vs Simulación** |
| `C` | tabla de dimensionado (barrido de `c`, marca el óptimo `c*`) |
| `G` | gráfico de la longitud de cola en el tiempo |

### HUD didáctico (para la presentación)

El HUD está pensado para **explicar los conceptos de teoría de colas** en vivo:

- **Estado/parámetros** (arriba-izq): notación Kendall-Lee, `λ` (llegadas), `μ` (servicio/torre),
  `c`, `K`, y estado en vivo (cola, servidores ocupados, en sistema, vida de la base).
- **Teoría vs Simulación** (abajo-izq, tecla `T`): compara `ρ, Lq, Wq, L, W` y `P` de
  fuga/bloqueo entre el modelo analítico y la corrida estocástica — **el corazón de la validación**.
- **Óptimo `c*`** (abajo-der, tecla `C`): barrido de cantidad de torres, resalta el `c` elegido.
- **Cola en el tiempo** (abajo-centro, tecla `G`): muestra la evolución estocástica de la cola.

### Selector de escenarios (interactivo, arriba-centro)

Botones clickeables que **cargan corridas precomputadas en caliente** (sin recalcular nada en el
front: cada escenario es un `output.json` válido y reproducible generado por el backend). Permiten
comparar al instante cómo cambia la cola/fuga/`Wq`:

- **Carga** (`λ`): *Tranquilo* (0.20) · *Normal* (0.40) · *Saturado* (0.70).
- **Torres `c`**: 1…6 (dimensionado; *Normal* y `3` son la corrida canónica `output.json`).
- **Cola**: *FIFO* vs *Prioridad* (con mezcla de enemigos goblin/orco de distinto `μ`).

> ⚠️ Las llegadas siguen siendo **Poisson(λ)** en todos los escenarios (no se inyectan a mano): eso
> preserva el supuesto del modelo y la validación teoría-vs-simulación. En los escenarios *FIFO/Prioridad*
> el servicio es heterogéneo, así que la columna "Teoría" (que asume `μ` homogéneo) es solo de referencia.

Los archivos viven en `scenarios/*.json` y se generan con:

```bash
# en el repo backend, con el venv activo:
python make_scenarios.py     # escribe ../<front>/scenarios/*.json (9 escenarios validados)
```

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
assets/               sprites medievales CC0 (terreno, goblins, torres, castillo, flechas)
export_presets.cfg    preset de exportación Web (PWA con cross-origin isolation)
icon.svg              ícono
```

El render es **modo inmediato** (`_draw`): cada cuadro es una función pura de `now`, dibujando
sprites con `draw_texture_rect*`. Las caminatas se animan eligiendo el frame del spritesheet en
función del reloj. Los sprites son pixel-art liviano (KB), así que el peso sigue siendo mínimo y
apto para web. Si falta algún asset, cada elemento cae a un dibujo procedural de respaldo.

## Look & feel (qué representa cada cosa, ahora temático)

- **Torres = servidores** (torres de piedra). Un **halo de calor** crece y se enrojece con la
  temperatura (azul frío → rojo caliente); en `cooldown` se ven grises y apagadas (con una `z`).
- **Goblins/orcos = clientes**, caminando desde la **cueva** (izquierda) hacia la línea de combate
  a ritmo constante (la caminata visual está **desacoplada** del evento de servicio, así no
  "aparecen/desaparecen" en el centro). Mueren con un desvanecimiento; se tiñen de rojo si se **fugan**.
- **Flechas** con estela de viento vuelan de la torre al enemigo que está atacando (servicio en curso).
- **Castillo = base** al final del camino, con barra de vida que baja con cada fuga.
- **Alcance de torre**: anillo punteado estilo radar (barrido giratorio), coloreado por temperatura.
- **Ambientación**: tinte cálido "hora dorada" + viñeta, y escenografía de fondo barata (lago con
  patitos, árboles, ovejas, ciervo, aves). Todo en modo inmediato, sin impacto de performance.

La ventana abre a **1600×900** (base 1280×720 escalada, `canvas_items`/`keep`), pensada para 1920×1080.

## Créditos de assets (todos libres)

- **Kenney.nl** — packs *Tower Defense (Top-Down)* y *Medieval RTS* — **CC0 1.0** (sin atribución
  requerida). https://kenney.nl
- **0x72 — DungeonTileset II** (goblin/orco animados) — **CC0**. https://0x72.itch.io/dungeontileset-ii

## Cómo lee el contrato (resumen)

- `events[]` → línea de tiempo de `spawn / enqueue / start_service / kill / leak / overheat /
  cooldown_done`. Se precomputa una tabla por enemigo (cuándo aparece, quién lo atiende, cuándo
  muere o se fuga).
- `samples[]` y `series` → temperatura y longitud de cola interpoladas en la grilla `dt_sample`.
- `layout` → posiciones de spawn, base, camino y torres.
- `stats` / `analytical` → valores del HUD.
