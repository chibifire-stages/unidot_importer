# This file is part of Unidot Importer. See LICENSE.txt for full MIT license.
# Copyright (c) 2021-present Lyuma <xn.lyuma@gmail.com> and contributors
# SPDX-License-Identifier: MIT
# Reads an exported .unitypackage avatar back with Unidot's own importer code: package_file.gd and
# tarfile.gd for the package, asset_database.gd for the metas, yaml_parser.gd for every asset, and
# UnidotMesh (object_adapter.gd) to turn the Mesh into a Godot mesh. Then it checks them against
# the VRM that went in.
#   godot --headless --path <project> --script res://addons/unidot_importer/export_avatar_check.gd -- \
#     --package=<p.unitypackage> --vrm=<the T-posed .vrm> --name=<Identifier> [--control]
# --control expects one triangle fewer than the VRM has, so the run must FAIL.
extends SceneTree

const PackageFile := preload("./package_file.gd")
const AssetDatabase := preload("./asset_database.gd")
const Export := preload("./export_vrm.sgd")

var fails := []


func expect(ok: bool, what: String) -> void:
	if not ok:
		fails.append(what)


func _initialize() -> void:
	var a := {}
	for arg in OS.get_cmdline_user_args():
		var kv := arg.trim_prefix("--").split("=", true, 1)
		a[kv[0]] = kv[1] if kv.size() > 1 else ""
	var vrm := FileAccess.get_file_as_bytes(a.vrm)
	var ex = Export.new()
	var gltf: Dictionary = ex.glb_json(vrm)
	var want_vertices := 0
	var want_indices := 0
	for node in gltf["nodes"]:
		if node.has("mesh") and node.has("skin"):
			for prim in gltf["meshes"][int(node["mesh"])]["primitives"]:
				want_vertices += int(gltf["accessors"][int(prim["attributes"]["POSITION"])]["count"])
				want_indices += int(gltf["accessors"][int(prim["indices"])]["count"])
	if a.has("control"):
		want_indices -= 3
	var want_human: int = gltf["extensions"]["VRMC_vrm"]["humanoid"]["humanBones"].size()

	var pkg = PackageFile.new().init_with_filename(a.package)
	if pkg == null:
		print("FAIL Unidot could not open the package")
		quit(1)
		return
	print("paths ", pkg.paths)
	var db = AssetDatabase.new()
	pkg.parse_all_meta(db)
	var kinds := {}
	for path in pkg.paths:
		var asset = pkg.path_to_pkgasset[path]
		var guid: String = pkg.read_guid_from_meta_file(asset.metadata_tar_header.get_stringfile())
		expect(guid == asset.guid, "%s: meta guid %s, folder %s" % [path, guid, asset.guid])
		expect(asset.parsed_meta != null, "Unidot parsed no meta for " + path)
		if path.ends_with(".png") or path.ends_with(".jpg"):
			var head: PackedByteArray = asset.asset_tar_header.get_data().slice(0, 4)
			expect(head == PackedByteArray([0x89, 0x50, 0x4E, 0x47]) or head.slice(0, 3) == PackedByteArray([0xFF, 0xD8, 0xFF]),
				"%s is not a PNG or JPEG file" % path)
			continue
		if path.ends_with(".txt") or asset.parsed_meta == null:
			continue
		var parsed = asset.parsed_meta.parse_asset(asset.asset_tar_header.get_stringfile())
		expect(parsed != null, "Unidot's YAML parser read nothing from " + path)
		if parsed == null:
			continue
		for fid in parsed.assets:
			var obj = parsed.assets[fid]
			kinds[obj.type] = kinds.get(obj.type, 0) + 1
			if obj.type == "Mesh":
				var mesh: Mesh = obj.create_godot_resource()
				expect(mesh != null, "UnidotMesh made no Godot mesh")
				if mesh != null:
					var nv := 0
					var ni := 0
					for s in mesh.get_surface_count():
						var arr := mesh.surface_get_arrays(s)
						nv = maxi(nv, (arr[Mesh.ARRAY_VERTEX] as PackedVector3Array).size())
						ni += (arr[Mesh.ARRAY_INDEX] as PackedInt32Array).size()
					print("mesh: %d surfaces, %d vertices, %d indices, aabb %s" % [mesh.get_surface_count(), nv, ni, mesh.get_aabb()])
					expect(nv >= want_vertices and nv < want_vertices + 4, "mesh has %d vertices, the VRM %d" % [nv, want_vertices])
					expect(ni == want_indices, "mesh has %d indices, the VRM %d" % [ni, want_indices])
			if obj.type == "Avatar":
				var human: Array = obj.keys["m_HumanDescription"]["m_Human"]
				print("avatar: %d human bones" % human.size())
				expect(human.size() == want_human, "avatar maps %d bones, the VRM %d" % [human.size(), want_human])
	print("objects ", kinds)
	for k in ["GameObject", "Transform", "SkinnedMeshRenderer", "Animator", "MonoBehaviour", "Mesh", "Avatar", "Material"]:
		expect(kinds.has(k), "no " + k + " in the package")
	expect(kinds.get("SkinnedMeshRenderer", 0) == 1, "want one SkinnedMeshRenderer")
	if fails.is_empty():
		print("PASS %d assets read back by Unidot" % pkg.paths.size())
		quit(0)
	else:
		for f in fails:
			print("FAIL ", f)
		quit(1)
