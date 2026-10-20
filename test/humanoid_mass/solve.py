# This file is part of Unidot Importer. See LICENSE.txt for full MIT license.
# Copyright (c) 2021-present Lyuma <xn.lyuma@gmail.com> and contributors
# SPDX-License-Identifier: MIT
"""Physics solve for the humanoid centre of mass, from bone positions alone (OneJoint.cs.txt).

Each body bone is a rigid segment with a fixed mass (human_trait.gd). Its centre lies on the line
from its joint p_i toward g_i, the centroid of its humanoid children's joints, at an unknown fraction
f_i:  c_i = p_i + f_i (g_i - p_i). Head, hands, feet and toes sit at their joint. The editor holds
the whole-body centre at bodyPosition * humanScale while one muscle moves, so every recorded pose
gives three equations

    sum_i m_i f_i (g_i - p_i) = body - sum_i m_i p_i,

linear in f. The solve prints f per bone beside k/(k+1), the value for "centroid of the joint and
its k children" (1/2 for a chain bone). A missing bone gives its mass to its nearest present parent.
  python3 solve.py onejoint.json [more.json ...]
  python3 solve.py --self-test   (synthetic data, plus a control that must fail)
"""
import json
import sys
import numpy as np

ORDER = ["Hips", "LeftUpperLeg", "RightUpperLeg", "LeftLowerLeg", "RightLowerLeg", "LeftFoot", "RightFoot",
         "Spine", "Chest", "UpperChest", "Neck", "Head", "LeftShoulder", "RightShoulder", "LeftUpperArm",
         "RightUpperArm", "LeftLowerArm", "RightLowerArm", "LeftHand", "RightHand", "LeftToes", "RightToes"]
MASS = dict(zip(ORDER, [0.14545456, 0.12121213, 0.12121213, 0.048484854, 0.048484854, 0.009696971, 0.009696971,
                        0.030303033, 0.14545456, 0.14545456, 0.012121214, 0.048484854, 0.006060607, 0.006060607,
                        0.024242427, 0.024242427, 0.01818182, 0.01818182, 0.006060607, 0.006060607, 0.0024242427,
                        0.0024242427]))
PARENT = {"LeftUpperLeg": "Hips", "RightUpperLeg": "Hips", "LeftLowerLeg": "LeftUpperLeg",
          "RightLowerLeg": "RightUpperLeg", "LeftFoot": "LeftLowerLeg", "RightFoot": "RightLowerLeg",
          "LeftToes": "LeftFoot", "RightToes": "RightFoot", "Spine": "Hips", "Chest": "Spine",
          "UpperChest": "Chest", "Neck": "UpperChest", "Head": "Neck", "LeftShoulder": "UpperChest",
          "RightShoulder": "UpperChest", "LeftUpperArm": "LeftShoulder", "RightUpperArm": "RightShoulder",
          "LeftLowerArm": "LeftUpperArm", "RightLowerArm": "RightUpperArm", "LeftHand": "LeftLowerArm",
          "RightHand": "RightLowerArm"}
END = {"Head", "LeftHand", "RightHand", "LeftFoot", "RightFoot", "LeftToes", "RightToes"}


def solve(d):
    """Least-squares fractions f per bone and the worst residual (m) for one recording."""
    bones = [b for b in ORDER if b in d["zero"]]
    present = set(bones)

    def up(b):
        p = PARENT.get(b)
        while p is not None and p not in present:
            p = PARENT.get(p)
        return p

    kids = {b: [c for c in bones if up(c) == b] for b in bones}
    mass = {b: MASS[b] for b in bones}
    for b in ORDER:
        if b not in present:
            mass[up(b)] += MASS[b]
    total = sum(mass.values())
    free = [b for b in bones if b not in END and kids[b]]
    body = np.array([0.0, d["scale"], 0.0])
    rows, rhs = [], []
    for s in [d["zero"]] + [mv["bones"] for mv in d["moves"]]:
        P = {b: np.array(s[b]) for b in bones}
        R = np.zeros((3, len(free)))
        for k, b in enumerate(free):
            g = np.mean([P[c] for c in kids[b]], 0)
            R[:, k] = mass[b] / total * (g - P[b])
        rows.append(R)
        rhs.append(body - sum(mass[b] / total * P[b] for b in bones))
    A = np.vstack(rows)
    r = np.concatenate(rhs)
    f, *_ = np.linalg.lstsq(A, r, rcond=None)
    e = A @ f - r
    return {b: float(f[k]) for k, b in enumerate(free)}, kids, float(np.abs(e).max()), len(rows)


def study(path):
    d = json.load(open(path))
    f, kids, worst, poses = solve(d)
    print("== %s: %d poses, worst residual %.1e m" % (d["prefab"].split("/")[-1], poses, worst))
    for b, v in f.items():
        n = len(kids[b])
        print("  %-14s f = %.4f   k/(k+1) = %.4f" % (b, v, n / (n + 1)))


# The rule AssetPackageExport.sgd writes: centroid of the joint and its children, the hips on their
# children only, the left upper arm at 1/8.
RULE = {b: 0.5 for b in ORDER if b not in END}
RULE.update({"Hips": 1.0, "UpperChest": 0.75, "LeftUpperArm": 0.125})


def synthetic(truth, poses=40, seed=3):
    """Random bone positions, shifted so the centre of mass under `truth` sits at the body point."""
    rng = np.random.default_rng(seed)
    kids = {b: [c for c in ORDER if PARENT.get(c) == b] for b in ORDER}
    total = sum(MASS.values())
    snaps = []
    for _ in range(poses):
        P = {b: rng.normal(size=3) * 0.3 + [0, 1, 0] for b in ORDER}
        c = np.zeros(3)
        for b in ORDER:
            centre = P[b]
            if b in truth and kids[b]:
                g = np.mean([P[k] for k in kids[b]], 0)
                centre = P[b] + truth[b] * (g - P[b])
            c += MASS[b] / total * centre
        shift = np.array([0.0, 1.0, 0.0]) - c
        snaps.append({b: list(P[b] + shift) for b in ORDER})
    return {"prefab": "synthetic", "scale": 1.0, "zero": snaps[0], "moves": [{"bones": s} for s in snaps[1:]]}


def matches_rule(d):
    f, _, worst, _ = solve(d)
    gap = max(abs(f[b] - RULE[b]) for b in f)
    return gap < 1e-6 and worst < 1e-9, gap


def self_test():
    ok, gap = matches_rule(synthetic(RULE))
    print("self-test: solver recovers the rule (largest gap %.1e): %s" % (gap, "PASS" if ok else "FAIL"))
    wrong = dict(RULE, LeftUpperArm=0.5)
    control, gap = matches_rule(synthetic(wrong))
    print("control: data made with the left upper arm at 1/2 (largest gap %.1e): %s" % (
        gap, "FAIL as it should" if not control else "PASSED, so the check cannot fail"))
    return 0 if ok and not control else 1


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-test"]:
        sys.exit(self_test())
    for p in sys.argv[1:] or ["onejoint.json"]:
        study(p)
