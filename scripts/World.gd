class_name TowerDefenseReplay
extends Node2D
## Tower Defense Estocástico — Reproductor 2D (sprites medievales + HUD didáctico).
##
## REGLA DE ORO: este script NO calcula nada del modelo. Solo lee output.json
## (contrato v1.0 del RAG) y reproduce/interpola la línea de tiempo de eventos y
## las muestras de estado (temperatura, cola). Toda la matemática vive en el backend.
##
## El render usa assets CC0 (Kenney + 0x72 DungeonTileset II) dibujados en modo
## inmediato: cada cuadro es función pura de `now`. Las caminatas se animan
## eligiendo el frame del spritesheet en función de un reloj de pared.

# ----------------------------------------------------------------------------- #
#  Parámetros ajustables (editables en el Inspector — @export)                    #
# ----------------------------------------------------------------------------- #
@export_file("*.json") var data_path := "res://output.json"
@export_range(0.25, 64.0, 0.25) var speed := 4.0   # velocidad de reproducción
@export var autoplay := true                        # arrancar reproduciendo
@export var loop := true                            # reiniciar al terminar
@export var leak_travel := 4.0                      # seg. visuales de un fugado hasta la base
@export var walk_speed := 320.0                     # px/seg (sim) de caminata visual del enemigo

# ----------------------------------------------------------------------------- #
#  Paleta de colores                                                              #
# ----------------------------------------------------------------------------- #
const COL_COLD := Color(0.31, 0.62, 1.0)     # torre fría (azul)
const COL_HOT := Color(1.0, 0.32, 0.16)      # torre caliente (rojo)
const COL_COOLDOWN := Color(0.60, 0.63, 0.68)# torre apagada (gris)
const COL_ENEMY_LEAK := Color(1.0, 0.42, 0.36)
const COL_FIRE := Color(1.0, 0.85, 0.35, 0.85)
const COL_TEXT := Color(0.93, 0.94, 0.98)
const COL_SHADOW := Color(0, 0, 0, 0.30)
const COL_STONE := Color(0.46, 0.47, 0.52)
const COL_STONE_DK := Color(0.30, 0.31, 0.35)
# acentos del HUD (coinciden con el deck): cada panel se colorea por propósito
const COL_GOLD := Color(0.91, 0.74, 0.34)
const COL_GREEN := Color(0.37, 0.83, 0.42)
const COL_PURPLE := Color(0.66, 0.55, 0.98)

# colores en hex para el HUD (BBCode)
const HX_COLD := "4f9eff"
const HX_HOT := "ff5230"
const HX_COOL := "9aa0a8"
const HX_ENEMY := "6cc06c"
const HX_LEAK := "f25a4d"
const HX_GOLD := "e7be57"
const HX_DIM := "9fb0c0"
const HX_GOOD := "5fd46a"
const HX_WARN := "ffb454"

# ----------------------------------------------------------------------------- #
#  Assets (CC0). Spritesheets de caminata: 4 frames horizontales.                 #
# ----------------------------------------------------------------------------- #
const GOBLIN_FRAMES := 4
const GOBLIN_FRAME := Vector2(16, 16)
const ORC_FRAMES := 4
const ORC_FRAME := Vector2(16, 20)
const ANIM_FPS := 8.0
const ENEMY_SCALE := 3.0
const DEATH_FADE := 0.45          # seg. de desvanecimiento al morir

# fracción de píxeles transparentes en el borde inferior de cada PNG (medido):
# se usa para anclar el sprite por su CONTENIDO real al piso (sin "flotar").
const PAD_CASTLE := 0.406         # castle.png: 26/64 px vacíos abajo
const PAD_KEEP := 0.344           # keep.png: 22/64
const PAD_TOWER := 0.219          # tower_stone.png: 14/64
const RANGE_SQUASH := 0.85        # achatado del anillo de rango (y del chequeo de disparo: coinciden)

var tex_grass: Texture2D
var tex_dirt: Texture2D
var tex_castle: Texture2D
var tex_keep: Texture2D
var tex_tower: Texture2D
var tex_goblin: Texture2D
var tex_orc: Texture2D
var tex_arrow: Texture2D
var tex_bush: Texture2D
var tex_rock: Texture2D

# ----------------------------------------------------------------------------- #
#  Estado                                                                         #
# ----------------------------------------------------------------------------- #
var data: Dictionary = {}
var enemies: Array[Dictionary] = []
var leak_arrivals: Array[Dictionary] = []
var now := 0.0
var sim_time := 1.0
var dt_sample := 0.5
var playing := true
var loaded := false
var _dirty := true
var _wall := 0.0

# geometría
var spawn_pos := Vector2.ZERO
var base_pos := Vector2.ZERO
var queue_anchor := Vector2.ZERO
var path_pts: PackedVector2Array = PackedVector2Array()
var towers: Array[Dictionary] = []
var decos: Array = []
var scenery: Array = []          # elementos de fondo (estanques, árboles, animalitos, aves)

var T_amb := 20.0
var T_max := 100.0

var font: Font

# HUD
var hud: CanvasLayer
var p_state: Panel
var p_legend: Panel
var p_compare: Panel
var p_sweep: Panel
var r_state: RichTextLabel
var r_legend: RichTextLabel
var r_compare: RichTextLabel
var r_sweep: RichTextLabel
var lbl_help: Label

# Selector de escenarios (carga corridas precomputadas en caliente)
var p_scen: Panel
var scen_buttons: Array = []          # [{btn, path}]
var current_scen_path := "res://output.json"

# toggles del HUD (configurable por teclado)
var hud_visible := true
var show_legend := true
var show_compare := true
var show_sweep := false
var show_chart := true

# Captura automática (correr con: --shot)
const SHOT_PATH := "C:/Users/lucia/AppData/Local/Temp/claude/C--Users-lucia-Documents-UCEMA-anio-5-simul-sis-tp/596cfff0-d50a-42a1-ac65-0097be5b39ea/scratchpad/shot.png"
var _shot := false
var _shot_t := 0.0


func _ready() -> void:
	font = ThemeDB.fallback_font
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	texture_repeat = CanvasItem.TEXTURE_REPEAT_ENABLED
	# ambientación cálida tipo "hora dorada" (multiplica solo el mundo, no el HUD)
	var cm := CanvasModulate.new()
	cm.color = Color(1.0, 0.965, 0.90)
	add_child(cm)
	_load_textures()
	playing = autoplay
	_shot = OS.get_cmdline_args().has("--shot") or OS.get_cmdline_user_args().has("--shot")
	if _shot:
		show_sweep = true            # la captura de verificación muestra todos los paneles
	for a in OS.get_cmdline_args():  # --scen=res://... para verificar la carga de un escenario
		if a.begins_with("--scen="):
			data_path = a.substr(7)
			current_scen_path = data_path
	_load_data()
	_build_hud()
	if not loaded:
		return
	_build_geometry()
	_build_enemies()
	_build_decorations()
	_build_scenery()
	_apply_hud_visibility()


func _load_textures() -> void:
	tex_grass = _try_load("res://assets/terrain/grass.png")
	tex_dirt = _try_load("res://assets/terrain/dirt.png")
	tex_castle = _try_load("res://assets/structures/castle.png")
	tex_keep = _try_load("res://assets/structures/keep.png")
	tex_tower = _try_load("res://assets/towers/tower_stone.png")
	tex_goblin = _try_load("res://assets/enemies/goblin_walk.png")
	tex_orc = _try_load("res://assets/enemies/orc_warrior_walk.png")
	tex_arrow = _try_load("res://assets/projectiles/arrow.png")
	tex_bush = _try_load("res://assets/structures/bush.png")
	tex_rock = _try_load("res://assets/structures/rock1.png")


func _try_load(path: String) -> Texture2D:
	if ResourceLoader.exists(path):
		return load(path)
	push_warning("Asset faltante (se usa fallback): " + path)
	return null


# ----------------------------------------------------------------------------- #
#  Carga del contrato                                                            #
# ----------------------------------------------------------------------------- #
func _load_data() -> void:
	var path := data_path
	if not FileAccess.file_exists(path):
		push_error("No se encontró output.json en res://. Copialo desde el backend.")
		return
	var f := FileAccess.open(path, FileAccess.READ)
	var txt := f.get_as_text()
	f.close()
	var parsed = JSON.parse_string(txt)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("output.json inválido.")
		return
	data = parsed
	var meta: Dictionary = data["meta"]
	sim_time = float(meta["sim_time"])
	dt_sample = float(meta["dt_sample"])
	var p: Dictionary = data["params"]
	T_amb = float(p["T_amb"])
	T_max = float(p["T_max"])
	loaded = true


func _build_geometry() -> void:
	var lay: Dictionary = data["layout"]
	spawn_pos = _v(lay["spawn"])
	base_pos = _v(lay["base"])
	queue_anchor = _v(lay["queue_anchor"])
	path_pts.clear()
	for pt in lay["path"]:
		path_pts.append(_v(pt))
	towers.clear()
	for tw in lay["towers"]:
		towers.append({"id": int(tw["id"]), "pos": Vector2(float(tw["x"]), float(tw["y"])),
			"range": float(tw["range"])})


func _v(d: Dictionary) -> Vector2:
	return Vector2(float(d["x"]), float(d["y"]))


func _build_decorations() -> void:
	decos.clear()
	if tex_bush == null and tex_rock == null:
		return
	var rng := RandomNumberGenerator.new()
	rng.seed = 9090
	var choices: Array = []
	if tex_bush: choices.append(tex_bush)
	if tex_rock: choices.append(tex_rock)
	var count := 0
	var attempts := 0
	while count < 22 and attempts < 600:
		attempts += 1
		var x := rng.randf_range(60, 1170)
		var y := rng.randf_range(60, 690)
		if absf(y - 360.0) < 90.0:
			continue
		if x > 470 and x < 800 and y > 130 and y < 590:
			continue
		if x < 150 and y > 280 and y < 460:        # despejar la cueva
			continue
		if x > 1090:                                # despejar el castillo
			continue
		var t: Texture2D = choices[rng.randi() % choices.size()]
		var s := rng.randf_range(26, 46)
		decos.append({"tex": t, "pos": Vector2(x, y), "size": Vector2(s, s)})
		count += 1


# Elementos de fondo "de lejos" (curados para no tapar el juego ni los paneles).
func _build_scenery() -> void:
	scenery = [
		{"kind": "pond", "pos": Vector2(690, 96), "rx": 98.0, "ry": 40.0},
		{"kind": "tree", "pos": Vector2(150, 252), "s": 1.0},
		{"kind": "tree", "pos": Vector2(255, 258), "s": 0.78},
		{"kind": "tree", "pos": Vector2(1086, 250), "s": 1.12},
		{"kind": "tree", "pos": Vector2(992, 268), "s": 0.7},
		{"kind": "sheep", "pos": Vector2(360, 292)},
		{"kind": "sheep", "pos": Vector2(408, 300)},
		{"kind": "sheep", "pos": Vector2(905, 286)},
		{"kind": "deer", "pos": Vector2(1052, 300)},
		{"kind": "birds", "pos": Vector2(470, 64), "n": 5},
		{"kind": "birds", "pos": Vector2(840, 120), "n": 3},
	]


# ----------------------------------------------------------------------------- #
#  Precómputo de la tabla de enemigos a partir de events[]                        #
# ----------------------------------------------------------------------------- #
func _build_enemies() -> void:
	leak_arrivals.clear()             # importante al recargar otro escenario
	var by_id := {}
	for ev in data["events"]:
		var t := float(ev["t"])
		var typ := String(ev["type"])
		if typ == "spawn":
			by_id[int(ev["enemy_id"])] = {
				"spawn_t": t, "start_t": -1.0, "end_t": -1.0,
				"end_type": "", "tower": -1}
		elif typ == "start_service":
			var e = by_id.get(int(ev["enemy_id"]))
			if e:
				e["start_t"] = t
				e["tower"] = int(ev["tower_id"])
		elif typ == "kill":
			var e = by_id.get(int(ev["enemy_id"]))
			if e:
				e["end_t"] = t
				e["end_type"] = "kill"
				e["tower"] = int(ev["tower_id"])
		elif typ == "leak":
			var e = by_id.get(int(ev["enemy_id"]))
			if e:
				e["end_t"] = t
				e["end_type"] = "leak"
			leak_arrivals.append({"t": t + leak_travel, "base_hp": int(ev["base_hp"])})

	enemies.clear()
	for eid in by_id:
		var e = by_id[eid]
		# jitter determinístico por id (para que no se superpongan)
		var jx := float((eid * 53) % 70) - 35.0
		var jy := float((eid * 31) % 80) - 40.0
		# El goblin camina hasta un punto del CAMINO debajo/encima de SU torre asignada,
		# que siempre cae DENTRO del rango de esa torre (así no se dispara fuera de rango).
		# Sin torre (fuga/balk o aún sin servicio al cortar): cae en el ancla de la cola.
		var tw_id := int(e["tower"])
		var combat: Vector2
		if tw_id >= 0 and tw_id < towers.size():
			var tx: float = towers[tw_id]["pos"].x
			combat = Vector2(tx + jx * 0.42, queue_anchor.y + jy * 0.26)
		else:
			combat = queue_anchor + Vector2(jx, jy)
		e["combat"] = combat
		# La caminata visual dura TODA la vida del goblin: avanza CONTINUO desde la cueva
		# hasta su torre y muere justo al llegar. Así no se "congela" esperando ni se
		# amontona; los que esperan más (cola larga) simplemente avanzan más lento.
		if e["end_type"] == "kill" and float(e["end_t"]) >= 0.0:
			e["walk_dur"] = maxf(0.3, float(e["end_t"]) - float(e["spawn_t"]))
		else:
			e["walk_dur"] = maxf(0.3, spawn_pos.distance_to(combat) / walk_speed)
		e["id"] = eid
		enemies.append(e)
	leak_arrivals.sort_custom(func(a, b): return a["t"] < b["t"])


# ----------------------------------------------------------------------------- #
#  Loop                                                                           #
# ----------------------------------------------------------------------------- #
func _process(delta: float) -> void:
	if not loaded:
		return
	_wall += delta
	if _shot:
		_shot_t += delta
		if now >= 50.0 or _shot_t > 30.0:
			_save_shot()
			return
	if playing:
		now += delta * speed
		if now >= sim_time:
			if loop:
				now = 0.0
			else:
				now = sim_time
				playing = false
		_update_hud()
		queue_redraw()
	elif _dirty:
		_update_hud()
		queue_redraw()
		_dirty = false


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		_dirty = true
		match event.keycode:
			KEY_SPACE:
				playing = not playing
				if now >= sim_time:
					now = 0.0
					playing = true
			KEY_R:
				now = 0.0
				playing = true
			KEY_RIGHT:
				speed = min(speed * 1.5, 64.0)
			KEY_LEFT:
				speed = max(speed / 1.5, 0.25)
			KEY_H:
				hud_visible = not hud_visible
				_apply_hud_visibility()
			KEY_L:
				show_legend = not show_legend
				_apply_hud_visibility()
			KEY_T:
				show_compare = not show_compare
				_apply_hud_visibility()
			KEY_C:
				show_sweep = not show_sweep
				_apply_hud_visibility()
			KEY_G:
				show_chart = not show_chart


# ----------------------------------------------------------------------------- #
#  Interpolación de muestras (temperatura / cola / estado)                        #
# ----------------------------------------------------------------------------- #
func _sample_idx() -> int:
	var samples: Array = data["samples"]
	return clampi(int(round(now / dt_sample)), 0, samples.size() - 1)


func _tower_temp(i: int) -> float:
	var series: Dictionary = data["series"]
	var temps: Array = series["tower_temp"][i]
	var n := temps.size()
	if n == 0: return T_amb
	var fidx := now / dt_sample
	var idx := int(floor(fidx))
	if idx >= n - 1: return float(temps[n - 1])
	if idx < 0: return float(temps[0])
	var frac := fidx - idx
	return lerp(float(temps[idx]), float(temps[idx + 1]), frac)


func _tower_state(i: int) -> String:
	return str(data["samples"][_sample_idx()]["towers"][i]["state"])


func _queue_len() -> int:
	return int(data["samples"][_sample_idx()]["queue_len"])


func _in_system() -> int:
	return int(data["samples"][_sample_idx()]["in_system"])


func _busy_count() -> int:
	var tws: Array = data["samples"][_sample_idx()]["towers"]
	var n := 0
	for tw in tws:
		if str(tw["state"]) == "busy":
			n += 1
	return n


func _temp_color(temp: float) -> Color:
	return COL_COLD.lerp(COL_HOT, _temp_frac(temp))


func _temp_frac(temp: float) -> float:
	return clampf((temp - T_amb) / max(1.0, T_max - T_amb), 0.0, 1.0)


func _base_hp() -> int:
	var hp := int(data["stats"]["base_hp_init"])
	for la in leak_arrivals:
		if la["t"] <= now:
			hp = int(la["base_hp"])
		else:
			break
	return hp


# Devuelve null si el enemigo no es visible, o {pos, alpha, scale, serving}.
func _enemy_state(e: Dictionary):
	var st := float(e["spawn_t"])
	if now < st:
		return null
	var combat: Vector2 = e["combat"]
	var wd := float(e["walk_dur"])
	if e["end_type"] == "leak":
		var lt := float(e["end_t"])
		if now < lt:
			var fw := clampf((now - st) / wd, 0.0, 1.0)
			return {"pos": spawn_pos.lerp(combat, fw), "alpha": 1.0, "scale": 1.0, "serving": false}
		var f := (now - lt) / leak_travel
		if f > 1.0:
			return null
		var p_leak := spawn_pos.lerp(combat, clampf((lt - st) / wd, 0.0, 1.0))
		return {"pos": p_leak.lerp(base_pos, f), "alpha": 1.0, "scale": 1.0, "serving": false}
	# matado o sobreviviente al corte de la simulación
	var et := float(e["end_t"])
	if et < 0.0:
		et = sim_time
	if now > et:
		return null
	var fwk := clampf((now - st) / wd, 0.0, 1.0)
	var pos := spawn_pos.lerp(combat, fwk)
	var alpha := 1.0
	var scl := 1.0
	if e["end_type"] == "kill":
		var rem := et - now
		if rem < DEATH_FADE:
			var a := clampf(rem / DEATH_FADE, 0.0, 1.0)
			alpha = a
			scl = lerp(0.55, 1.0, a)
	var stt := float(e["start_t"])
	var serving: bool = (e["end_type"] == "kill" and stt >= 0.0 and now >= stt)
	return {"pos": pos, "alpha": alpha, "scale": scl, "serving": serving, "arrived": fwk >= 0.99}


# ----------------------------------------------------------------------------- #
#  Helpers de dibujo                                                              #
# ----------------------------------------------------------------------------- #
func _blit_ground(tex: Texture2D, feet: Vector2, size: Vector2, mod := Color.WHITE, pad_frac := 0.0) -> void:
	# Ancla el CONTENIDO del sprite al piso: desplaza hacia abajo el relleno
	# transparente inferior (pad_frac) para que la base visible toque `feet`.
	if tex == null: return
	var top_left := feet - Vector2(size.x * 0.5, size.y) + Vector2(0, size.y * pad_frac)
	draw_texture_rect(tex, Rect2(top_left, size), false, mod)


func _blit_region_ground(tex: Texture2D, feet: Vector2, size: Vector2, src: Rect2, mod := Color.WHITE) -> void:
	if tex == null: return
	draw_texture_rect_region(tex, Rect2(feet - Vector2(size.x * 0.5, size.y), size), src, mod)


func _shadow(center: Vector2, w: float, squash := 0.42) -> void:
	draw_set_transform(center, 0.0, Vector2(1.0, squash))
	draw_circle(Vector2.ZERO, w, COL_SHADOW)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


func _ellipse(center: Vector2, rx: float, ry: float, col: Color) -> void:
	draw_set_transform(center, 0.0, Vector2(1.0, ry / rx))
	draw_circle(Vector2.ZERO, rx, col)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


func _dashed_ring(center: Vector2, r: float, col: Color, dashes := 40, width := 2.5) -> void:
	var step := TAU / dashes
	for i in range(0, dashes, 2):
		draw_arc(center, r, i * step, (i + 1) * step, 6, col, width)


# Anillo de alcance estilo radar: relleno tenue + sector de barrido giratorio +
# anillo punteado brillante. Bien visible, en perspectiva elíptica.
func _draw_range(tw: Dictionary, i: int) -> void:
	var center: Vector2 = tw["pos"]
	var state := _tower_state(i)
	var col := _temp_color(_tower_temp(i))
	if state == "cooldown":
		col = COL_COOLDOWN
	var r: float = tw["range"]
	draw_set_transform(center, 0.0, Vector2(1.0, RANGE_SQUASH))
	draw_circle(Vector2.ZERO, r, Color(col.r, col.g, col.b, 0.05))
	# sector de barrido (radar)
	var sweep := fposmod(_wall * 0.7 + float(i) * 2.1, TAU)
	var seg := 0.45
	var fan := PackedVector2Array([Vector2.ZERO])
	for k in 11:
		var ang := sweep - seg + seg * 2.0 * float(k) / 10.0
		fan.append(Vector2(cos(ang), sin(ang)) * r)
	draw_colored_polygon(fan, Color(col.r, col.g, col.b, 0.10))
	draw_line(Vector2.ZERO, Vector2(cos(sweep), sin(sweep)) * r, Color(col.r, col.g, col.b, 0.55), 2.5)
	# anillos
	var pulse := 0.5 + 0.5 * sin(_wall * 1.8 + float(i))
	_dashed_ring(Vector2.ZERO, r, Color(col.r, col.g, col.b, 0.55 + 0.20 * pulse), 50, 3.5)
	draw_arc(Vector2.ZERO, r, 0, TAU, 72, Color(col.r, col.g, col.b, 0.22), 1.5)
	draw_arc(Vector2.ZERO, r * 0.5, 0, TAU, 48, Color(col.r, col.g, col.b, 0.14), 1.0)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


# ----------------------------------------------------------------------------- #
#  Escenografía de fondo (barata, sin lag)                                        #
# ----------------------------------------------------------------------------- #
func _draw_scenery() -> void:
	for s in scenery:
		match s["kind"]:
			"pond": _draw_pond(s["pos"], s["rx"], s["ry"])
			"tree": _draw_tree(s["pos"], s["s"])
			"sheep": _draw_sheep(s["pos"])
			"deer": _draw_deer(s["pos"])
			"birds": _draw_birds(s["pos"], int(s["n"]))


func _draw_pond(c: Vector2, rx: float, ry: float) -> void:
	_ellipse(c, rx + 7, ry + 6, Color(0.30, 0.34, 0.20))      # orilla húmeda
	_ellipse(c, rx, ry, Color(0.19, 0.40, 0.53))              # agua
	_ellipse(c, rx * 0.92, ry * 0.88, Color(0.24, 0.50, 0.62))
	for j in 3:                                               # reflejos animados
		var yo := -ry * 0.45 + ry * 0.42 * j + sin(_wall * 1.5 + j) * 2.0
		var ww := rx * (0.55 - 0.13 * j)
		draw_line(c + Vector2(-ww, yo), c + Vector2(ww, yo), Color(1, 1, 1, 0.12), 2.0)
	for sx in [-rx * 0.82, rx * 0.72, -rx * 0.5]:             # juncos
		var b := c + Vector2(sx, ry * 0.25)
		draw_line(b, b + Vector2(2, -15), Color(0.24, 0.40, 0.20), 2.0)
	for dd in [Vector2(-rx * 0.25, -ry * 0.1), Vector2(rx * 0.22, ry * 0.05)]:  # patitos
		var p: Vector2 = c + dd
		_ellipse(p, 7, 5, Color(0.15, 0.13, 0.12))
		draw_circle(p + Vector2(5, -4), 2.5, Color(0.15, 0.13, 0.12))


func _draw_tree(c: Vector2, s: float) -> void:
	_shadow(c, 22 * s)
	draw_line(c, c + Vector2(0, -34 * s), Color(0.34, 0.24, 0.16), 7 * s)
	var top := c + Vector2(0, -48 * s)
	_ellipse(top, 30 * s, 26 * s, Color(0.14, 0.32, 0.17))
	_ellipse(top + Vector2(-11 * s, -6 * s), 20 * s, 18 * s, Color(0.19, 0.39, 0.21))
	_ellipse(top + Vector2(12 * s, 2 * s), 18 * s, 16 * s, Color(0.17, 0.36, 0.19))


func _draw_sheep(c: Vector2) -> void:
	_shadow(c + Vector2(0, 4), 14)
	draw_line(c + Vector2(-6, 0), c + Vector2(-6, 7), Color(0.2, 0.18, 0.18), 2.0)
	draw_line(c + Vector2(6, 0), c + Vector2(6, 7), Color(0.2, 0.18, 0.18), 2.0)
	for o in [Vector2(-7, -6), Vector2(0, -9), Vector2(7, -6), Vector2(0, -3)]:
		draw_circle(c + o, 8, Color(0.92, 0.92, 0.90))
	draw_circle(c + Vector2(11, -7), 5, Color(0.22, 0.20, 0.22))


func _draw_deer(c: Vector2) -> void:
	_shadow(c + Vector2(0, 3), 16)
	var br := Color(0.45, 0.30, 0.18)
	for lx in [-9, -3, 5, 10]:
		draw_line(c + Vector2(lx, 0), c + Vector2(lx, 12), br, 2.0)
	_ellipse(c + Vector2(0, -10), 16, 9, br)
	draw_line(c + Vector2(12, -12), c + Vector2(20, -26), br, 4.0)
	draw_circle(c + Vector2(21, -27), 4, br)
	draw_line(c + Vector2(21, -30), c + Vector2(17, -39), br, 1.5)
	draw_line(c + Vector2(21, -30), c + Vector2(26, -37), br, 1.5)


func _draw_birds(c: Vector2, n: int) -> void:
	var col := Color(0.14, 0.12, 0.15, 0.75)
	for k in n:
		var bx := c.x + k * 24.0 - n * 9.0
		var by := c.y + sin(_wall * 1.2 + k * 0.9) * 4.0 + float(k % 2) * 7.0
		var p := Vector2(bx, by)
		var flap := 2.0 + sin(_wall * 5.0 + k) * 1.5
		draw_line(p + Vector2(-6, flap), p, col, 1.6)
		draw_line(p, p + Vector2(6, flap), col, 1.6)


func _draw_vignette() -> void:
	var d := 165.0
	var ca := Color(0, 0, 0, 0.34)
	var cz := Color(0, 0, 0, 0.0)
	draw_polygon(PackedVector2Array([Vector2(0, 0), Vector2(1280, 0), Vector2(1280, d), Vector2(0, d)]),
		PackedColorArray([ca, ca, cz, cz]))
	draw_polygon(PackedVector2Array([Vector2(0, 720), Vector2(1280, 720), Vector2(1280, 720 - d), Vector2(0, 720 - d)]),
		PackedColorArray([ca, ca, cz, cz]))
	draw_polygon(PackedVector2Array([Vector2(0, 0), Vector2(0, 720), Vector2(d, 720), Vector2(d, 0)]),
		PackedColorArray([ca, ca, cz, cz]))
	draw_polygon(PackedVector2Array([Vector2(1280, 0), Vector2(1280, 720), Vector2(1280 - d, 720), Vector2(1280 - d, 0)]),
		PackedColorArray([ca, ca, cz, cz]))


# ----------------------------------------------------------------------------- #
#  Render                                                                         #
# ----------------------------------------------------------------------------- #
func _draw() -> void:
	if not loaded:
		draw_string(font, Vector2(40, 60),
			"Falta output.json en res://  (copiar desde el backend).", 0, -1, 22,
			Color(1, 0.5, 0.5))
		return

	var anim_frame := int(_wall * ANIM_FPS)

	# ---- fondo: pasto tileado ----
	if tex_grass:
		draw_texture_rect(tex_grass, Rect2(0, 0, 1280, 720), true)
	else:
		draw_rect(Rect2(0, 0, 1280, 720), Color(0.22, 0.45, 0.24))

	# ---- camino de tierra ----
	var py := 360.0
	var ph := 84.0
	if tex_dirt:
		draw_texture_rect(tex_dirt, Rect2(0, py - ph * 0.5, base_pos.x, ph), true)
	else:
		draw_rect(Rect2(0, py - ph * 0.5, base_pos.x, ph), Color(0.55, 0.40, 0.25))
	draw_line(Vector2(0, py - ph * 0.5), Vector2(base_pos.x, py - ph * 0.5), Color(0, 0, 0, 0.20), 3.0)
	draw_line(Vector2(0, py + ph * 0.5), Vector2(base_pos.x, py + ph * 0.5), Color(0, 0, 0, 0.20), 3.0)

	# ---- escenografía de fondo (estanque, árboles, animalitos, aves) ----
	_draw_scenery()

	# ---- anillos de alcance (radar, bien visibles) ----
	for tw in towers:
		var i: int = tw["id"]
		_draw_range(tw, i)

	# ---- decoración estática ----
	for d in decos:
		var feet: Vector2 = d["pos"] + Vector2(0, d["size"].y * 0.5)
		_shadow(feet, d["size"].x * 0.36)
		_blit_ground(d["tex"], feet, d["size"])

	# ---- cueva de goblins (spawn) ----
	_draw_cave(spawn_pos)

	# ---- castillo (base) ----
	var hp := _base_hp()
	var hp0 := int(data["stats"]["base_hp_init"])
	var hp_frac := float(hp) / maxi(1, hp0)
	_draw_castle(Vector2(minf(base_pos.x, 1168.0), base_pos.y), hp_frac, hp, hp0)

	# ---- torres ----
	for tw in towers:
		_draw_tower(tw)

	# ---- enemigos + flechas ----
	for e in enemies:
		var stt = _enemy_state(e)
		if stt == null:
			continue
		var p: Vector2 = stt["pos"]
		var a: float = stt["alpha"]
		# flecha en vuelo desde la torre que lo ataca — SOLO si está dentro del rango
		var twd: Dictionary = towers[int(e["tower"])] if stt["serving"] else {}
		var in_range := false
		if stt["serving"]:
			# misma elipse que el anillo dibujado: la torre dispara SOLO dentro de su rango visible
			var cc: Vector2 = twd["pos"]
			var de := Vector2(p.x - cc.x, (p.y - cc.y) / RANGE_SQUASH)
			in_range = de.length() <= float(twd["range"])
		if in_range:
			var tw_pos: Vector2 = twd["pos"] + Vector2(0, 4)
			var phase := fposmod(_wall * 2.4 + float(e["id"]) * 0.37, 1.0)
			var apos := tw_pos.lerp(p + Vector2(0, -12), phase)
			var ang := (p - tw_pos).angle()
			var dir := Vector2(cos(ang), sin(ang))
			# estela de viento (segmentos que se desvanecen detrás de la flecha)
			for k in range(1, 6):
				var t0 := apos - dir * (k * 6.0)
				var t1 := apos - dir * (k * 6.0 + 5.0)
				var al := a * (0.32 - k * 0.05)
				if al > 0.0:
					draw_line(t0, t1, Color(1.0, 0.96, 0.78, al), maxf(1.0, 5.5 - k * 0.8))
			draw_circle(apos, 5.0, Color(1.0, 0.9, 0.6, a * 0.22))   # resplandor
			if tex_arrow:
				draw_set_transform(apos, ang, Vector2.ONE)
				draw_texture_rect(tex_arrow, Rect2(-Vector2(21, 10), Vector2(42, 20)), false, Color(1, 1, 1, a))
				draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
			else:
				draw_line(tw_pos, p, COL_FIRE, 3.0)
		# sprite del enemigo (animado). orcos cada 3 ids, goblins el resto.
		var is_leak: bool = e["end_type"] == "leak"
		var tint := COL_ENEMY_LEAK if is_leak else Color.WHITE
		tint.a = a
		var sc: float = stt["scale"]
		# Ya en su lugar (en servicio o esperando): "saltito" con fase propia por id, para
		# verse vivo y distinguible de un goblin vecino (no parecer paralizado al dispararle).
		# saltito de marcha (siempre): mantiene vivos incluso a los goblins que avanzan
		# muy lento (cola saturada), con fase propia por id para distinguirlos del vecino.
		var idf := float(e["id"])
		var bob := Vector2(sin(_wall * 2.6 + idf) * 1.1, -absf(sin(_wall * 5.0 + idf * 1.9)) * 2.6)
		_shadow(p + Vector2(0, 2), 12.0 * sc)         # la sombra queda fija en el piso
		var feetp := p + bob
		var use_orc: bool = (int(e["id"]) % 3 == 0) and tex_orc != null
		if use_orc:
			var fr := anim_frame % ORC_FRAMES
			_blit_region_ground(tex_orc, feetp + Vector2(0, 6), ORC_FRAME * ENEMY_SCALE * sc,
				Rect2(fr * ORC_FRAME.x, 0, ORC_FRAME.x, ORC_FRAME.y), tint)
		elif tex_goblin:
			var fr := anim_frame % GOBLIN_FRAMES
			_blit_region_ground(tex_goblin, feetp + Vector2(0, 6), GOBLIN_FRAME * ENEMY_SCALE * sc,
				Rect2(fr * GOBLIN_FRAME.x, 0, GOBLIN_FRAME.x, GOBLIN_FRAME.y), tint)
		else:
			draw_circle(p, 9, tint)

	# ---- viñeta de ambientación (oscurece bordes, enfoca el centro) ----
	_draw_vignette()

	# ---- estandarte de la cola ----
	var qn := _queue_len()
	var qpos := queue_anchor + Vector2(0, 96)
	var qtxt := "Cola: %d / %d" % [qn, int(data["params"]["K"])]
	var qw := float(qtxt.length()) * 9.5 + 24.0
	draw_rect(Rect2(qpos.x - qw * 0.5, qpos.y - 14, qw, 28), Color(0.12, 0.10, 0.08, 0.80))
	draw_rect(Rect2(qpos.x - qw * 0.5, qpos.y - 14, qw, 28), Color(0.75, 0.62, 0.30, 0.9), false, 2.0)
	draw_string(font, qpos + Vector2(-qw * 0.5 + 12, 6), qtxt, 0, -1, 16, COL_TEXT)

	# ---- gráfico de la cola en el tiempo ----
	if hud_visible and show_chart:
		_draw_queue_chart()


func _draw_cave(feet: Vector2) -> void:
	var c := feet + Vector2(46, -10)
	# montículo rocoso (imponente)
	_shadow(c + Vector2(0, 40), 70, 0.32)
	_ellipse(c + Vector2(0, 12), 92, 70, Color(0.32, 0.28, 0.31))
	_ellipse(c + Vector2(0, 0), 82, 62, Color(0.25, 0.22, 0.25))
	_ellipse(c + Vector2(-26, -26), 32, 24, Color(0.39, 0.35, 0.38))
	_ellipse(c + Vector2(30, -20), 24, 19, Color(0.39, 0.35, 0.38))
	_ellipse(c + Vector2(4, -40), 22, 16, Color(0.34, 0.30, 0.33))
	# boca de la cueva (oscura, con degradé)
	_ellipse(c + Vector2(0, 20), 44, 50, Color(0.06, 0.05, 0.07))
	_ellipse(c + Vector2(0, 26), 38, 40, Color(0.0, 0.0, 0.0))
	# ojos acechando en la oscuridad
	var blink := 0.6 + 0.4 * sin(_wall * 1.3)
	draw_circle(c + Vector2(-12, 18), 3.0, Color(1.0, 0.85, 0.2, blink))
	draw_circle(c + Vector2(10, 22), 3.0, Color(1.0, 0.85, 0.2, blink * 0.8))
	# estacas con calaveras + antorchas que titilan
	for sx in [-66.0, 66.0]:
		var base := c + Vector2(sx, 24)
		draw_line(base, base + Vector2(0, -34), Color(0.30, 0.21, 0.12), 5.0)
		var flick := 0.7 + 0.3 * sin(_wall * 9.0 + sx)
		draw_circle(base + Vector2(0, -40), 9.0 * flick, Color(1.0, 0.50, 0.10, 0.85))
		draw_circle(base + Vector2(0, -41), 5.0 * flick, Color(1.0, 0.85, 0.35))
	# cartel
	draw_string(font, c + Vector2(-42, 58), "Cueva goblin", 0, -1, 14, Color(0.88, 0.82, 0.72))


func _draw_tower(tw: Dictionary) -> void:
	var i: int = tw["id"]
	var pos: Vector2 = tw["pos"]
	var feet := pos + Vector2(0, 20)
	var state := _tower_state(i)
	var temp := _tower_temp(i)
	var heat := _temp_frac(temp)
	var col := _temp_color(temp)
	var is_cool := state == "cooldown"
	if is_cool:
		col = COL_COOLDOWN
	# base de piedra (imponente, apoyada en el piso)
	_shadow(feet + Vector2(0, 6), 34)
	_ellipse(feet + Vector2(0, 4), 38, 18, COL_STONE_DK)
	_ellipse(feet, 34, 15, COL_STONE)
	# halo de calor
	var glow_a := 0.10 + 0.55 * heat
	if is_cool:
		glow_a = 0.20
	draw_circle(pos + Vector2(0, -6), 30 * (1.5 + 0.7 * heat), Color(col.r, col.g, col.b, glow_a))
	# sprite de la torre (más grande)
	var tint := Color.WHITE
	if is_cool:
		tint = Color(0.64, 0.68, 0.74)
	else:
		tint = Color.WHITE.lerp(Color(1.0, 0.72, 0.6), heat * 0.6)
	var tsize := Vector2(96, 96)
	_blit_ground(tex_tower, feet, tsize, tint, PAD_TOWER)
	var ctop := feet.y - tsize.y * (1.0 - PAD_TOWER)        # cima visible de la torre
	# bandera flameando en la cima
	var top := Vector2(feet.x, ctop + 4)
	var fl := sin(_wall * 3.0 + float(i)) * 5.0
	draw_line(top, top + Vector2(0, -22), Color(0.25, 0.20, 0.16), 2.5)
	var fcol := col.lightened(0.1)
	var pts := PackedVector2Array([top + Vector2(0, -22), top + Vector2(20 + fl, -17),
		top + Vector2(0, -12)])
	draw_colored_polygon(pts, fcol)
	# etiqueta de temperatura + cooldown
	draw_string(font, Vector2(feet.x - 18, ctop - 28), "%d°" % int(temp), 0, -1, 16,
		col.lightened(0.25))
	if is_cool:
		draw_string(font, Vector2(feet.x + 16, ctop - 28), "enfría", 0, -1, 12,
			Color(0.8, 0.85, 0.95))


func _draw_castle(feet: Vector2, hp_frac: float, hp: int, hp0: int) -> void:
	# sombra y plataforma ajustadas bajo la base visible (sin flotar)
	_shadow(feet + Vector2(0, 2), 60)
	_ellipse(feet + Vector2(0, 2), 64, 18, COL_STONE_DK)
	# dos torreones flanqueando (profundidad) + castillo principal
	if tex_keep:
		_blit_ground(tex_keep, feet + Vector2(-52, 2), Vector2(72, 72), Color.WHITE, PAD_KEEP)
		_blit_ground(tex_keep, feet + Vector2(52, 2), Vector2(72, 72), Color.WHITE, PAD_KEEP)
	var csize := Vector2(158, 158)
	if tex_castle:
		_blit_ground(tex_castle, feet, csize, Color.WHITE, PAD_CASTLE)
	else:
		draw_rect(Rect2(feet - Vector2(70, 130), Vector2(140, 130)), COL_STONE)
	# barra de vida grande justo encima de la cima visible del castillo
	var ctop := feet.y - csize.y * (1.0 - PAD_CASTLE)
	var bw := 142.0
	var bx := feet.x - bw * 0.5
	var by := ctop - 22.0
	draw_rect(Rect2(bx - 3, by - 3, bw + 6, 18), Color(0, 0, 0, 0.6))
	draw_rect(Rect2(bx, by, bw, 12), Color(0.22, 0.05, 0.05))
	var hp_col := Color(0.30, 0.85, 0.40).lerp(Color(0.95, 0.30, 0.25), 1.0 - hp_frac)
	draw_rect(Rect2(bx, by, bw * hp_frac, 12), hp_col)
	draw_string(font, Vector2(bx, by - 6), "Castillo  %d / %d" % [hp, hp0], 0, bw, 13, COL_TEXT)


func _draw_queue_chart() -> void:
	var ox := 470.0
	var oy := 612.0
	var w := 340.0
	var h := 84.0
	var K := float(data["params"]["K"])
	# panel
	draw_rect(Rect2(ox - 10, oy - 26, w + 20, h + 40), Color(0.06, 0.05, 0.08, 0.66))
	draw_string(font, Vector2(ox, oy - 10), "Cola en el tiempo  (capacidad K=%d)" % int(K),
		0, -1, 13, Color(0.85, 0.88, 0.95))
	# ejes
	draw_line(Vector2(ox, oy), Vector2(ox, oy + h), Color(1, 1, 1, 0.25), 1.0)
	draw_line(Vector2(ox, oy + h), Vector2(ox + w, oy + h), Color(1, 1, 1, 0.25), 1.0)
	# línea de capacidad K
	draw_line(Vector2(ox, oy), Vector2(ox + w, oy), Color(0.95, 0.35, 0.30, 0.35), 1.0)
	var q: Array = data["series"]["queue_len"]
	var n := q.size()
	if n < 2:
		return
	var upto := clampi(int(now / dt_sample) + 1, 2, n)
	var pts := PackedVector2Array()
	var step := maxi(1, int(ceil(float(upto) / w)))
	var idx := 0
	while idx < upto:
		var x := ox + w * float(idx) / float(maxi(1, upto - 1))
		var yv := oy + h - h * clampf(float(q[idx]) / maxf(1.0, K), 0.0, 1.0)
		pts.append(Vector2(x, yv))
		idx += step
	# último punto exacto
	var lx := ox + w
	var ly := oy + h - h * clampf(float(q[upto - 1]) / maxf(1.0, K), 0.0, 1.0)
	pts.append(Vector2(lx, ly))
	if pts.size() >= 2:
		draw_polyline(pts, Color(0.45, 0.80, 1.0, 0.95), 2.0)
	draw_circle(Vector2(lx, ly), 3.0, Color(1.0, 0.9, 0.4))
	draw_string(font, Vector2(ox + w - 30, oy + 12), str(int(q[upto - 1])), 0, -1, 13,
		Color(1.0, 0.9, 0.4))
	draw_string(font, Vector2(ox, oy + h + 12), "picos = ráfagas aleatorias de llegadas", 0, -1, 11,
		Color(0.72, 0.78, 0.88))


func _save_shot() -> void:
	var img := get_viewport().get_texture().get_image()
	var err := img.save_png(SHOT_PATH)
	if err != OK:
		push_error("No se pudo guardar el screenshot: %d" % err)
	get_tree().quit()


# ----------------------------------------------------------------------------- #
#  HUD                                                                            #
# ----------------------------------------------------------------------------- #
func _build_hud() -> void:
	hud = CanvasLayer.new()
	add_child(hud)

	p_state = _mk_panel(Vector2(8, 8), Vector2(470, 182), COL_COLD)
	r_state = _mk_rich(Vector2(18, 14), 452, 15)

	p_legend = _mk_panel(Vector2(956, 8), Vector2(316, 174), COL_PURPLE)
	r_legend = _mk_rich(Vector2(966, 14), 300, 14)

	p_compare = _mk_panel(Vector2(8, 438), Vector2(414, 252), COL_GREEN)
	r_compare = _mk_rich(Vector2(18, 444), 398, 14)

	p_sweep = _mk_panel(Vector2(896, 428), Vector2(376, 264), COL_GOLD)
	r_sweep = _mk_rich(Vector2(906, 434), 360, 13)

	lbl_help = Label.new()
	lbl_help.position = Vector2(8, 700)
	lbl_help.add_theme_font_size_override("font_size", 13)
	lbl_help.add_theme_color_override("font_color", COL_TEXT)
	lbl_help.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.85))
	lbl_help.add_theme_constant_override("shadow_offset_x", 1)
	lbl_help.add_theme_constant_override("shadow_offset_y", 1)
	lbl_help.text = "[Espacio] play/pausa     [←→] velocidad     [R] reiniciar"
	lbl_help.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud.add_child(lbl_help)

	_fill_legend()
	_build_selector()


func _mk_panel(pos: Vector2, size: Vector2, accent := Color(0.50, 0.55, 0.68)) -> Panel:
	# panel redondeado, semitransparente, con acento de color a la izquierda y sombra suave
	var p := Panel.new()
	p.position = pos
	p.size = size
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE   # decorativo: no robar clicks a los botones
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.05, 0.06, 0.10, 0.86)
	sb.set_corner_radius_all(11)
	sb.border_color = Color(accent.r, accent.g, accent.b, 0.85)
	sb.border_width_left = 5
	sb.border_width_top = 1
	sb.border_width_right = 1
	sb.border_width_bottom = 1
	sb.shadow_color = Color(0, 0, 0, 0.45)
	sb.shadow_size = 9
	p.add_theme_stylebox_override("panel", sb)
	hud.add_child(p)
	return p


func _mk_rich(pos: Vector2, width: int, font_size: int) -> RichTextLabel:
	var rt := RichTextLabel.new()
	rt.bbcode_enabled = true
	rt.scroll_active = false
	rt.fit_content = true
	rt.autowrap_mode = TextServer.AUTOWRAP_OFF
	rt.position = pos
	rt.custom_minimum_size = Vector2(width, 0)
	rt.size = Vector2(width, 0)
	rt.add_theme_font_size_override("normal_font_size", font_size)
	rt.add_theme_font_size_override("bold_font_size", font_size)
	rt.mouse_filter = Control.MOUSE_FILTER_IGNORE   # decorativo: no robar clicks a los botones
	hud.add_child(rt)
	return rt


func _apply_hud_visibility() -> void:
	hud.visible = hud_visible
	if not hud_visible:
		return
	p_legend.visible = show_legend
	r_legend.visible = show_legend
	p_compare.visible = show_compare
	r_compare.visible = show_compare
	p_sweep.visible = show_sweep
	r_sweep.visible = show_sweep


func _fill_legend() -> void:
	r_legend.text = ("[b]Leyenda[/b]\n"
		+ "[color=#%s]■[/color]→[color=#%s]■[/color]  Torre: fría → caliente\n" % [HX_COLD, HX_HOT]
		+ "[color=#%s]■[/color]  Torre en cooldown (no atiende)\n" % HX_COOL
		+ "[color=#%s]■[/color]  Goblin = cliente (servicio/cola)\n" % HX_ENEMY
		+ "[color=#%s]■[/color]  Goblin rojo = se fuga a la base\n" % HX_LEAK
		+ "[color=#%s]➤[/color]  Flecha = disparo (servicio)\n" % HX_GOLD
		+ "◌  Anillo punteado = alcance de torre")


# ----------------------------------------------------------------------------- #
#  Selector de escenarios (carga corridas precomputadas con un click)             #
# ----------------------------------------------------------------------------- #
func _build_selector() -> void:
	p_scen = _mk_panel(Vector2(482, 6), Vector2(470, 56), COL_COLD)
	var t := Label.new()
	t.position = Vector2(862, 8)
	t.add_theme_font_size_override("font_size", 11)
	t.add_theme_color_override("font_color", Color(0.62, 0.68, 0.78))
	t.text = "ESCENARIOS"
	t.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud.add_child(t)
	# fila 1: carga + disciplina de cola
	_scen_label("Carga:", Vector2(490, 11))
	_mk_scen_btn("Tranq", 544, 10, 52, "res://scenarios/carga_tranquilo.json")
	_mk_scen_btn("Normal", 598, 10, 52, "res://output.json")
	_mk_scen_btn("Satur", 652, 10, 50, "res://scenarios/carga_saturado.json")
	_scen_label("Cola:", Vector2(710, 11))
	_mk_scen_btn("FIFO", 752, 10, 46, "res://scenarios/cola_fifo.json")
	_mk_scen_btn("Prio", 800, 10, 46, "res://scenarios/cola_prioridad.json")
	# fila 2: dimensionado de torres
	_scen_label("Torres c:", Vector2(490, 36))
	var cpaths := ["res://scenarios/c1.json", "res://scenarios/c2.json", "res://output.json",
		"res://scenarios/c4.json", "res://scenarios/c5.json", "res://scenarios/c6.json"]
	for i in 6:
		_mk_scen_btn(str(i + 1), 560 + i * 32, 35, 30, cpaths[i])
	_highlight_scen(current_scen_path)


func _scen_label(text: String, pos: Vector2) -> void:
	var l := Label.new()
	l.position = pos
	l.add_theme_font_size_override("font_size", 12)
	l.add_theme_color_override("font_color", Color(0.80, 0.84, 0.92))
	l.text = text
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud.add_child(l)


func _mk_scen_btn(text: String, x: float, y: float, w: float, path: String) -> void:
	var b := Button.new()
	b.text = text
	b.position = Vector2(x, y)
	b.custom_minimum_size = Vector2(w, 21)
	b.size = Vector2(w, 21)
	b.focus_mode = Control.FOCUS_NONE          # no robar el foco (Espacio sigue siendo play/pausa)
	b.add_theme_font_size_override("font_size", 12)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.15, 0.16, 0.21, 0.96)
	sb.set_corner_radius_all(3)
	b.add_theme_stylebox_override("normal", sb)
	var sbh := StyleBoxFlat.new()
	sbh.bg_color = Color(0.26, 0.28, 0.36, 0.98)
	sbh.set_corner_radius_all(3)
	b.add_theme_stylebox_override("hover", sbh)
	b.add_theme_stylebox_override("pressed", sbh)
	b.add_theme_color_override("font_color", COL_TEXT)
	b.add_theme_color_override("font_hover_color", COL_TEXT)
	b.pressed.connect(_on_scen.bind(path))
	hud.add_child(b)
	scen_buttons.append({"btn": b, "path": path})


func _on_scen(path: String) -> void:
	_load_scenario(path)
	_highlight_scen(path)


func _highlight_scen(path: String) -> void:
	current_scen_path = path
	for e in scen_buttons:
		e["btn"].modulate = Color(1.0, 0.80, 0.32) if e["path"] == path else Color(1, 1, 1)


func _load_scenario(path: String) -> void:
	data_path = path
	leak_arrivals.clear()
	_load_data()
	if not loaded:
		return
	_build_geometry()
	_build_enemies()
	now = 0.0
	playing = true
	_dirty = true
	_update_hud()
	queue_redraw()


func _update_hud() -> void:
	if not loaded:
		return
	var meta: Dictionary = data["meta"]
	var p: Dictionary = data["params"]
	var ana: Dictionary = data["analytical"]
	var st: Dictionary = data["stats"]

	# ---- panel de estado (parámetros + vivo) ----
	var stable := bool(ana["stable"])
	var stable_txt := "[color=#%s]estable[/color]" % HX_GOOD if stable else "[color=#%s]inestable[/color]" % HX_WARN
	r_state.text = ("[b]Tower Defense Estocástico[/b]   [color=#%s]%s[/color]\n" % [HX_DIM, meta["model"]]
		+ "[color=#%s]Torres=servidores · Goblins=clientes · Castillo=base[/color]\n" % HX_DIM
		+ "[b]Entrada:[/b]  λ=%.2f (llegadas/s)   μ=%.2f (servicio/torre)   c=%d   K=%d\n" % [
			float(p["lambda"]), float(p["mu"]), int(p["c"]), int(p["K"])]
		+ "[b]t[/b] = %.0f / %.0f s   [color=#%s]x%.2f[/color]   %s\n" % [
			now, sim_time, HX_GOLD, speed, stable_txt]
		+ "[b]En vivo:[/b]  cola=[color=#%s]%d[/color]/%d   ocupadas=[color=#%s]%d[/color]/%d   en sistema=%d   base ♥ %d/%d\n" % [
			HX_WARN, _queue_len(), int(p["K"]), HX_COLD, _busy_count(), int(p["c"]),
			_in_system(), _base_hp(), int(st["base_hp_init"])]
		+ "[color=#%s]Paneles:  [H] HUD   [L] leyenda   [T] teoría/sim   [C] óptimo c*   [G] gráfico[/color]" % HX_DIM)

	# ---- panel teoría vs simulación (validación) ----
	if show_compare and hud_visible:
		var rho := float(ana["rho"])
		var util_sim := 0.0
		for u in st["tower_utilization"]:
			util_sim += float(u)
		util_sim /= max(1, st["tower_utilization"].size())
		r_compare.text = ("[b]Validación — Teoría (M/M/c/K) vs Simulación[/b]\n"
			+ "[color=#%s]Promedios temporales de la corrida (seed %d).[/color]\n" % [HX_DIM, int(meta["seed"])]
			+ "[table=3]"
			+ _row("[b]Métrica[/b]", "[b]Teoría[/b]", "[b]Sim[/b]")
			+ _row("ρ utilización", "%.3f" % rho, "%.3f" % util_sim)
			+ _row("Lq (en cola)", "%.2f" % float(ana["Lq"]), "%.2f" % float(st["avg_queue_len"]))
			+ _row("Wq espera (s)", "%.2f" % float(ana["Wq"]), "%.2f" % float(st["avg_wait_q"]))
			+ _row("L (en sistema)", "%.2f" % float(ana["L"]), "%.2f" % float(st["avg_in_system"]))
			+ _row("W total (s)", "%.2f" % float(ana["W"]), "%.2f" % float(st["avg_time_system"]))
			+ _row("P fuga / bloqueo", "%.2f%%" % (float(ana["Pb_finite"]) * 100.0),
				"%.2f%%" % (float(st["leak_rate"]) * 100.0))
			+ "[/table]\n"
			+ "[color=#%s][i]Sim ≳ Teoría: el sobrecalentamiento de las\ntorres baja la capacidad efectiva (más espera y fuga).[/i][/color]" % HX_DIM)

	# ---- panel sweep (óptimo c*) ----
	if show_sweep and hud_visible:
		var c_now := int(p["c"])
		var txt := ("[b]Dimensionado: ¿cuántas torres? (c*)[/b]\n"
			+ "[color=#%s]Barrido de c con λ,μ fijos. Se marca el c actual.[/color]\n" % HX_DIM
			+ "[table=5]"
			+ _row5("[b]c[/b]", "[b]ρ[/b]", "[b]Lq[/b]", "[b]Wq[/b]", "[b]fuga[/b]"))
		for row in data["sweep"]:
			var c_val := int(row["c"])
			var rho_s := "%.2f" % float(row["rho"]) if row["rho"] != null else "—"
			var lq_s := "%.2f" % float(row["Lq"]) if row["Lq"] != null else "[color=#%s]inest.[/color]" % HX_WARN
			var wq_s := "%.2f" % float(row["Wq"]) if row["Wq"] != null else "—"
			var leak_s := "%.1f%%" % (float(row["leak_rate_sim"]) * 100.0)
			var cc := "[b][color=#%s]%d ◄[/color][/b]" % [HX_GOOD, c_val] if c_val == c_now else str(c_val)
			txt += _row5(cc, rho_s, lq_s, wq_s, leak_s)
		txt += "[/table]\n"
		txt += ("[color=#%s][i]c* = menor c estable (ρ<1) con fuga ≈ 0.\nMás torres → menos espera, mayor costo.[/i][/color]" % HX_DIM)
		r_sweep.text = txt


func _row(a: String, b: String, c: String) -> String:
	return "[cell]%s  [/cell][cell]%s  [/cell][cell]%s[/cell]" % [a, b, c]


func _row5(a: String, b: String, c: String, d: String, e: String) -> String:
	return "[cell]%s  [/cell][cell]%s  [/cell][cell]%s  [/cell][cell]%s  [/cell][cell]%s[/cell]" % [a, b, c, d, e]
