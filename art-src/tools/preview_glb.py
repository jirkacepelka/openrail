"""Quick preview render of exported .glb files (no rebuild).

blender -b --factory-startup --python tools/preview_glb.py -- export/vehicles/locomotive_steam.glb ...
Writes previews/quick_<name>.png
"""
import math
import os
import sys

import bpy
from mathutils import Vector

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
files = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []

bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene
try:
    scene.render.engine = "BLENDER_EEVEE"
except TypeError:
    scene.render.engine = "BLENDER_EEVEE_NEXT"
scene.view_settings.view_transform = "Standard"
scene.render.resolution_x, scene.render.resolution_y = 1600, 900
world = bpy.data.worlds.new("Sky")
world.use_nodes = True
world.node_tree.nodes["Background"].inputs["Color"].default_value = (0.4, 0.58, 0.83, 1)
scene.world = world
sun = bpy.data.objects.new("Sun", bpy.data.lights.new("Sun", "SUN"))
sun.data.energy = 3.6
sun.data.color = (1.0, 0.87, 0.7)
sun.rotation_euler = (math.radians(55), math.radians(8), math.radians(-35))
scene.collection.objects.link(sun)
cam = bpy.data.objects.new("Cam", bpy.data.cameras.new("Cam"))
scene.collection.objects.link(cam)
scene.camera = cam

for f in files:
    for o in list(scene.objects):
        if o.type not in ("LIGHT", "CAMERA"):
            bpy.data.objects.remove(o)
    bpy.ops.import_scene.gltf(filepath=os.path.join(ROOT, f))
    pts = [o.matrix_world @ Vector(c) for o in scene.objects if o.type == "MESH" for c in o.bound_box]
    lo = Vector((min(p.x for p in pts), min(p.y for p in pts), min(p.z for p in pts)))
    hi = Vector((max(p.x for p in pts), max(p.y for p in pts), max(p.z for p in pts)))
    c = (lo + hi) / 2
    r = (hi - lo).length
    yaw = math.radians(-38)
    cam.location = c + Vector((math.cos(yaw) * r * 1.05, math.sin(yaw) * r * 1.05, r * 0.35))
    cam.rotation_euler = (c - cam.location).to_track_quat("-Z", "Y").to_euler()
    name = os.path.splitext(os.path.basename(f))[0]
    scene.render.filepath = os.path.join(ROOT, "previews", f"quick_{name}.png")
    bpy.ops.render.render(write_still=True)
    print("rendered", name)
