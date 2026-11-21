extends RefCounted

const Simulation = preload("res://scripts/simulation/simulation_runner.gd")
const Values = preload("res://scripts/domain/snapshot_values.gd")
const SCHEMA_VERSION := 8
const WALLPAPER_SLOPES_SCHEMA_VERSION := 9
const WALLPAPER_RAMP_SCHEMA_VERSION := 10
const WALLPAPER_BLOCK_CUTS_SCHEMA_VERSION := 21

enum Status { OK, MISSING, INVALID, UNSUPPORTED, IO_ERROR }

var _balance: Dictionary
var _path: String
var _schema_version: int


func _init(balance: Dictionary, path: String = "user://wallpaper/save.json") -> void:
	_balance = balance.duplicate(true)
	_path = path
	_schema_version = WALLPAPER_SLOPES_SCHEMA_VERSION if balance.world.get("quarrySlopesOnly", false) else SCHEMA_VERSION
	if balance.world.get("pyramidRamp", false):
		_schema_version = WALLPAPER_RAMP_SCHEMA_VERSION
	if balance.world.get("quarryBlockCuts", false):
		_schema_version = WALLPAPER_BLOCK_CUTS_SCHEMA_VERSION


func load_game() -> Dictionary:
	var primary := _read(_path)
	if primary.status in [Status.OK, Status.UNSUPPORTED]:
		return primary
	var backup := _read(_path + ".bak")
	if backup.status == Status.OK:
		backup["recovered"] = true
		return backup
	if backup.status == Status.UNSUPPORTED or primary.status == Status.MISSING:
		return backup
	return primary


func save_game(simulation: Simulation, lifecycle: Dictionary = {}, transfer_facing: Dictionary = {}, reset_progress := false) -> Error:
	var primary := _read(_path)
	var backup := _read(_path + ".bak")
	if not reset_progress:
		if Status.UNSUPPORTED in [primary.status, backup.status]:
			return ERR_UNAVAILABLE
		if Status.IO_ERROR in [primary.status, backup.status]:
			return ERR_CANT_OPEN
		if primary.status == Status.INVALID and backup.status != Status.OK:
			return ERR_FILE_CORRUPT
	var result := DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_path.get_base_dir()))
	if result != OK:
		return result
	var temporary := _path + ".tmp"
	var data := {
		"savedAtUtc": int(Time.get_unix_time_from_system()),
		"configVersion": int(_balance.configVersion),
		"simulation": simulation.to_dict(),
		"lifecycle": lifecycle,
	}
	if not transfer_facing.is_empty():
		data["wallpaperTransferFacing"] = transfer_facing
	var payload := JSON.stringify(data, "", true, true)
	result = _write(temporary, JSON.stringify({
		"schemaVersion": _schema_version,
		"payload": payload,
		"checksum": _checksum(_schema_version, payload),
	}))
	if result != OK:
		return result
	if _read(temporary).status != Status.OK:
		return ERR_FILE_CORRUPT
	if reset_progress or primary.status == Status.OK:
		var backup_temporary := _path + ".bak.tmp"
		var backup_text: String = FileAccess.get_file_as_string(temporary) if reset_progress else primary.text
		result = _write(backup_temporary, backup_text)
		if result != OK:
			return result
		if _read(backup_temporary).status != Status.OK:
			return ERR_FILE_CORRUPT
		result = DirAccess.rename_absolute(backup_temporary, _path + ".bak")
		if result != OK:
			return result
	return DirAccess.rename_absolute(temporary, _path)


func _read(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		var status := Status.MISSING if FileAccess.get_open_error() == ERR_FILE_NOT_FOUND else Status.IO_ERROR
		return {"status": status}
	var source := file.get_as_text()
	var parser := JSON.new()
	if parser.parse(source) != OK:
		return {"status": Status.INVALID}
	var envelope: Variant = parser.data
	if not envelope is Dictionary or not Values.integer(envelope.get("schemaVersion"), 9007199254740991):
		return {"status": Status.INVALID}
	var version := int(envelope.schemaVersion)
	var saved_layout := version
	if version > _schema_version:
		return {"status": Status.UNSUPPORTED}
	var payload: Variant = envelope.get("payload")
	if not payload is String or envelope.get("checksum") != _checksum(version, payload):
		return {"status": Status.INVALID}
	if parser.parse(payload) != OK:
		return {"status": Status.INVALID}
	var data: Variant = parser.data
	if not data is Dictionary:
		return {"status": Status.INVALID}
	while version < _schema_version:
		if not _migrate(version, data):
			return {"status": Status.INVALID}
		version += 1
	if not Values.integer(data.get("configVersion"), 9007199254740991):
		return {"status": Status.INVALID}
	if int(data.configVersion) != int(_balance.configVersion):
		return {"status": Status.UNSUPPORTED}
	if not Values.integer(data.get("savedAtUtc"), 9007199254740991) or not data.get("simulation") is Dictionary:
		return {"status": Status.INVALID}
	var lifecycle: Variant = data.get("lifecycle", {})
	if not lifecycle is Dictionary:
		return {"status": Status.INVALID}
	if not lifecycle.is_empty():
		if not lifecycle.get("paused") is bool 				or not Values.integer(lifecycle.get("absenceUtc"), 9007199254740991) 				or not Values.integer(lifecycle.get("targetTicks"), 1 + int(float(_balance.simulation.offlineCapSeconds) / float(_balance.simulation.fixedStepSeconds))) 				or (lifecycle.absenceUtc == 0 and lifecycle.targetTicks != 0):
			return {"status": Status.INVALID}
	if not lifecycle.get("tutorialSkipped", false) is bool:
		return {"status": Status.INVALID}
	var simulation := Simulation.from_dict(_balance, data.simulation)
	if simulation == null:
		return {"status": Status.INVALID}
	var quarry_layout := 7 if _schema_version == SCHEMA_VERSION else WALLPAPER_SLOPES_SCHEMA_VERSION
	if (saved_layout < quarry_layout or (_schema_version == WALLPAPER_BLOCK_CUTS_SCHEMA_VERSION
			and saved_layout < WALLPAPER_BLOCK_CUTS_SCHEMA_VERSION)) and not simulation.migrate_quarry_routes():
		return {"status": Status.INVALID}
	if saved_layout < 8:
		simulation.migrate_workshop_layout()
	var result := {"status": Status.OK, "simulation": simulation, "saved_at_utc": int(data.savedAtUtc),
		"text": source, "lifecycle": lifecycle}
	if data.get("wallpaperTransferFacing") is Dictionary:
		result["transfer_facing"] = data.wallpaperTransferFacing
	return result


# Version 1 used a different name for the snapshot timestamp.
func _migrate(version: int, data: Dictionary) -> bool:
	match version:
		1:
			if not data.has("snapshotUtc"):
				return false
			data["savedAtUtc"] = data.snapshotUtc
			data.erase("snapshotUtc")
			return true
		2, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20:
			# Route migration needs the validated work queues and resource IDs.
			return true
		3, 4, 5, 6, 7:
			# The model accepts snapshots without the newly added stocks and routes.
			return true
	return false


func _checksum(version: int, payload: String) -> String:
	return ("%d\n%s" % [version, payload]).sha256_text()


func _write(path: String, contents: String) -> Error:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	if not file.store_string(contents):
		var error := file.get_error()
		file.close()
		return ERR_CANT_CREATE if error == OK else error
	file.flush()
	var result := file.get_error()
	file.close()
	return result

