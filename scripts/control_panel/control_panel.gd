extends Window
@onready var main: Node2D = get_parent()

@export_category("General")
@export var obs: ObsWebSocketClient

@export_category("UI")
@export var current_prompt: Label
@export var current_speech: Label
@export var cancel_button: Button
@export var pause_button: Button

@export_category("Timers")
@export var stats_timer: Timer
@export var status_timer: Timer

var OpCodes := ObsWebSocketClient.OpCodeEnums.WebSocketOpCode

var anim_menu: Array
var expr_menu: Array

var is_streaming = false

# region MAIN

func _ready() -> void:
	generate_model_controls()
	connect_signals()
	obs_connection()

func _process(_delta) -> void:
	var render_data = {
		"fps": Performance.get_monitor(Performance.Monitor.TIME_FPS),
		"frameTime": Performance.get_monitor(Performance.Monitor.TIME_PROCESS),
		"videoMemoryUsed": Performance.get_monitor(Performance.Monitor.RENDER_VIDEO_MEM_USED),
		"audioLatency": Performance.get_monitor(Performance.Monitor.AUDIO_OUTPUT_LATENCY),
	}

	insert_data(render_data, %GodotStats, Templates.godot_stats_template)

func obs_connection() -> void:
	# OBS Connection
	obs.establish_connection()
	await obs.connection_authenticated
	obs.data_received.connect(_on_data_received)
	change_status_color(%ObsClientStatus, true)

	# OBS Data init
	obs.send_command_batch([
		"GetSceneList",
		"GetInputList",
		"GetStats",
		# "GetStreamStatus"
	])

	# OBS Stats timers
	stats_timer.start()
	# status_timer.start()

	# Pause
	if Globals.is_paused:
		pause_button.button_pressed = true
		_on_pause_speech_toggled(true)

func connect_signals() -> void:
	Globals.set_toggle.connect(update_toggle_controls)
	Globals.incoming_speech.connect(_on_incoming_speech.unbind(1))
	Globals.new_speech.connect(_on_new_speech)
	print_debug("Control Panel: connected signals")

# TODO: find a way to a make THIS a generic function lule
func generate_model_controls():
	for b in [%Animations, %Expressions, %Toggles]:
		for n in b.get_children():
			n.queue_free()

	# Animations
	var anim_label = Label.new()
	anim_label.text = "Animations"
	%Animations.add_child(anim_label)

	for a in Globals.animations:
		var anim = Button.new()
		anim.text = a
		anim.name = "Anim%s" % [a.to_camel_case().capitalize()]
		anim.pressed.connect(func (): Globals.play_animation.emit(a))
		%Animations.add_child(anim)

	# Expressions
	var expr_label = Label.new()
	expr_label.text = "Expressions"
	%Expressions.add_child(expr_label)

	for a in Globals.expressions:
		var expr = Button.new()
		expr.text = a
		expr.name = "Expr%s" % [a.to_camel_case().capitalize()]
		expr.pressed.connect(func (): Globals.set_expression.emit(a))
		%Expressions.add_child(expr)

	# Toggles
	for a in Globals.toggles:
		var toggle = CheckButton.new()
		toggle.text = a
		toggle.name = "Toggle%s" % [a.to_camel_case().capitalize()]
		toggle.button_pressed = Globals.toggles[a].enabled
		toggle.pressed.connect(_on_toggle_pressed.bind(toggle))
		%Toggles.add_child(toggle)

# endregion

# region INCOMING DATA

func _on_data_received(data):
	match data.op:
		OpCodes.Event.IDENTIFIER_VALUE:
			_handle_event(data.d)

		OpCodes.RequestResponse.IDENTIFIER_VALUE:
			_handle_request(data.d)

		OpCodes.RequestBatchResponse.IDENTIFIER_VALUE:
			for i in data.d.results:
				_handle_request(i)

		_:
			print_debug("Unhandled op: ", data.op)
			print_debug(data)
			print_debug("-------------")

func _handle_event(data):
	match data.eventType:
		"CurrentProgramSceneChanged", "SceneListChanged":
			obs.send_command("GetSceneList")

		"InputMuteStateChanged":
			change_input_state(data.eventData)

		"InputNameChanged":
			change_input_name(data.eventData)

		"StreamStateChanged":
			if is_streaming != data.eventData.outputActive:
				is_streaming = data.eventData.outputActive
				update_stream_control_button()

		"ExitStarted":
			stop_processing()

		# Ignored callbacks
		"SceneNameChanged":
			pass # handled by SceneListChanged

		"SceneTransitionStarted", "SceneTransitionVideoEnded", "SceneTransitionEnded":
			pass # We don't need it

		_:
			pass
			# print_debug("Unhandled event: ", data.eventType)
			# print_debug(data)
			# print_debug("-------------")

func _handle_request(data):
	if not data.requestStatus.result:
		if data.requestStatus.code != 604:
			print_debug("Error in request: ", data)
			return
		return

	match data.requestType:
		"GetStats":
			insert_data(data.responseData, %StreamStats, Templates.obs_stats_template)

		"GetStreamStatus":
			var status = data.responseData
			# insert_data(status, %StreamStatus, "")
			if is_streaming != status.outputActive:
				is_streaming = status.outputActive
				update_stream_control_button()

		"GetSceneList":
			generate_scene_buttons(data.responseData)

		"GetInputList":
			generate_input_request(data.responseData.inputs)

		"GetInputMute":
			var inputData := {
				"inputName": data.requestId,
				"inputMuted": data.responseData.inputMuted
			}
			generate_input_button(inputData)

		# Ignored callbacks
		"ToggleInputMute":
			pass # handled by InputMuteStateChanged event

		"SetCurrentProgramScene", "ToggleStream":
			pass # handled by StreamChateChanged event

		_:
			print("Unhandled request: ", data.requestType)
			print(data)
			print("-------------")

# endregion

# region TIMERS

func _on_stats_timer_timeout():
	obs.send_command("GetStats")

func _on_status_timer_timeout():
	obs.send_command("GetStreamStatus")

# endregion

# region UI FUNCTIONS

func _on_dancing_toggle_toggled(button_pressed: bool):
	var wait_time = float(%DancingWaitTime.value)
	var bpm = float(%DancingBpm.value)

	if button_pressed:
		Globals.start_dancing_motion.emit(wait_time, bpm)
		%DancingToggle.text = ">> Stop <<"
	else:
		Globals.end_dancing_motion.emit()
		%DancingToggle.text = "Start"

func _on_toggle_pressed(toggle: CheckButton):
	Globals.set_toggle.emit(toggle.text, toggle.button_pressed)

func _on_new_speech(prompt, text) -> void:
	current_speech.remove_theme_color_override("font_color")
	current_prompt.text = prompt
	current_speech.text = text

func _on_incoming_speech():
	current_speech.text = str(randi())

func update_toggle_controls(toggle_name: String, enabled: bool):
	var ui_name := "Toggle%s" % [toggle_name.to_camel_case().capitalize()]
	var toggle: CheckButton = %Toggles.get_node(ui_name)
	if toggle:
		toggle.button_pressed = enabled

func change_status_color(node: Node, active: bool) -> void:
	node.get_theme_stylebox("panel").bg_color = Color(0, 1, 0) if active else Color(1, 0, 0)

func update_stream_control_button():
	if is_streaming:
		%ObsStreamControl.text = "Stop Stream"
		for i in ["font_color", "font_hover_color", "font_focus_color", "font_pressed_color"]:
			%ObsStreamControl.add_theme_color_override(i, Color(1, 0, 0))
	else:
		%ObsStreamControl.text = "Start Stream"
		for i in ["font_color", "font_hover_color", "font_focus_color", "font_pressed_color"]:
			%ObsStreamControl.remove_theme_color_override(i)

func _on_obs_stream_control_pressed():
	obs.send_command("ToggleStream")

func _on_scene_button_pressed(button):
	obs.send_command("SetCurrentProgramScene", { "sceneName": button.text })

func generate_scene_buttons(data):
	var active_scene = null
	if data.has("currentProgramSceneName"):
		active_scene = data.currentProgramSceneName
	var scenes = data.scenes
	scenes.reverse()

	for n in %ObsScenes.get_children():
		n.queue_free()

	for scene in scenes:
		var button = Button.new()
		button.text = scene.sceneName
		if (scene.sceneName == active_scene):
			for i in ["font_color", "font_hover_color", "font_focus_color", "font_pressed_color"]:
				button.add_theme_color_override(i, Color(0, 1, 0))
		button.pressed.connect(_on_scene_button_pressed.bind(button))
		%ObsScenes.add_child(button)

func generate_input_request(inputs):
	for n in %ObsInputs.get_children():
		n.queue_free()

	var request = []
	for i in inputs:
		request.push_back(["GetInputMute", { "inputName": i.inputName }, i.inputName])

	obs.send_command_batch(request)

func generate_input_button(input):
	var button = Button.new()
	button.visible = false
	button.name = input.inputName.to_camel_case()
	button.text = input.inputName
	button.pressed.connect(_on_input_button_pressed.bind(button))
	%ObsInputs.add_child(button)
	change_input_state(input)

func change_input_name(data):
	var button = %ObsInputs.get_node(data.oldInputName.to_camel_case())
	if button:
		button.name = data.inputName.to_camel_case()
		button.text = data.inputName

func change_input_state(data):
	var button = %ObsInputs.get_node(data.inputName.to_camel_case())
	if button:
		button.visible = true
		if (data.inputMuted):
			for i in ["font_color", "font_hover_color", "font_focus_color", "font_pressed_color"]:
				button.add_theme_color_override(i, Color(1, 0, 0))
		else:
			for i in ["font_color", "font_hover_color", "font_focus_color", "font_pressed_color"]:
				button.add_theme_color_override(i, Color(0, 1, 0))

func _on_input_button_pressed(button):
	obs.send_command("ToggleInputMute", { "inputName": button.text }, button.text)

func insert_data(data: Dictionary, node: Node, template: String) -> void:
	node.clear()
	node.append_text(template.format(data))

# endregion

# region WINDOW FUNCTIONS

func _input(event):
	if event.is_action_pressed("cancel_speech"):
		cancel_button.emit_signal("pressed")

	if event.is_action_pressed("pause_resume"):
		pause_button.button_pressed = not pause_button.button_pressed
		pause_button.emit_signal("toggled", pause_button.button_pressed)

func backend_connected():
	change_status_color(%BackendStatus, true)

func backend_disconnected():
	change_status_color(%BackendStatus, false)

func _on_pause_speech_toggled(button_pressed: bool):
	Globals.is_paused = button_pressed

	if (button_pressed):
		pause_button.text = ">>> RESUME <<<"
		for i in ["font_color", "font_hover_color", "font_focus_color", "font_pressed_color"]:
			pause_button.add_theme_color_override(i, Color(1, 0, 0))
	else:
		Globals.ready_for_speech.emit()
		pause_button.text = "Pause"
		for i in ["font_color", "font_hover_color", "font_focus_color", "font_pressed_color"]:
			pause_button.remove_theme_color_override(i)

func _on_cancel_speech_pressed():
	Globals.cancel_speech.emit()
	current_speech.add_theme_color_override("font_color", Color(1, 0, 0))

func stop_processing():
	stats_timer.stop()
	status_timer.stop()
	obs.break_connection()
	main.client.break_connection("from control panel")
	change_status_color(%ObsClientStatus, false)

func _on_reconnect_button_pressed():
	stop_processing()
	get_tree().reload_current_scene()

func _on_close_requested():
	$CloseConfirm.visible = true

func _on_close_confirm_confirmed():
	stop_processing()
	get_tree().quit()

# endregion
