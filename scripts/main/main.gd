extends Node2D

@export_category("Variables")
@export_range(0.5, 10, 0.01) var time_before_cleanout: float = 3.0
@export_range(0.5, 10, 0.01) var time_before_ready: float = 2.0

@export_category("Model")
@export var model: Node2D
@onready var model_sprite := model.get_node("%Sprite2D")
@onready var user_model := model.get_node("%GDCubismUserModel")
@onready var model_target_point := model.get_node("%TargetPoint")
var pressed: bool

@export_category("Nodes")
@export var client: WebSocketClient
@export var control_panel: Window
@export var prompt: Label
@export var subtitles: Label
@export var mic: AnimatedSprite2D

@export_group("Sound Bus")
@export var cancel_sound: AudioStreamPlayer
@export var speech_player: AudioStreamPlayer
@export var song_player: AudioStreamPlayer

# Tweens
@onready var tweens := {}

# Cleanout stuff
var subtitles_cleanout := false
var subtitles_duration := 0.0

# Song-related
@onready var voice_bus := AudioServer.get_bus_index("Voice")
var current_song: Dictionary
var song_playback: AudioStreamPlayback
var wait_time_triggered := false
var stop_time_triggered := false

# Defaults
@onready var prompt_font_size := prompt.label_settings.font_size
@onready var subtitles_font_size := subtitles.label_settings.font_size

func _ready():
	# Makes bg transparent
	get_tree().get_root().set_transparent_background(true)
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_TRANSPARENT, true, 0)

	# Defaults
	prompt.text = ""
	subtitles.text = ""

	# Signals
	Globals.new_speech.connect(_on_new_speech)
	Globals.cancel_speech.connect(_on_cancel_speech)
	Globals.start_singing.connect(_on_start_singing)
	Globals.stop_singing.connect(_on_stop_singing)

	cancel_sound.finished.connect(func (): Globals.is_speaking = false)

	# Waiting for the backend
	await client.connection_established
	control_panel.backend_connected()
	client.data_received.connect(_on_data_received)
	client.connection_closed.connect(_on_connection_closed)

	# Ready for speech
	Globals.ready_for_speech.connect(_on_ready_for_speech)

func _process(_delta) -> void:
	if Globals.is_singing and current_song:
		if not wait_time_triggered or not stop_time_triggered:
			var pos = song_player.get_playback_position() + AudioServer.get_time_since_last_mix()
			pos -= AudioServer.get_output_latency()
			if pos >= current_song.wait_time and not wait_time_triggered:
				Globals.start_dancing_motion.emit(current_song.bpm)
				wait_time_triggered = true
			if current_song.stop_time != 0.0:
				if pos >= current_song.stop_time and not stop_time_triggered:
					Globals.end_dancing_motion.emit()
					stop_time_triggered = true

func _input(event):
	if event as InputEventMouseButton:
		pressed = event.is_pressed()

	if event as InputEventMouseMotion:
		if pressed == true:
			var local_pos: Vector2 = model_sprite.to_local(event.position)
			print(local_pos)

			var render_size: Vector2 = Vector2(
				float(user_model.size.x) * model_sprite.scale.x,
				float(user_model.size.y) * model_sprite.scale.y * -1.0
			) * 0.5
			local_pos /= render_size
			model_target_point.set_target(local_pos)
		else:
			model_target_point.set_target(Vector2.ZERO)

func _on_data_received(data: Variant):
	if Globals.is_paused:
		return

	if typeof(data) == TYPE_PACKED_BYTE_ARRAY:
		if Globals.is_speaking:
			printerr("Audio while blabbering")
			return

		# Testing for MP3
		var header = data.slice(0, 2)
		if not (header == PackedByteArray([255, 251]) or header == PackedByteArray([73, 68])):
			printerr("%s is not an MP3 file! Skipping..." % [header])
			return

		# Preparing for speaking
		prepare_speech(data)
	else:
		var message = JSON.parse_string(data.message)

		match message.type:
			"PlayAnimation":
				Globals.play_animation.emit(message.animationName)

			"SetExpression":
				Globals.set_expression.emit(message.expressionName)

			"SetToggle":
				Globals.set_toggle.emit(message.toggleName, message.enabled)

			"NewSpeech":
				if not Globals.is_speaking:
					Globals.new_speech.emit(message.prompt, message.text)
				else:
					print_debug("NewSpeech while blabbering")

			_:
				print("Unhandled data type: ", message)

func _on_speech_player_finished():
	Globals.is_speaking = false
	speech_player.stream = null

	if (Globals.is_singing):
		Globals.stop_singing.emit()

	trigger_cleanout()
	Globals.speech_done.emit()

func prepare_speech(message: PackedByteArray):
	var stream = AudioStreamMP3.new()
	stream.data = message
	subtitles_duration = stream.get_length()
	speech_player.stream = stream

func _play_audio() -> void:
	if speech_player.stream:
		Globals.is_speaking = true
		speech_player.play()
	else:
		printerr("NO AUDIO FOR THE MESSAGE!")

func _on_ready_for_speech():
	if not Globals.is_paused:
		client.send_message({"type": "ReadyForSpeech"})

func _on_new_speech(p_prompt, p_text) -> void:
	_print_prompt(p_prompt)
	_print_subtitles(p_text.response)

	_play_audio()

func _print_prompt(text):
	if text:
		prompt.text = "%s" % text
	else:
		prompt.text = ""

	while prompt.get_line_count() > prompt.get_visible_line_count():
		prompt.label_settings.font_size -= 3

	_tween_text(prompt, "prompt", 0.0, 1.0, 1.0)

func _print_subtitles(text):
	if text:
		subtitles.text = "%s" % text
	else:
		subtitles.text = "tsh mebla"

	while subtitles.get_line_count() > subtitles.get_visible_line_count():
		subtitles.label_settings.font_size -= 3

	_tween_text(subtitles, "subtitles", 0.0, 1.0, subtitles_duration)

func _on_cancel_speech():
	Globals.set_toggle.emit("void", true)

	speech_player.stop()
	speech_player.stream = null
	cancel_sound.play()

	prompt.text = ""
	prompt.label_settings.font_size = prompt_font_size

	subtitles.text = "[TOASTED]"
	subtitles.label_settings.font_size = subtitles_font_size
	_tween_text(subtitles, "subtitles", 0.0, 1.0, cancel_sound.stream.get_length())

	await trigger_cleanout()
	Globals.set_toggle.emit("void", false)

func trigger_cleanout():
	await get_tree().create_timer(time_before_cleanout).timeout
	_tween_text(prompt, "prompt", 1.0, 0.0, 1.0)
	_tween_text(subtitles, "subtitles", 1.0, 0.0, 1.0)

	await get_ready_for_next_speech()
	subtitles.label_settings.font_size = subtitles_font_size

func get_ready_for_next_speech():
	if not Globals.is_paused:
		await get_tree().create_timer(time_before_ready).timeout
		Globals.ready_for_speech.emit()

func _on_connection_closed():
	control_panel.backend_disconnected()

func _tween_text(label: Label, tween_name: String, start_val: float, final_val: float, duration: float) -> void:
	if tweens.has(tween_name):
		tweens[tween_name].kill()

	label.visible_ratio = start_val

	tweens[tween_name] = create_tween()
	tweens[tween_name].tween_property(label, "visible_ratio", final_val, duration - duration * 0.2)

func _on_start_singing(song: Dictionary):
	current_song = song

	Globals.is_paused = true
	Globals.is_singing = true

	mic.animation = "in"
	mic.play()

	subtitles_duration = 3.0
	_print_prompt("")
	_print_subtitles("{artist}\n\"{name}\"".format(song))

	AudioServer.set_bus_mute(voice_bus, song.mute_voice)
	AudioServer.set_bus_effect_enabled(voice_bus, 1, song.reverb)

	var song_track := _load_mp3(song, "song")
	song_player.stream = song_track

	var voice_track := _load_mp3(song, "voice")
	speech_player.stream = voice_track

	wait_time_triggered = false
	stop_time_triggered = false

	song_player.play()
	speech_player.play()

func _on_stop_singing():
	Globals.is_singing = false

	song_player.stop()
	speech_player.stop()

	mic.animation = "out"
	mic.play()

	current_song = {}

	AudioServer.set_bus_mute(voice_bus, false)
	AudioServer.set_bus_effect_enabled(voice_bus, 1, false)

	Globals.end_dancing_motion.emit()
	Globals.end_singing_mouth_movement.emit()

func _load_mp3(song: Dictionary, type: String) -> AudioStreamMP3:
	var path: String = song.path % type

	if not FileAccess.file_exists(path):
		printerr("No audio file %s" % path)

	var file = FileAccess.open(path, FileAccess.READ)
	var stream = AudioStreamMP3.new()
	stream.data = file.get_buffer(file.get_length())
	stream.bpm = song.bpm
	return stream
