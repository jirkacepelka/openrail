extends RefCounted
## Persistent user settings (window mode, volume, language, last join data),
## stored in user://settings.cfg. Everything is static so any script can read
## `Settings.language` without an instance.

const PATH := "user://settings.cfg"

static var window_mode := "windowed" ## "windowed" or "fullscreen"
static var master_volume := 0.8 ## 0.0 to 1.0
static var language := "cs"
static var join_address := "127.0.0.1"
static var join_port := 7878
static var join_name := "Hráč"
static var join_fingerprint := ""
static var _loaded := false


## Reads the file once; later calls do nothing.
static func load_from_disk(path: String = PATH) -> void:
	if _loaded:
		return
	_loaded = true
	var cfg := ConfigFile.new()
	if cfg.load(path) != OK:
		return
	window_mode = str(cfg.get_value("display", "window_mode", window_mode))
	if window_mode != "fullscreen":
		window_mode = "windowed"
	master_volume = clampf(float(cfg.get_value("audio", "master_volume", master_volume)), 0.0, 1.0)
	language = str(cfg.get_value("ui", "language", language))
	join_address = str(cfg.get_value("join", "address", join_address))
	join_port = int(cfg.get_value("join", "port", join_port))
	join_name = str(cfg.get_value("join", "name", join_name))
	join_fingerprint = str(cfg.get_value("join", "fingerprint", join_fingerprint))


static func save_to_disk(path: String = PATH) -> Error:
	var cfg := ConfigFile.new()
	cfg.set_value("display", "window_mode", window_mode)
	cfg.set_value("audio", "master_volume", master_volume)
	cfg.set_value("ui", "language", language)
	cfg.set_value("join", "address", join_address)
	cfg.set_value("join", "port", join_port)
	cfg.set_value("join", "name", join_name)
	cfg.set_value("join", "fingerprint", join_fingerprint)
	return cfg.save(path)


## Pushes the settings to the engine (window mode and master bus volume).
static func apply() -> void:
	if DisplayServer.get_name() != "headless":
		var mode := DisplayServer.WINDOW_MODE_FULLSCREEN if window_mode == "fullscreen" \
				else DisplayServer.WINDOW_MODE_WINDOWED
		DisplayServer.window_set_mode(mode)
	# Placeholder: there is no audio yet, but the master bus follows the slider.
	AudioServer.set_bus_volume_db(0, linear_to_db(maxf(master_volume, 0.0001)))
