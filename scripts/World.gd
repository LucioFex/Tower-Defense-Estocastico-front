extends Node2D
## Tower Defense Estocástico — Reproductor 2D.
##
## REGLA DE ORO: este script NO calcula nada del modelo. Solo lee output.json
## (contrato v1.0 del RAG) y reproduce/interpola la línea de tiempo de eventos y
## las muestras de estado (temperatura, cola). Toda la matemática vive en el backend.

# ----------------------------------------------------------------------------- #
#  Constantes de presentación                                                    #
# ----------------------------------------------------------------------------- #
const LEAK_TRAVEL := 3.0        # seg. visuales que tarda un enemigo fugado en llegar a la base
const ENEMY_R := 9.0
const TOWER_R := 22.0
const COL_BG := Color(0.08, 0.09, 0.12)
const COL_PATH := Color(0.22, 0.24, 0.30)
const COL_COLD := Color(0.25, 0.55, 1.0)     # torre fría (azul)
const COL_HOT := Color(1.0, 0.30, 0.18)      # torre caliente (rojo)
const COL_COOLDOWN := Color(0.45, 0.45, 0.50)# torre apagada (gris)
const COL_ENEMY := Color(0.85, 0.78, 0.30)
const COL_ENEMY_LEAK := Color(0.90, 0.30, 0.30)
const COL_FIRE := Color(1.0, 0.85, 0.35, 0.75)
const COL_BASE := Color(0.35, 0.80, 0.55)
const COL_TEXT := Color(0.90, 0.92, 0.96)

# ----------------------------------------------------------------------------- #
#  Estado                                                                         #
# ----------------------------------------------------------------------------- #
var data: Dictionary = {}
var enemies: Array = []          # tabla precomputada de enemigos
var leak_arrivals: Array = []    # [{t_arrive, base_hp}] ordenado, para la vida de la base
var now := 0.0                   # reloj de reproducción
var sim_time := 1.0
var dt_sample := 0.5
var speed := 4.0                 # multiplicador de velocidad de reproducción
var playing := true
var loaded := false

# geometría
var spawn_pos := Vector2.ZERO
var base_pos := Vector2.ZERO
var queue_anchor := Vector2.ZERO
var path_pts: Array = []
var towers: Array = []           # [{id,pos,range}]

# parámetros para el color de temperatura
var T_amb := 20.0
var T_max := 100.0

var font: Font

# HUD nodes
var hud: CanvasLayer
var lbl_title: Label
var lbl_stats: Label
var lbl_help: Label


func _ready() -> void:
	font = ThemeDB.fallback_font
	_load_data()
	_build_hud()
	if not loaded:
		return
	_build_geometry()
	_build_enemies()


# ----------------------------------------------------------------------------- #
#  Carga del contrato                                                            #
# ----------------------------------------------------------------------------- #
func _load_data() -> void:
	var path := "res://output.json"
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


# ----------------------------------------------------------------------------- #
#  Precómputo de la tabla de enemigos a partir de events[]                        #
# ----------------------------------------------------------------------------- #
func _build_enemies() -> void:
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
			leak_arrivals.append({"t": t + LEAK_TRAVEL, "base_hp": int(ev["base_hp"])})

	enemies.clear()
	for eid in by_id:
		var e = by_id[eid]
		# jitter determinístico por id para que no se superpongan en la línea de combate
		var jx := float((eid * 53) % 70) - 35.0
		var jy := float((eid * 31) % 80) - 40.0
		e["combat"] = queue_anchor + Vector2(jx, jy)
		e["id"] = eid
		enemies.append(e)
	leak_arrivals.sort_custom(func(a, b): return a["t"] < b["t"])


# ----------------------------------------------------------------------------- #
#  Loop                                                                           #
# ----------------------------------------------------------------------------- #
func _process(delta: float) -> void:
	if not loaded:
		return
	if playing:
		now += delta * speed
		if now >= sim_time:
			now = sim_time
			playing = false
	_update_hud()
	queue_redraw()


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
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


# ----------------------------------------------------------------------------- #
#  Interpolación de muestras (temperatura / cola)                                 #
# ----------------------------------------------------------------------------- #
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
	var samples: Array = data["samples"]
	var idx := clampi(int(round(now / dt_sample)), 0, samples.size() - 1)
	return str(samples[idx]["towers"][i]["state"])


func _queue_len() -> int:
	var samples: Array = data["samples"]
	var idx := clampi(int(round(now / dt_sample)), 0, samples.size() - 1)
	return int(samples[idx]["queue_len"])


func _temp_color(temp: float) -> Color:
	var t := clampf((temp - T_amb) / max(1.0, T_max - T_amb), 0.0, 1.0)
	return COL_COLD.lerp(COL_HOT, t)


func _base_hp() -> int:
	var hp := int(data["stats"]["base_hp_init"])
	for la in leak_arrivals:
		if la["t"] <= now:
			hp = int(la["base_hp"])
		else:
			break
	return hp


func _enemy_pos(e: Dictionary):
	# Devuelve Vector2 o null si no está visible en `now`.
	var st := float(e["spawn_t"])
	if now < st:
		return null
	if e["end_type"] == "leak":
		var arrive := st + LEAK_TRAVEL
		if now > arrive:
			return null
		var f := (now - st) / LEAK_TRAVEL
		return spawn_pos.lerp(base_pos, f)
	# killed (o aún en el sistema al cortar la simulación: end_t < 0 -> visible hasta el final)
	var et := float(e["end_t"])
	if et < 0.0:
		et = sim_time
	if now > et:
		return null
	var stt := float(e["start_t"])
	if stt < 0.0 or now >= stt:
		return e["combat"]              # en combate (siendo atacado) o esperando en la línea
	# caminando hacia la línea de combate
	var f2 := (now - st) / max(0.001, stt - st)
	return spawn_pos.lerp(e["combat"], clampf(f2, 0.0, 1.0))


# ----------------------------------------------------------------------------- #
#  Render                                                                         #
# ----------------------------------------------------------------------------- #
func _draw() -> void:
	if not loaded:
		draw_string(font, Vector2(40, 60),
			"Falta output.json en res://  (copiar desde el backend).", 0, -1, 22,
			Color(1, 0.5, 0.5))
		return

	# camino
	if path_pts.size() >= 2:
		draw_polyline(PackedVector2Array(path_pts), COL_PATH, 26.0)

	# spawn y base
	draw_circle(spawn_pos, 14, Color(0.5, 0.5, 0.6))
	var hp := _base_hp()
	var hp0 := int(data["stats"]["base_hp_init"])
	var hp_frac := float(hp) / max(1, hp0)
	# base como rectángulo con barra de vida
	var bsize := Vector2(46, 90)
	draw_rect(Rect2(base_pos - bsize / 2, bsize), COL_BASE.darkened(0.3))
	draw_rect(Rect2(base_pos - bsize / 2 + Vector2(0, bsize.y * (1.0 - hp_frac)),
		Vector2(bsize.x, bsize.y * hp_frac)), COL_BASE)
	draw_rect(Rect2(base_pos - bsize / 2, bsize), COL_TEXT, false, 2.0)

	# torres + rango + fuego
	for tw in towers:
		var i: int = tw["id"]
		var pos: Vector2 = tw["pos"]
		var state := _tower_state(i)
		var temp := _tower_temp(i)
		var col := _temp_color(temp)
		if state == "cooldown":
			col = COL_COOLDOWN
		draw_circle(pos, tw["range"], Color(col.r, col.g, col.b, 0.05))
		draw_arc(pos, tw["range"], 0, TAU, 48, Color(col.r, col.g, col.b, 0.18), 1.0)
		draw_circle(pos, TOWER_R, col)
		draw_arc(pos, TOWER_R, 0, TAU, 24, COL_TEXT, 2.0)
		draw_string(font, pos + Vector2(-5, 5), str(i), 0, -1, 16, COL_BG)
		draw_string(font, pos + Vector2(-22, -TOWER_R - 8),
			"%d°" % int(temp), 0, -1, 14, col.lightened(0.3))

	# enemigos + líneas de fuego
	var alive := 0
	for e in enemies:
		var p = _enemy_pos(e)
		if p == null:
			continue
		alive += 1
		var being_served: bool = (e["end_type"] == "kill" and float(e["start_t"]) >= 0.0
			and now >= float(e["start_t"]))
		if being_served:
			var tw_pos: Vector2 = towers[int(e["tower"])]["pos"]
			draw_line(tw_pos, p, COL_FIRE, 2.0)
		var ecol: Color = COL_ENEMY_LEAK if e["end_type"] == "leak" else COL_ENEMY
		draw_circle(p, ENEMY_R, ecol)
		draw_arc(p, ENEMY_R, 0, TAU, 12, ecol.darkened(0.4), 1.5)

	# etiqueta de cola
	draw_string(font, queue_anchor + Vector2(-40, 70),
		"cola: %d" % _queue_len(), 0, -1, 16, COL_TEXT)


# ----------------------------------------------------------------------------- #
#  HUD                                                                            #
# ----------------------------------------------------------------------------- #
func _build_hud() -> void:
	hud = CanvasLayer.new()
	add_child(hud)

	lbl_title = _mk_label(Vector2(16, 10), 22)
	lbl_stats = _mk_label(Vector2(16, 44), 16)
	lbl_help = _mk_label(Vector2(16, 690), 13)
	lbl_help.text = "[Espacio] play/pausa   [←/→] velocidad   [R] reiniciar"


func _mk_label(pos: Vector2, size: int) -> Label:
	var l := Label.new()
	l.position = pos
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", COL_TEXT)
	hud.add_child(l)
	return l


func _update_hud() -> void:
	if not loaded:
		lbl_title.text = "Tower Defense Estocástico — falta output.json"
		return
	var meta: Dictionary = data["meta"]
	var p: Dictionary = data["params"]
	var ana: Dictionary = data["analytical"]
	var st: Dictionary = data["stats"]
	lbl_title.text = "Tower Defense Estocástico  —  %s   c=%d  K=%d" % [
		meta["model"], int(p["c"]), int(p["K"])]
	var rho := float(ana["rho"])
	lbl_stats.text = ("t = %6.1f / %.0f s   (x%.2f)\n" % [now, sim_time, speed]
		+ "λ=%.2f  μ=%.2f  ρ=%.3f  (%s)\n" % [float(p["lambda"]), float(p["mu"]), rho,
			"estable" if bool(ana["stable"]) else "inestable"]
		+ "cola=%d   base HP=%d/%d\n" % [_queue_len(), _base_hp(), int(st["base_hp_init"])]
		+ "fuga sim=%.1f%%   Wq sim=%.2fs   Lq sim=%.2f" % [
			float(st["leak_rate"]) * 100.0, float(st["avg_wait_q"]),
			float(st["avg_queue_len"])])
