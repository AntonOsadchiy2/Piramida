extends Control

const Lifecycle = preload("res://scripts/application/lifecycle_controller.gd")
const State = preload("res://scripts/domain/game_state.gd")
const Owner = State.Owner
const Diagnostics = preload("res://scripts/simulation/production_diagnostics.gd")

signal restart_requested
signal upgrade_purchased

const ART := "res://assets/sprites/"
const ROLE_ICONS := ["icon_miner", "icon_porter", "icon_dresser", "icon_builder"]

const SETTINGS_PATH := "user://settings.cfg"

const ROLES := ["Добыча", "Носильщики", "Обработка", "Строительство"]
const SPEED := ["MINER_SPEED", "PORTER_SPEED", "DRESSER_SPEED", "BUILDER_SPEED"]
const STAGES := [["miner"], ["porter"], ["dresser"], ["builder", "lift"]]
const FLOW := ["mined", "delivered", "processed", "placed"]
const UNITS := ["глыб", "глыб", "кирпичей", "кирпичей"]
const STOCKS := {Owner.QUARRY: "Карьер", Owner.RAW: "Сырьё",
	Owner.FINISHED: "У подъёмника", Owner.PLATFORM: "На лесах"}
const REASONS := {
	"quarry_full": "Очередь карьера заполнена",
	"raw_full": "Склад сырья заполнен или зарезервирован",
	"wait_stone": "Ожидание свободной глыбы в карьере",
	"wait_raw": "Глыбы в карьере ожидают вывоза",
	"wait_quarry": "Ожидание добычи или пополнения очереди карьера",
	"raw_in_transit": "Сырьё зарезервировано и ожидает доставки",
	"brick_full": "Готовый кирпич ждёт вывоза",
	"row_transition": "Переход на новый ряд",
	"wait_brick": "Строитель ждёт готовый кирпич",
	"base_full": "У основания подъёмника нет места для новых кирпичей",
}

var _lifecycle: Lifecycle
var _state: State
var _diagnostics: Diagnostics
var _totals: PackedInt32Array
var _step: float
var _stats_time := 0.0
var _mode := -1
var _role := -1
var _detail := -1
var _world_config: Dictionary
var _row_reward: int
var _snapshot: Array = []
var _quoted_levels: Dictionary
var _stocks: Dictionary
var _buy: Dictionary
var _top: Label
var _pause: Button
var _notice: Label
var _notice_timer: Timer
var _card: PanelContainer
var _title: Label
var _stats: Label
var _detail_label: Label
var _overlay: ColorRect
var _dialog: VBoxContainer
var _screen := ""
var _offline_summary: Dictionary = {}
var _victory_seen := false
var _settings := ConfigFile.new()
var _show_tutorial := true
var _tutorial: PanelContainer
var _hint: Label


func setup(lifecycle: Lifecycle, balance: Dictionary) -> void:
	_lifecycle = lifecycle
	_state = lifecycle.session.simulation.state
	_world_config = balance.world
	_row_reward = int(balance.economy.coinsPerRow)
	_step = float(balance.simulation.fixedStepSeconds)
	_reset_statistics()
	_settings.load(SETTINGS_PATH)
	_apply_volume(&"Music", _volume(&"Music"))
	_apply_volume(&"SFX", _volume(&"SFX"))
	_show_tutorial = _settings.get_value("display", "tutorial", true) == true
	_build()
	_build_flow()
	_refresh_tutorial()
	refresh_mode()
	refresh_flow()


func _build() -> void:
	theme = Theme.new()
	theme.default_font_size = 20
	theme.set_constant("icon_max_width", "Button", 24)
	for state: String in ["normal", "hover", "pressed", "disabled", "hover_pressed"]:
		var box := _texture_box("ui_button", Vector2(22, 14), Vector2(12, 7))
		match state:
			"hover":
				box.modulate_color = Color("#fff1dd")
			"pressed", "hover_pressed":
				box.modulate_color = Color("#d1b2c4")
			"disabled":
				box.modulate_color = Color("#8f8188")
		theme.set_stylebox(state, "Button", box)
	$CameraButtons/Overview.icon = load(ART + "icon_overview.png")

	var header := HBoxContainer.new()
	_place(_panel(header), 0.0, 12.0, 64.0)
	_add_icon(header, "coin")
	_top = _label(header)
	_top.size_flags_horizontal = SIZE_EXPAND_FILL
	_pause = _button(header, "Пауза", toggle_pause, "icon_pause")
	$CameraButtons.offset_top = 76

	_notice_timer = Timer.new()
	_notice_timer.one_shot = true
	_notice_timer.timeout.connect(func(): _notice.text = "")
	add_child(_notice_timer)
	_notice = _label(self)
	_notice.add_theme_color_override("font_color", Color("#282018"))
	_notice.set_anchors_and_offsets_preset(PRESET_TOP_RIGHT)
	_notice.offset_left = -510
	_notice.offset_right = -12
	_notice.offset_top = 76
	_notice.offset_bottom = 124
	_notice.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT

	var footer := VBoxContainer.new()
	var roles := HBoxContainer.new()
	var stocks := HBoxContainer.new()
	footer.add_child(stocks)
	footer.add_child(roles)
	_place(_panel(footer), 1.0, -120.0, -12.0)
	for owner in STOCKS:
		var button := _button(stocks, STOCKS[owner], _toggle_stock.bind(owner))
		button.size_flags_horizontal = SIZE_EXPAND_FILL
		var bar := ProgressBar.new()
		bar.show_percentage = false
		bar.mouse_filter = MOUSE_FILTER_IGNORE
		button.add_child(bar)
		bar.set_anchors_and_offsets_preset(PRESET_BOTTOM_WIDE)
		bar.offset_left = 6
		bar.offset_right = -6
		bar.offset_top = -7
		bar.offset_bottom = -3
		_stocks[owner] = [button, bar]
	for role in range(ROLES.size()):
		_button(roles, ROLES[role], _toggle_role.bind(role), ROLE_ICONS[role]).size_flags_horizontal = SIZE_EXPAND_FILL

	_detail_label = _label(self)
	_detail_label.set_anchors_and_offsets_preset(PRESET_BOTTOM_LEFT)
	_detail_label.offset_left = 12
	_detail_label.offset_top = -170
	_detail_label.offset_bottom = -124
	_detail_label.add_theme_stylebox_override("normal", _background())
	_detail_label.hide()

	var card_body := VBoxContainer.new()
	_card = _panel(card_body)
	_card.set_anchors_and_offsets_preset(PRESET_BOTTOM_RIGHT)
	_card.grow_vertical = GROW_DIRECTION_BEGIN
	_card.grow_horizontal = GROW_DIRECTION_BEGIN
	_card.offset_left = -540
	_card.offset_right = -12
	_card.offset_bottom = -128
	_card.offset_top = -128
	var heading := HBoxContainer.new()
	card_body.add_child(heading)
	_title = _label(heading)
	_title.size_flags_horizontal = SIZE_EXPAND_FILL
	_button(heading, "Закрыть", close_card, "icon_close")
	_stats = _label(card_body)
	_stats.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_stats.custom_minimum_size.y = 78
	for code in SPEED + ["HIRE_PORTER", "PORTER_CAPACITY"]:
		var icon := "icon_speed"
		match code:
			"HIRE_PORTER":
				icon = "icon_hire"
			"PORTER_CAPACITY":
				icon = "icon_capacity"
		_buy[code] = _button(card_body, "", _purchase.bind(code), icon)
	_card.hide()


func _background() -> StyleBoxTexture:
	return _texture_box("ui_panel", Vector2(20, 20), Vector2(14, 10))


func _texture_box(name: String, border: Vector2, padding: Vector2) -> StyleBoxTexture:
	var box := StyleBoxTexture.new()
	box.texture = load(ART + name + ".png")
	box.region_rect = Rect2(8, 8, 80, 80) if name == "ui_panel" else Rect2(9, 10, 78, 44)
	box.texture_margin_left = border.x
	box.texture_margin_right = border.x
	box.texture_margin_top = border.y
	box.texture_margin_bottom = border.y
	box.content_margin_left = padding.x
	box.content_margin_right = padding.x
	box.content_margin_top = padding.y
	box.content_margin_bottom = padding.y
	return box


func _add_icon(parent: Control, name: String) -> void:
	var icon := TextureRect.new()
	icon.texture = load(ART + name + ".png")
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.custom_minimum_size = Vector2(24, 24)
	icon.mouse_filter = MOUSE_FILTER_IGNORE
	parent.add_child(icon)


func _panel(content: Control) -> PanelContainer:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _background())
	add_child(panel)
	panel.add_child(content)
	return panel


func _place(control: Control, anchor: float, top: float, bottom: float) -> void:
	control.anchor_right = 1.0
	control.anchor_top = anchor
	control.anchor_bottom = anchor
	control.offset_left = 12
	control.offset_right = -12
	control.offset_top = top
	control.offset_bottom = bottom


func _label(parent: Control) -> Label:
	var label := Label.new()
	parent.add_child(label)
	return label


func _button(parent: Control, caption: String, action: Callable, icon: String = "") -> Button:
	var button := Button.new()
	button.text = caption
	if not icon.is_empty():
		button.icon = load(ART + icon + ".png")
	button.custom_minimum_size = Vector2(48, 48)
	parent.add_child(button)
	button.pressed.connect(action)
	return button


func select_worker(id: int) -> void:
	if id >= Owner.FIRST_PORTER:
		_open_role(1)
	elif id == Owner.MINER:
		_open_role(0)
	elif id == Owner.DRESSER:
		_open_role(2)
	else:
		_open_role(3)


func _toggle_role(role: int) -> void:
	if _role == role:
		close_card()
	else:
		_open_role(role)


func _open_role(role: int) -> void:
	_role = role
	_detail = -1
	_detail_label.hide()
	_card.show()
	_title.text = ROLES[role]
	_refresh_card()
	_refresh_statistics()


func close_card() -> void:
	_role = -1
	_card.hide()
	_detail = -1
	_detail_label.hide()


func _toggle_stock(owner: int) -> void:
	var show_detail := _detail != owner
	close_card()
	if show_detail:
		_detail = owner
		_refresh_stock_detail()
		_detail_label.show()


func toggle_pause() -> void:
	if _lifecycle.mode == Lifecycle.Mode.ACTIVE:
		_lifecycle.set_paused(true)
		refresh_mode()
		_show_pause()


func back() -> void:
	if _lifecycle.mode in [Lifecycle.Mode.BACKGROUND, Lifecycle.Mode.RESTORING]:
		return
	match _screen:
		"settings", "confirm", "restart_error":
			_show_pause()
		"pause":
			_resume()
		"offline":
			_dismiss_report()
		"victory":
			_inspect()
		_:
			if _role >= 0 or _detail >= 0:
				close_card()
			else:
				toggle_pause()



func refresh_mode() -> void:
	if _mode == _lifecycle.mode:
		return
	var restoring := _mode == Lifecycle.Mode.RESTORING
	_mode = _lifecycle.mode
	_pause.disabled = _mode not in [Lifecycle.Mode.ACTIVE, Lifecycle.Mode.PAUSED]
	_pause.text = "Пауза"
	if restoring:
		_reset_statistics()
		_refresh_statistics()
	_refresh(true)


func tick() -> void:
	var next := Diagnostics.totals(_state)
	_diagnostics.record(_diagnostics.waiting_reasons(_state), _totals, next)
	_totals = next
	_stats_time += _step
	if _stats_time >= 1.0 - 0.000001 or _state.finished:
		_stats_time = 0.0
		_refresh_statistics()
	_refresh()
	_refresh_tutorial()


func _reset_statistics() -> void:
	_diagnostics = Diagnostics.new(_step)
	_totals = Diagnostics.totals(_state)
	_stats_time = 0.0


func _refresh(force: bool = false) -> void:
	var layer := _state.geometry.quarry_depth(_state.mined_count()) + 1
	var snapshot := [_state.currency, _state.placed_count(), _state.current_row,
		layer, _state.completed_rows, _state.finished]
	for owner in STOCKS:
		snapshot.append(_state.stock_count(owner))
		snapshot.append(_state.incoming_count(owner))
	if not force and snapshot == _snapshot:
		return
	if not force and not _snapshot.is_empty():
		var notices := PackedStringArray()
		if snapshot[3] > _snapshot[3]:
			notices.append("Новый слой карьера")
		if snapshot[4] > _snapshot[4]:
			notices.append("Ряд завершён · +%d монет" % _row_reward)
		if not notices.is_empty():
			_show_notice("  •  ".join(notices))
	_snapshot = snapshot
	_top.text = "Монеты %d     Кирпичи %d/%d     Ряд %d/%d     Слой %d/%d" % [
		snapshot[0], snapshot[1], State.RESOURCE_COUNT, snapshot[2] + 1,
		int(_world_config.pyramidRows), layer, int(_world_config.quarryLayers)]
	for owner in STOCKS:
		var stock := _state.stock_count(owner)
		var bar: ProgressBar = _stocks[owner][1]
		bar.max_value = stock + _state.incoming_count(owner) + _state.free_slots(owner)
		bar.value = stock
	if _detail >= 0:
		_refresh_stock_detail()
	if _role >= 0:
		_refresh_card()


func _refresh_stock_detail() -> void:
	var stock := _state.stock_count(_detail)
	var reserved := _state.incoming_count(_detail)
	_detail_label.text = "%s · %d/%d · в резерве %d" % [STOCKS[_detail], stock,
		stock + reserved + _state.free_slots(_detail), reserved]


func _refresh_card() -> void:
	for code in _buy:
		var button: Button = _buy[code]
		button.visible = code == SPEED[_role] or (_role == 1 and code not in SPEED)
		if not button.visible:
			continue
		var quote := _lifecycle.session.purchases.quote(code)
		_quoted_levels[code] = quote.level
		var caption: String
		match code:
			"HIRE_PORTER":
				caption = "Носильщиков %d · нанять ещё" % quote.level
			"PORTER_CAPACITY":
				caption = "Вместимость %d · +1 глыба" % quote.level
			_:
				var multiplier := _lifecycle.session.simulation.economy.speed_effect(code)
				caption = "Скорость · ур. %d · следующий ×%.2f" % [quote.level, multiplier]
		if quote.price < 0:
			caption = caption.get_slice(" · ", 0) + " · " + ("Стройка завершена" if _state.finished else "Предел")
			if code in SPEED:
				caption = "Скорость · ур. %d · %s" % [quote.level, "Стройка завершена" if _state.finished else "Предел"]
		else:
			caption += " · %d монет" % quote.price
		button.text = caption
		button.disabled = not quote.available


func _refresh_statistics() -> void:
	if _role < 0:
		return
	var reason := _diagnostics.dominant_wait(STAGES[_role])
	_stats.text = "Темп %.1f %s/мин\n%s" % [
		_diagnostics.rates()[FLOW[_role]], UNITS[_role],
		REASONS.get(reason, "Заметного ожидания пока нет")]
	if _state.finished:
		_stats.text = "Стройка завершена"
	elif _state.mined_count() == State.RESOURCE_COUNT and _role == 0:
		_stats.text = "Карьер выработан"


func _purchase(code: String) -> void:
	if _lifecycle.session.purchases.purchase(code, _quoted_levels[code]):
		_lifecycle.session.flush_save()
		upgrade_purchased.emit()
	_refresh(true)


func _show_notice(message: String) -> void:
	_notice.text = message
	_notice_timer.start(3.0)


func _build_flow() -> void:
	var hints := HBoxContainer.new()
	_tutorial = _panel(hints)
	_place(_tutorial, 0.0, 132.0, 184.0)
	_hint = _label(hints)
	_hint.size_flags_horizontal = SIZE_EXPAND_FILL
	_button(hints, "Пропустить", _skip_tutorial)

	_overlay = ColorRect.new()
	_overlay.color = Color(0.10, 0.08, 0.06, 0.68)
	add_child(_overlay)
	_overlay.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	var center := CenterContainer.new()
	_overlay.add_child(center)
	center.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	_dialog = VBoxContainer.new()
	_dialog.custom_minimum_size.x = 460
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _background())
	panel.add_child(_dialog)
	center.add_child(panel)
	_overlay.hide()


func blocks_play() -> bool:
	return not _screen.is_empty()


func refresh_flow() -> void:
	_overlay.visible = blocks_play() and _lifecycle.mode != Lifecycle.Mode.BACKGROUND
	if _lifecycle.mode == Lifecycle.Mode.BACKGROUND:
		return
	if _lifecycle.mode == Lifecycle.Mode.RESTORING:
		if _screen != "restoring":
			_open_dialog("restoring", "Восстанавливаем стройку…")
		return
	if _screen == "restoring":
		_close_dialog()
	if not blocks_play():
		if not _offline_summary.is_empty():
			_show_report()
		elif _state.finished and not _victory_seen:
			_show_victory()
		elif _lifecycle.mode == Lifecycle.Mode.PAUSED:
			_show_pause()


func _refresh_tutorial() -> void:
	var visible_hint := _show_tutorial and not _lifecycle.tutorial_skipped and not _state.finished
	if visible_hint:
		var totals := _totals
		var tips := [
			"Каменотёс добывает первую глыбу.",
			"Глыба добыта. Носильщик доставит её на склад сырья.",
			"Глыба доставлена. Обработчик вытешет из неё кирпич.",
			"Кирпич готов. Его заберёт строитель или свободный носильщик.",
			"Строитель забрал кирпич и уложит его в первый ряд.",
		]
		var stage := 0
		while stage < totals.size() and totals[stage] > 0:
			stage += 1
		if stage == tips.size():
			visible_hint = _state.completed_rows == 0
			_hint.text = "Первый кирпич уложен. Улучшения доступны на нижней панели."
		else:
			_hint.text = tips[stage]
	_tutorial.visible = visible_hint


func _skip_tutorial() -> void:
	_lifecycle.skip_tutorial()
	_refresh_tutorial()


func _open_dialog(screen: String, title: String, message: String = "") -> void:
	close_card()
	_screen = screen
	var focused := get_viewport().gui_get_focus_owner()
	if focused != null:
		focused.release_focus()
	for child in _dialog.get_children():
		_dialog.remove_child(child)
		child.queue_free()
	var heading := _label(_dialog)
	heading.text = title
	heading.add_theme_font_size_override("font_size", 28)
	if not message.is_empty():
		var body := _label(_dialog)
		body.text = message
	_overlay.show()


func _close_dialog() -> void:
	_screen = ""
	_overlay.hide()
	_refresh_tutorial()


func _show_pause() -> void:
	_open_dialog("pause", "Пауза")
	_button(_dialog, "Продолжить", _resume)
	_button(_dialog, "Настройки", _show_settings)
	_button(_dialog, "Новая игра", _confirm_restart)


func _resume() -> void:
	_lifecycle.set_paused(false)
	_close_dialog()
	refresh_mode()
	refresh_flow()


func _show_settings(error: String = "") -> void:
	_open_dialog("settings", "Настройки", error)
	var caption := "Подсказки обучения включены" if _show_tutorial else "Подсказки обучения выключены"
	_button(_dialog, caption, _toggle_tutorial_setting)
	_add_volume_control("Музыка", &"Music")
	_add_volume_control("Звуки", &"SFX")
	_button(_dialog, "Назад", _show_pause)


func _volume(bus: StringName) -> float:
	return clampf(float(_settings.get_value("audio", String(bus), 1.0)), 0.0, 1.0)


func _apply_volume(bus: StringName, value: float) -> void:
	var index := AudioServer.get_bus_index(bus)
	AudioServer.set_bus_volume_linear(index, value)
	AudioServer.set_bus_mute(index, is_zero_approx(value))


func _add_volume_control(caption: String, bus: StringName) -> void:
	var row := HBoxContainer.new()
	_dialog.add_child(row)
	_add_icon(row, "icon_music" if bus == &"Music" else "icon_sound")
	var label := _label(row)
	var slider := HSlider.new()
	slider.custom_minimum_size.y = 44
	slider.max_value = 1.0
	slider.step = 0.05
	slider.value = _volume(bus)
	label.text = "%s · %d%%" % [caption, roundi(slider.value * 100)]
	_dialog.add_child(slider)
	slider.value_changed.connect(func(value: float) -> void:
		_apply_volume(bus, value)
		label.text = "%s · %d%%" % [caption, roundi(value * 100)]
		_settings.set_value("audio", String(bus), value)
		if _settings.save(SETTINGS_PATH) != OK:
			label.text += " · не сохранено"
	)


func _toggle_tutorial_setting() -> void:
	_settings.set_value("display", "tutorial", not _show_tutorial)
	if _settings.save(SETTINGS_PATH) != OK:
		_show_settings("Не удалось сохранить настройки.")
		return
	_show_tutorial = not _show_tutorial
	_refresh_tutorial()
	_show_settings()


func _confirm_restart() -> void:
	_open_dialog("confirm", "Начать новую игру?", "Текущий прогресс будет сброшен.")
	_button(_dialog, "Начать заново", func(): restart_requested.emit())
	_button(_dialog, "Отмена", _show_pause)


func show_restart_error() -> void:
	_open_dialog("restart_error", "Не удалось начать новую игру", "Текущая игра остаётся доступной.")
	_button(_dialog, "Назад", _show_pause)


func show_offline_report(summary: Dictionary) -> void:
	_offline_summary = summary
	_reset_statistics()
	_refresh_tutorial()
	_show_report()


func _show_report() -> void:
	var summary := _offline_summary
	var message := (
		"Учтённое отсутствие: %s\nВремя работы: %s\nДобыто глыб: %d\nДоставлено глыб: %d\n"
		+ "Обработано кирпичей: %d\nУложено кирпичей: %d\nЗавершено рядов: %d\nЗаработано монет: %d"
	) % [_duration(summary.credited_seconds), _duration(summary.simulated_seconds),
		summary.mined, summary.delivered, summary.processed, summary.placed, summary.rows, summary.currency]
	_open_dialog("offline", "Работа в ваше отсутствие", message)
	_button(_dialog, "Продолжить", _dismiss_report)


func _dismiss_report() -> void:
	_offline_summary.clear()
	_close_dialog()
	refresh_flow()


func _show_victory() -> void:
	var message := "Уложено кирпичей: %d\nРядов: %d\nВремя строительства: %s" % [
		_state.placed_count(), _state.completed_rows,
		_duration(_lifecycle.session.simulation.elapsed_seconds())]
	_open_dialog("victory", "Пирамида построена!", message)
	_button(_dialog, "Осмотреть пирамиду", _inspect)


func _inspect() -> void:
	_victory_seen = true
	if _lifecycle.mode == Lifecycle.Mode.PAUSED:
		_lifecycle.set_paused(false)
	_close_dialog()
	$CameraButtons/Construction.pressed.emit()


func _duration(seconds: float) -> String:
	return "%d ч %02d мин %02d с" % [floori(seconds / 3600.0),
		floori(seconds / 60.0) % 60, int(seconds) % 60]



