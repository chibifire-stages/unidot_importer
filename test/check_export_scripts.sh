#!/bin/sh
# This file is part of Unidot Importer. See LICENSE.txt for full MIT license.
# Copyright (c) 2021-present Lyuma <xn.lyuma@gmail.com> and contributors
# SPDX-License-Identifier: MIT
#
# Parses the avatar export scripts with a stock Godot. The .sgd files are GDScript that Godot
# Sandbox compiles, so they are parsed as .gd copies. `--check-only` exits 0 even on a parse error,
# so the log decides. A planted broken script must fail, or the check itself is broken.
#   test/check_export_scripts.sh <godot binary>
set -u
GODOT="$1"
ADDON="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
mkdir -p "$WORK/addons"
printf '[application]\nconfig/name="unidot export check"\n' > "$WORK/project.godot"
cp -R "$ADDON" "$WORK/addons/unidot_importer"
cd "$WORK/addons/unidot_importer"
cp export_vrm.sgd export_vrm_parsed.gd
cp thirdparty/unitypackage/UnitypackageExport.sgd unitypackage_export_parsed.gd
printf 'extends RefCounted\nfunc broken(:\n' > planted_broken.gd

parse() {
	"$GODOT" --headless --path "$WORK" --check-only --script "res://addons/unidot_importer/$1" > "$WORK/log" 2>&1
	! grep -q -E "Parse Error|Failed to load script" "$WORK/log"
}

status=0
for f in export_avatar.gd export_vrm_parsed.gd unitypackage_export_parsed.gd; do
	if parse "$f"; then echo "PASS $f"; else echo "FAIL $f"; cat "$WORK/log"; status=1; fi
done
if parse planted_broken.gd; then
	echo "FAIL the planted broken script parsed, so this check cannot fail"
	status=1
else
	echo "PASS the planted broken script fails as it should"
fi
rm -rf "$WORK"
exit $status
