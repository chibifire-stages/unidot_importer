# SPDX-License-Identifier: MIT
# Unrigged or rigged GLB -> an avatar package of native engine assets.
#   godot --path <project> --script res://addons/unidot_importer/avatar_export/glb_to_avatar.gd -- \
#     --glb=<in.glb> --out=<out package> --name=<Identifier> --skintokens=<skintokens.elf> \
#     [--weights=<GGUF dir>] [--rigged=<rigged.glb> --roles=<roles.json>] [--keep=<dir>]
# The project needs addons/godot_sandbox (a double-precision build) and this add-on at
# addons/unidot_importer. Rigging runs skintokens.elf on a local RenderingDevice, so run it in a
# window; with --rigged and --roles it is skipped and the run can be headless.
# Steps: skintokens rig -> skintokens humanoid roles -> vrm_from_rig (.sgd) -> skintokens T-pose
# -> view_position + native_package (.sgd).
extends SceneTree

const EXPORT := "res://addons/unidot_importer/avatar_export/vrm_export.sgd"
const NATIVE := "res://addons/unidot_importer/avatar_export/native_assets.sgd"
const WAIT_GPU := 1
const READ := 2
const UPLOAD := 3
const COOP := 4
const DONE := 5
const ERROR := 6
const CHUNK := 32 << 20

var _a := {}
var _sb: Node
var _rd: RenderingDevice
var _elf := PackedByteArray()


func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		var kv := arg.trim_prefix("--").split("=", true, 1)
		_a[kv[0]] = kv[1] if kv.size() > 1 else ""
	_run.call_deferred()


func _run() -> void:
	for need in ["glb", "out", "name", "skintokens"]:
		if not _a.has(need):
			_quit("FAIL missing --" + need)
			return
	_elf = FileAccess.get_file_as_bytes(_a.skintokens)
	var keep: String = _a.get("keep", OS.get_user_data_dir())
	DirAccess.make_dir_recursive_absolute(keep)
	var rigged: String = _a.get("rigged", "")
	var roles := ""
	if rigged == "":
		rigged = keep.path_join(_a.name + ".rigged.glb")
		_rd = RenderingServer.create_local_rendering_device()
		if _rd == null:
			_quit("FAIL no local RenderingDevice (run in a window, not --headless)")
			return
		_new_sb()
		_sb.vmcall("skintokens_attach", _rd, 4096)
		_sb.vmcall("skintokens_start", _a.get("weights", ""), _a.glb,
			"beams=1 temperature=0 GGML_RD_MAX_BUFFER_MB=128")
		var glb := await _drive()
		if glb.is_empty():
			return
		_write(rigged, glb)
		print("STEP rig %s %d bytes" % [rigged, glb.size()])
	if _a.has("roles"):
		roles = FileAccess.get_file_as_string(_a.roles)
	else:
		_new_sb()
		_sb.vmcall("skintokens_humanoid_start", rigged)
		roles = (await _drive()).get_string_from_utf8()
		_write(keep.path_join(_a.name + ".roles.json"), roles.to_utf8_buffer())
	print("STEP roles ", roles)

	var ex = load(EXPORT).new()
	if not ex.has_method("glb_json"):
		_quit("FAIL %s did not compile" % EXPORT)
		return
	var src_json: Dictionary = ex.glb_json(FileAccess.get_file_as_bytes(_a.glb))
	var extras: Dictionary = src_json.get("asset", {}).get("extras", {})
	var meta := _meta_from_extras(extras)
	var vrm0: PackedByteArray = ex.vrm_from_rig(FileAccess.get_file_as_bytes(rigged), roles, meta)
	if vrm0.is_empty():
		_quit("FAIL vrm_from_rig: " + str(ex.last_error))
		return
	var vrm0_path := keep.path_join(_a.name + ".rest.vrm")
	_write(vrm0_path, vrm0)
	print("STEP vrm %s %d bytes" % [vrm0_path, vrm0.size()])

	_new_sb()
	_sb.vmcall("skintokens_vrm_start", vrm0_path)
	var vrm := await _drive()
	if vrm.is_empty():
		return
	var vrm_path := keep.path_join(_a.name + ".vrm")
	_write(vrm_path, vrm)
	print("STEP tpose %s %d bytes" % [vrm_path, vrm.size()])

	var view: Vector3 = ex.view_position(vrm)
	print("STEP view ", view)
	var native = load(NATIVE).new()
	if not native.has_method("native_package"):
		_quit("FAIL %s did not compile" % NATIVE)
		return
	var t0 := Time.get_ticks_msec()
	var pkg: PackedByteArray = native.native_package(vrm, _a.name, view, _credits(extras))
	if pkg.is_empty():
		_quit("FAIL native_package: " + str(native.last_error))
		return
	print("STEP native %d ms" % (Time.get_ticks_msec() - t0))
	_write(_a.out, pkg)
	print("STEP package %s %d bytes" % [_a.out, pkg.size()])
	_quit("DONE")


# Sketchfab writes title, author, licence and source into asset.extras; a CC-BY licence permits
# everything VRM asks about, with credit.
func _meta_from_extras(extras: Dictionary) -> Dictionary:
	var licence := str(extras.get("license", ""))
	var cc_by := licence.begins_with("CC-BY-4.0") or licence.begins_with("CC-BY ")
	var url := ""
	var at := licence.find("(")
	if at >= 0:
		url = licence.substr(at + 1).trim_suffix(")")
	var m := {
		"name": str(extras.get("title", _a.name)),
		"authors": [str(extras.get("author", "Unknown"))],
		"copyright": "%s, %s, %s" % [extras.get("author", ""), licence, extras.get("source", "")],
		"licence_url": url,
	}
	if cc_by:
		m["avatar_permission"] = "everyone"
		m["commercial_usage"] = "corporation"
		m["credit_notation"] = "required"
		m["allow_redistribution"] = true
		m["modification"] = "allowModificationRedistribution"
	return m


func _credits(extras: Dictionary) -> String:
	return ("%s\nby %s\n%s\nLicence: %s\n\nRigged by SkinTokens (skintokens.elf) and converted by "
		+ "unidot_importer's avatar export.\n") % [extras.get("title", _a.name),
		extras.get("author", "Unknown"), extras.get("source", ""), extras.get("license", "")]


func _new_sb() -> void:
	if _sb != null:
		_sb.queue_free()
	_sb = ClassDB.instantiate("Sandbox")
	_sb.memory_max = 1024
	_sb.references_max = 4096
	_sb.allocations_max = 10000000
	_sb.execution_timeout = 0
	root.add_child(_sb)
	_sb.load_buffer(_elf)
	if _rd != null:
		_sb.vmcall("skintokens_attach", _rd, 4096)


func _drive() -> PackedByteArray:
	var feed := PackedByteArray()
	while true:
		var r = _sb.vmcall("skintokens_pump", feed)
		feed = PackedByteArray()
		if typeof(r) != TYPE_ARRAY or r.size() < 3:
			_quit("FAIL skintokens_pump returned %s" % str(r))
			return PackedByteArray()
		var hdr: PackedInt64Array = r[0]
		match hdr[0]:
			DONE:
				break
			ERROR:
				_quit("FAIL skintokens: %s" % str(r[1]).replace("\n", " | "))
				return PackedByteArray()
			WAIT_GPU, COOP:
				await process_frame
			READ:
				var f := FileAccess.open(str(r[1]), FileAccess.READ)
				f.seek(hdr[1])
				feed = f.get_buffer(hdr[2] if hdr[2] > 0 else f.get_length() - hdr[1])
			UPLOAD:
				var f := FileAccess.open(str(r[1]), FileAccess.READ)
				var done := 0
				while done < hdr[2]:
					var n: int = mini(hdr[2] - done, CHUNK)
					f.seek(hdr[1] + done)
					var b := f.get_buffer(n)
					if b.size() != n or _rd.buffer_update(r[2], hdr[3] + done, n, b) != OK:
						_quit("FAIL weight upload")
						return PackedByteArray()
					done += n
			_:
				_quit("FAIL unknown request %d" % hdr[0])
				return PackedByteArray()
	var size := int(_sb.vmcall("skintokens_result_size"))
	var out := PackedByteArray()
	while out.size() < size:
		var chunk: PackedByteArray = _sb.vmcall("skintokens_result_chunk", out.size(), size - out.size())
		if chunk.is_empty():
			break
		out.append_array(chunk)
	return out


func _write(path: String, b: PackedByteArray) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_buffer(b)
	f.close()


func _quit(msg: String) -> void:
	print(msg)
	quit(0 if msg == "DONE" else 1)
