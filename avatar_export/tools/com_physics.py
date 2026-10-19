"""Physics solve for the humanoid centre of mass, from bone positions alone (OneJoint.cs.txt).

Each body bone is a rigid segment with a fixed mass (human_trait.gd). Its centre lies on the line
from its joint p_i toward g_i, the centroid of its humanoid children's joints, at an unknown fraction
f_i:  c_i = p_i + f_i (g_i - p_i). Head, hands, feet and toes sit at their joint. The engine holds
the whole-body centre at bodyPosition * humanScale while one muscle moves, so every recorded pose
gives three equations

    sum_i m_i f_i (g_i - p_i) = body - sum_i m_i p_i,

linear in f. The solve prints f per bone beside k/(k+1), the value for "centroid of the joint and
its k children" (1/2 for a chain bone). A missing bone gives its mass to its nearest present parent.
  python3 com_physics.py onejoint.json [more.json ...]
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


def study(path):
    d = json.load(open(path))
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
    print("== %s: %d poses, residual rms %.1e m, max %.1e m" % (
        d["prefab"].split("/")[-1], len(rows), np.sqrt(np.mean(e ** 2)), np.abs(e).max()))
    for k, b in enumerate(free):
        n = len(kids[b])
        print("  %-14s f = %.4f   k/(k+1) = %.4f" % (b, f[k], n / (n + 1)))


for p in sys.argv[1:] or ["onejoint.json"]:
    study(p)
