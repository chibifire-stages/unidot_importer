# Avatar export

Unidot reads an engine asset package into Godot. This folder goes the other way: it turns a GLB model into an avatar package, written directly in the engine's own text asset formats. The target project needs only the social VR platform's avatar SDK.

## What it is for

`glb_to_avatar.gd` takes a GLB model, rigged or not, and writes a package with these assets:

- `<Name>.prefab`: the avatar, with GameObjects, Transforms, one SkinnedMeshRenderer, an Animator and the SDK's avatar descriptor with its eye point already set.
- `<Name>.mesh.asset`: one Mesh. Every skinned primitive is merged into it, with one submesh per material.
- `<Name>.avatar.asset`: the humanoid Avatar, computed by the rules in the next section.
- `Materials/*.mat`: Standard-shader materials made from the glTF PBR factors.
- `CREDITS.txt`: the model's title, author, source and licence.

The steps run as RISC-V guests in Godot Sandbox:

1. `skintokens.elf`, the SkinTokens guest, rigs the model, matches its joints to humanoid roles, and later turns the VRM to a T-pose.
2. `vrm_export.sgd` writes the VRM 1.0 (meta and humanoid bones) and finds the eye point.
3. `native_assets.sgd` writes the engine assets and the package. A package is the gzip of a tar that holds `<guid>/asset`, `<guid>/asset.meta` and `<guid>/pathname` for each asset, which is the layout `tarfile.gd` and `package_file.gd` read.

Godot Sandbox's GDScript compiler compiles both `.sgd` files. The guests read no files: the driver passes them bytes and writes out the bytes they return. Each attribute is moved with bulk engine operators, because a loop over each vertex in the guest runs out of its instruction budget on a 100k-vertex model.

## How the Avatar is computed

The rules were found clean-room: by observing what the engine does, through its public API and the text assets it writes, for avatars it built itself. No engine source code or decompiled code was read.

- **Bone frame:** a bone's frame points its x axis along the bone, toward the next humanoid bone. It keeps the template z axis for that bone, then sets y = z × x. End bones (head, hands, feet, toes) use the template frame unchanged.
- **PostQ and PreQ:** PostQ is the bone's global rotation, inverted, times the frame. PreQ is the parent's global rotation, inverted, times the frame, times a fixed offset per bone that moves the frame to the zero-muscle pose.
- **Lengths:** a bone's length is the distance to its child. The head uses the neck's length, a hand or toe is a quarter of the distance from its parent, and a foot's length is its height above the ground.
- **Constants:** masses come from `human_trait.gd`. Signs and muscle limits are constants of the humanoid.

With these rules, the PreQ, PostQ, lengths, signs and limits for all 22 bones agree with the engine's own Avatar for the same T-posed VRM to within 1.2e-6. The muscles at rest agree to 7e-7.

**Body centre (`m_RootX.t`):** each body bone is a rigid segment with its humanoid mass. Its centre is the centroid of its own joint and its humanoid children's joints. The hips use only their children. The head, hands, feet and toes sit at their joint. The left upper arm's centre is 1/8 of the way to the elbow, where the right one is at 1/2. A missing UpperChest gives its mass to the chest.

The engine keeps the whole-body centre still while one muscle moves, so bending one joint at a time and recording only bone positions gives a linear system in each segment's centre. `tools/OneJoint.cs.txt` records the poses and `tools/com_physics.py` solves them. On two avatars the engine built itself (566 poses), the rule reproduces the engine's centre to 4.9e-7 m. With 200 random poses applied to our Avatar and to the engine's own, every bone lands within 1.4e-6 m.

## Build and run

The project needs `addons/godot_sandbox` (a double-precision build) and this add-on at `addons/unidot_importer`. Rigging needs a local RenderingDevice, so run it in a window:

```sh
godot --path <project> --script res://addons/unidot_importer/avatar_export/glb_to_avatar.gd -- \
  --glb=in.glb --out=<package> --name=Name \
  --skintokens=skintokens.elf --weights=<SkinTokens GGUF dir> --keep=<work dir>
```

`--rigged=<rigged.glb> --roles=<roles.json>` skips the rig, and the run can then be headless.

`check_package.gd` reads the package back with Unidot's own importer code (the package, the metas, the YAML of every asset, and `UnidotMesh` to build a Godot mesh). It then checks the vertex, index and bone counts against the T-posed VRM. With `--control`, it expects one triangle fewer, so the check must fail:

```sh
godot --headless --path <project> --script res://addons/unidot_importer/avatar_export/check_package.gd -- \
  --package=<package> --vrm=<work dir>/Name.vrm --name=Name [--control]
```

## Licence

The files in this folder are MIT. The rest of Unidot keeps its own licence (`LICENSE.txt`). A converted model keeps its author's licence, which the package carries in `CREDITS.txt` and in the VRM meta.
