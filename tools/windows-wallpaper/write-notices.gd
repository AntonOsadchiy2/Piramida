extends SceneTree

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() != 1:
		quit(1)
		return
	var output := FileAccess.open(args[0], FileAccess.WRITE)
	if output == null:
		quit(1)
		return
	output.store_string("Godot Engine %s\n\n" % Engine.get_version_info().string)
	for component in Engine.get_copyright_info():
		output.store_line(component.name)
		for part in component.parts:
			output.store_line("Copyright: " + ", ".join(part.copyright))
			output.store_line("License: " + part.license)
		output.store_line("")
	var licenses := Engine.get_license_info()
	licenses["Godot Engine (MIT)"] = Engine.get_license_text()
	for name in licenses:
		output.store_line("\n" + name + "\n\n" + licenses[name])
	output.close()
	quit()
