extends Node2D
## Emoji 测试 demo（Godot 4.x）
## 不需要任何贴图和节点设置：把本脚本挂到一个空的 Node2D 上（或直接运行 demo.tscn）即可。
## 流程、按键、四条剧情线的判定逻辑和正式版 main.gd 完全一致，只是把立绘/UI/台词换成了 emoji。
##
## 想换 emoji：改下面的 STAND / HOLD / HEART_EMOJI / SIGNATURE 常量。
## 如果运行后 emoji 显示成方块：你的系统字体不含彩色 emoji，
## 可以在项目里导入 Noto Color Emoji 字体并设为项目默认字体的 fallback。

const A := 0
const B := 1
const HEART_COUNT := 12
const ROUTE_COUNT := 4
const PLAYER_FONT := 64
const HEART_FONT := 44

enum Route { SOLO_A, SOLO_B, LOVE_AB, LOVE_BA }
enum State { WAIT_KEY, INTRO, TUTORIAL, PLAYING, DIALOGUE, ENDING, PV }

## 每个角色的按键：上、下、左、右
const MOVE_KEYS := [
	[KEY_W, KEY_S, KEY_A, KEY_D],  # A
	[KEY_I, KEY_K, KEY_J, KEY_L],  # B
]

const STAND := ["🐱", "🐶"]                # 站立
const HOLD := ["😻", "🥰"]                 # 手抱爱心
const HEART_EMOJI := ["🤎", "❤️", "💜"]    # brown -> red -> purple&blue

## 每条剧情线的“标志 emoji”，用来在对话里区分是哪条线
const SIGNATURE := {
	Route.SOLO_A: "🌸",
	Route.SOLO_B: "🌊",
	Route.LOVE_AB: "✨",
	Route.LOVE_BA: "🌙",
}

const ENDING_PAGES := {
	Route.SOLO_A: ["🐱🤎🤎🤎  ➡️  🐱❤️❤️❤️", "🎉🎉🎉 🏆 🎉🎉🎉"],
	Route.SOLO_B: ["🐶🤎🤎🤎  ➡️  🐶❤️❤️❤️", "🎊🎊🎊 🏆 🎊🎊🎊"],
	Route.LOVE_AB: ["🐱➡️❤️➡️🐶", "💜💜💜 💙💙💙 💜💜💜"],
	Route.LOVE_BA: ["🐶➡️❤️➡️🐱", "💙💙💙 💜💜💜 💙💙💙"],
}

const TUTORIAL_TEXT := "🎮 怎么玩\n\n🐱 A：W A S D 移动　　🐶 B：I J K L 移动\n\n碰到 🤎 就能捡起爱心，抱着爱心时按【空格】触发对话\n\n1️⃣ 🐱 单人捡完 12 颗\n2️⃣ 🐶 单人捡完 12 颗\n3️⃣ 每颗爱心：🐱 先捡 → 🐶 再捡  💜\n4️⃣ 每颗爱心：🐶 先捡 → 🐱 再捡  💜\n\n四条线全部完成 → 🎬 PV 彩蛋　　（R：重开这一轮）"

@export var move_speed := 320.0
@export var pickup_radius := 56.0
@export var screen_margin := 40.0
@export var title_show_time := 2.5

var vp: Vector2
var state: State = State.WAIT_KEY

# UI
var ui: CanvasLayer
var press_label: Label
var rec_label: Label
var title_label: Label
var tutorial_label: Label
var next_btn: Button
var progress_root: Control
var progress_rects: Array[ColorRect] = []
var ending_title: Label
var dialogue_box: ColorRect
var dialogue_label: Label
var pv_root: Control
var pv_can_restart := false
var press_tween: Tween

# 游戏层
var game_layer: Node2D
var player_nodes: Array[Node2D] = []
var player_labels: Array[Label] = []
var start_pos: Array[Vector2] = []
var heart_labels: Array[Label] = []
var heart_pos: Array[Vector2] = []

# 游戏状态
var heart_picks: Array = []            # heart_picks[h] = [谁捡过, ...]
var pick_log: Array[Vector2i] = []     # 本轮所有捡取记录 (who, heart)
var pending := {}                      # 已捡起、等待按空格的那一次
var completed := {}                    # 已通关的剧情线
var ending_route := -1
var ending_pages: Array = []
var ending_index := 0


func _ready() -> void:
	vp = get_viewport_rect().size
	_build_background()
	_build_world()
	_build_ui()
	_update_progress()
	_reset_round()

	press_label.visible = true
	press_tween = _blink(press_label, 0.6)


# ---------------------------------------------------------------- 搭建场景

func _emoji_label(text: String, font_size: int) -> Label:
	var box := float(font_size) * 1.6
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", font_size)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.custom_minimum_size = Vector2(box, box)
	l.size = Vector2(box, box)
	l.position = -l.size / 2.0  # 让 label 以节点位置为中心
	return l


func _full_label(parent: Node, text: String, font_size: int, color := Color.WHITE) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", font_size)
	l.add_theme_color_override("font_color", color)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	parent.add_child(l)
	l.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	return l


func _build_background() -> void:
	var bg_layer := CanvasLayer.new()
	bg_layer.layer = -1
	add_child(bg_layer)
	var bg := ColorRect.new()
	bg.color = Color(0.13, 0.12, 0.2)
	bg_layer.add_child(bg)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)


func _build_world() -> void:
	game_layer = Node2D.new()
	game_layer.visible = false
	add_child(game_layer)

	# 12 颗爱心：固定位置，摆成一个椭圆
	var center := Vector2(vp.x * 0.5, vp.y * 0.45)
	for i in HEART_COUNT:
		var ang := TAU * i / HEART_COUNT - PI / 2.0
		var p := center + Vector2(cos(ang) * vp.x * 0.36, sin(ang) * vp.y * 0.28)
		var l := _emoji_label(HEART_EMOJI[0], HEART_FONT)
		l.position += p
		game_layer.add_child(l)
		heart_labels.append(l)
		heart_pos.append(p)

	# 两个角色
	var starts := [Vector2(vp.x * 0.35, vp.y * 0.45), Vector2(vp.x * 0.65, vp.y * 0.45)]
	for who in 2:
		var n := Node2D.new()
		n.position = starts[who]
		game_layer.add_child(n)
		var l := _emoji_label(STAND[who], PLAYER_FONT)
		n.add_child(l)
		player_nodes.append(n)
		player_labels.append(l)
		start_pos.append(n.position)


func _build_ui() -> void:
	ui = CanvasLayer.new()
	ui.layer = 1
	add_child(ui)

	press_label = _full_label(ui, "PRESS ANY KEY TO START ⌨️", 40)

	rec_label = Label.new()
	rec_label.text = "🔴 REC"
	rec_label.add_theme_font_size_override("font_size", 28)
	rec_label.add_theme_color_override("font_color", Color(1, 0.3, 0.3))
	rec_label.position = Vector2(24, 16)
	ui.add_child(rec_label)

	title_label = _full_label(ui, "💗 1001th Love 💗", 72)   # 游戏名占位

	tutorial_label = _full_label(ui, TUTORIAL_TEXT, 26)
	tutorial_label.offset_bottom = -130

	next_btn = Button.new()
	next_btn.text = "Next ▶"
	next_btn.add_theme_font_size_override("font_size", 28)
	next_btn.custom_minimum_size = Vector2(160, 56)
	next_btn.size = Vector2(160, 56)
	next_btn.position = Vector2(vp.x / 2.0 - 80.0, vp.y - 110.0)
	next_btn.focus_mode = Control.FOCUS_NONE
	next_btn.pressed.connect(_on_next_pressed)
	ui.add_child(next_btn)

	# 四格进度条
	progress_root = Control.new()
	progress_root.position = Vector2(vp.x - 4 * 64 - 40, 44)
	ui.add_child(progress_root)
	var cap := Label.new()
	cap.text = "PROGRESS 📈"
	cap.add_theme_font_size_override("font_size", 16)
	cap.position = Vector2(0, -26)
	progress_root.add_child(cap)
	var frame := ColorRect.new()
	frame.color = Color(0, 0, 0, 0.6)
	frame.size = Vector2(4 * 64 + 8, 32)
	progress_root.add_child(frame)
	for i in ROUTE_COUNT:
		var r := ColorRect.new()
		r.size = Vector2(56, 24)
		r.position = Vector2(8 + i * 64, 4)
		progress_root.add_child(r)
		progress_rects.append(r)

	# 结局标题 + 对话框
	ending_title = _full_label(ui, "", 64)
	ending_title.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	ending_title.offset_top = 80

	dialogue_box = ColorRect.new()
	dialogue_box.color = Color(0, 0, 0, 0.78)
	dialogue_box.position = Vector2(60, vp.y - 150)
	dialogue_box.size = Vector2(vp.x - 120, 130)
	ui.add_child(dialogue_box)
	dialogue_label = Label.new()
	dialogue_label.add_theme_font_size_override("font_size", 32)
	dialogue_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	dialogue_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	dialogue_box.add_child(dialogue_label)
	dialogue_label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT, Control.PRESET_MODE_MINSIZE, 20)

	# PV 彩蛋
	pv_root = Control.new()
	ui.add_child(pv_root)
	pv_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var pv_bg := ColorRect.new()
	pv_bg.color = Color(0.05, 0.02, 0.1)
	pv_root.add_child(pv_bg)
	pv_bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_full_label(pv_root, "🎬 PV 彩蛋 🎬\n\n🐱💗🐶\n\n💜💙💜💙💜💙💜💙\n\n🎉 THE END 🎉", 56)
	var again := _full_label(pv_root, "按任意键重新开始 🔄", 22, Color(1, 1, 1, 0.6))
	again.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	again.offset_bottom = -30

	for n in [press_label, rec_label, title_label, tutorial_label, next_btn,
			progress_root, ending_title, dialogue_box, pv_root]:
		n.visible = false


func _blink(n: CanvasItem, t: float) -> Tween:
	var tw := create_tween().set_loops()
	tw.tween_property(n, "modulate:a", 0.1, t)
	tw.tween_property(n, "modulate:a", 1.0, t)
	return tw


func _reset_round() -> void:
	pick_log.clear()
	pending = {}
	heart_picks.clear()
	for h in HEART_COUNT:
		heart_picks.append([])
		_refresh_heart(h)
	for who in 2:
		player_nodes[who].position = start_pos[who]
		player_labels[who].text = STAND[who]


# ---------------------------------------------------------------- 开场流程

func _start_intro() -> void:
	state = State.INTRO
	if press_tween:
		press_tween.kill()
	press_label.visible = false

	# REC 开始闪烁，代表游戏开始（整局一直闪）
	rec_label.visible = true
	_blink(rec_label, 0.5)
	await get_tree().create_timer(1.2).timeout

	# 游戏名淡入
	title_label.visible = true
	title_label.modulate.a = 0.0
	create_tween().tween_property(title_label, "modulate:a", 1.0, 0.8)
	await get_tree().create_timer(title_show_time).timeout

	# 标题消失，出现玩法引导 + Next
	title_label.visible = false
	tutorial_label.visible = true
	next_btn.visible = true
	state = State.TUTORIAL


func _on_next_pressed() -> void:
	if state != State.TUTORIAL:
		return
	tutorial_label.visible = false
	next_btn.visible = false
	game_layer.visible = true
	progress_root.visible = true
	_reset_round()
	state = State.PLAYING


# ---------------------------------------------------------------- 输入

func _unhandled_input(event: InputEvent) -> void:
	var k := event as InputEventKey
	if k == null or not k.pressed or k.echo:
		return

	match state:
		State.WAIT_KEY:
			_start_intro()
		State.PLAYING:
			if k.keycode == KEY_SPACE:
				_on_space()
			elif k.keycode == KEY_R:
				_reset_round()
		State.DIALOGUE:
			if k.keycode == KEY_SPACE:
				_close_dialogue()
		State.ENDING:
			if k.keycode == KEY_SPACE:
				_next_ending_page()
		State.PV:
			if pv_can_restart:
				get_tree().reload_current_scene()


# ---------------------------------------------------------------- 游戏主循环

func _process(delta: float) -> void:
	if state != State.PLAYING:
		return
	_move_players(delta)
	if pending.is_empty():
		_check_pickups()


func _move_players(delta: float) -> void:
	var lo := Vector2(screen_margin, screen_margin)
	for who in 2:
		var k: Array = MOVE_KEYS[who]
		var dir := Vector2(
			float(Input.is_physical_key_pressed(k[3])) - float(Input.is_physical_key_pressed(k[2])),
			float(Input.is_physical_key_pressed(k[1])) - float(Input.is_physical_key_pressed(k[0])))
		if dir != Vector2.ZERO:
			var n := player_nodes[who]
			n.position = (n.position + dir.normalized() * move_speed * delta).clamp(lo, vp - lo)


func _check_pickups() -> void:
	for who in 2:
		var pos := player_nodes[who].position
		for h in HEART_COUNT:
			if heart_picks[h].has(who):
				continue  # 同一个角色不能重复捡同一颗
			if pos.distance_to(heart_pos[h]) <= pickup_radius:
				_begin_pick(who, h)
				return


func _begin_pick(who: int, h: int) -> void:
	pick_log.append(Vector2i(who, h))
	heart_picks[h].append(who)
	player_labels[who].text = HOLD[who]  # 站立 -> 手抱爱心

	# 找出当前仍然成立的剧情线（单人线优先于双人线）
	var alive: Array = []
	for r in [Route.SOLO_A, Route.SOLO_B, Route.LOVE_AB, Route.LOVE_BA]:
		if _route_alive(r):
			alive.append(r)

	var text := ""
	var complete := -1
	if alive.is_empty():
		# 所有剧情线都被打断：给出提示对话
		text = "%s：❓💔❓　按 R 🔄 重来" % STAND[who]
	else:
		var r: int = alive[0]
		text = _make_line(r, who, pick_log.size() - 1)
		if pick_log.size() == _route_length(r):
			complete = r

	pending = {"who": who, "heart": h, "text": text, "complete": complete}


## 用 emoji 生成台词（数字只是为了方便你测试时看进度）
func _make_line(route: int, who: int, index: int) -> String:
	var sig: String = SIGNATURE[route]
	if route <= Route.SOLO_B:
		# 单人线：第 n 颗就显示 n 个标志 emoji
		return "%s：%s　%d/%d" % [STAND[who], sig.repeat(index + 1), index + 1, HEART_COUNT]
	# 双人线：先手把 🤎 变 ❤️，后手把 ❤️ 变 💜
	var first := A if route == Route.LOVE_AB else B
	var change := "🤎➡️❤️" if who == first else "❤️➡️💜"
	var pair := floori(index / 2.0) + 1
	return "%s：%s%s　%d/%d" % [STAND[who], sig, change, pair, HEART_COUNT]


func _route_length(r: int) -> int:
	return HEART_COUNT if r <= Route.SOLO_B else HEART_COUNT * 2


func _route_alive(r: int) -> bool:
	if r == Route.SOLO_A:
		return _solo_alive(A)
	if r == Route.SOLO_B:
		return _solo_alive(B)
	if r == Route.LOVE_AB:
		return _love_alive(A)
	if r == Route.LOVE_BA:
		return _love_alive(B)
	return false


## 单人线：到目前为止所有记录都是同一个角色
func _solo_alive(who: int) -> bool:
	for e in pick_log:
		if e.x != who:
			return false
	return true


## 双人线：每颗爱心 first 先捡、另一人紧接着捡同一颗
func _love_alive(first: int) -> bool:
	for i in pick_log.size():
		var e := pick_log[i]
		if i % 2 == 0:
			if e.x != first:
				return false
		else:
			if e.x == first or e.y != pick_log[i - 1].y:
				return false
	return true


func _refresh_heart(h: int) -> void:
	# 0 人捡过 = brown，1 人 = red，2 人 = purple&blue
	heart_labels[h].text = HEART_EMOJI[mini(heart_picks[h].size(), 2)]


# ---------------------------------------------------------------- 对话

func _on_space() -> void:
	if pending.is_empty():
		return
	_refresh_heart(pending.heart)
	dialogue_label.text = pending.text
	dialogue_box.visible = true
	state = State.DIALOGUE


func _close_dialogue() -> void:
	dialogue_box.visible = false
	var who: int = pending.who
	player_labels[who].text = STAND[who]  # 手抱爱心 -> 站立
	var done: int = pending.complete
	pending = {}
	if done >= 0:
		_start_ending(done)
	else:
		state = State.PLAYING


# ---------------------------------------------------------------- 结局 / 进度 / PV

func _start_ending(route: int) -> void:
	state = State.ENDING
	ending_route = route
	ending_title.text = "💜💙 FOREVER LOVE 💙💜" if route >= Route.LOVE_AB else "🎉 HAPPY ENDING 🎉"
	ending_title.visible = true
	ending_pages = ENDING_PAGES[route]
	ending_index = 0
	dialogue_label.text = ending_pages[0]
	dialogue_box.visible = true


func _next_ending_page() -> void:
	ending_index += 1
	if ending_index < ending_pages.size():
		dialogue_label.text = ending_pages[ending_index]
		return

	# 结局播完：进度 +1
	ending_title.visible = false
	dialogue_box.visible = false
	completed[ending_route] = true
	_update_progress()

	if completed.size() >= ROUTE_COUNT:
		_start_pv()
	else:
		_reset_round()
		state = State.PLAYING


func _update_progress() -> void:
	for i in progress_rects.size():
		progress_rects[i].color = Color(1.0, 0.8, 0.25) if i < completed.size() else Color(0.3, 0.3, 0.35)


func _start_pv() -> void:
	state = State.PV
	game_layer.visible = false
	pv_root.visible = true
	await get_tree().create_timer(1.0).timeout
	pv_can_restart = true
