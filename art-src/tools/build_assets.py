"""Build the OpenRail sample assets (v2) and export them for Godot.

Run with:  blender -b --factory-startup --python tools/build_assets.py [-- --no-render] [-- --fast]
Needs the textures from tools/make_textures.py.

Pipeline:
  1. model every part and box-map the tiling hand-painted textures onto it
  2. per exported mesh, unwrap a second UV set and bake a *painted* albedo in Cycles:
     texture x painted light (top-lit, cool shadows, ambient occlusion) + warm edge highlights
  3. run a Kuwahara filter over the bake so it reads like brushwork, save it to source/baked/
  4. swap in one simple material per mesh (M_<Asset>_<Mesh>) + untouched emissive materials
  5. export .glb and render previews

Conventions (see README):
  * metres, Blender Z-up, vehicles face +Y in Blender = -Z (forward) in Godot
  * vehicle origin = top of rail, centred; wheelsets are separate nodes with origin on the axle
"""
import math
import os
import random
import sys

import bmesh
import bpy
import numpy as np
from mathutils import Matrix, Vector

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TEX = os.path.join(ROOT, "source", "textures")
BAKED = os.path.join(ROOT, "source", "baked")
# inside the game repo (art-src/) export straight into the Godot client, otherwise next to the sources
_CLIENT = os.path.join(os.path.dirname(ROOT), "client", "assets")
EXPORT = os.environ.get("OPENRAIL_EXPORT") or (_CLIENT if os.path.isdir(os.path.dirname(_CLIENT)) else
                                               os.path.join(ROOT, "export"))
PREVIEW = os.path.join(ROOT, "previews")
BLEND = os.path.join(ROOT, "source", "blend")
for d in (EXPORT, PREVIEW, BLEND, BAKED):
    os.makedirs(d, exist_ok=True)
RENDER = "--no-render" not in sys.argv
FAST = "--fast" in sys.argv  # small bakes for quick iteration

bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene
MATS = {}


def srgb(h):
    h = h.lstrip("#")
    c = [int(h[i:i + 2], 16) / 255.0 for i in (0, 2, 4)]
    return tuple(x / 12.92 if x <= 0.04045 else ((x + 0.055) / 1.055) ** 2.4 for x in c)


def mat(name, tex=None, color=None, emit=None, tile=2.0, strength=5.0):
    """Source material: one painted texture (box-mapped, `tile` metres per repeat) or a flat colour."""
    if name in MATS:
        return MATS[name]
    m = bpy.data.materials.new("M_" + name)
    m.use_nodes = True
    nt = m.node_tree
    bsdf = nt.nodes["Principled BSDF"]
    bsdf.inputs["Roughness"].default_value = 0.7
    if tex:
        node = nt.nodes.new("ShaderNodeTexImage")
        node.image = bpy.data.images.load(os.path.join(TEX, tex + ".png"), check_existing=True)
        uv = nt.nodes.new("ShaderNodeUVMap")
        uv.uv_map = "UVMap"
        nt.links.new(uv.outputs["UV"], node.inputs["Vector"])
        nt.links.new(node.outputs["Color"], bsdf.inputs["Base Color"])
    if color:
        bsdf.inputs["Base Color"].default_value = (*srgb(color), 1)
    if emit:
        bsdf.inputs["Base Color"].default_value = (*srgb(emit), 1)
        bsdf.inputs["Emission Color"].default_value = (*srgb(emit), 1)
        bsdf.inputs["Emission Strength"].default_value = strength
    m["tile"] = tile
    m["emissive"] = bool(emit)
    MATS[name] = m
    return m


def collection(name):
    c = bpy.data.collections.new(name)
    scene.collection.children.link(c)
    return c


# ============================================================ geometry kit

def finish(name, bm, material, col, loc=(0, 0, 0), smooth=True, uv="box", sharp=40):
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    ob = bpy.data.objects.new(name, me)
    col.objects.link(ob)
    me.materials.append(material)
    ob.location = loc
    ob["uv_mode"] = uv
    if smooth:
        for p in me.polygons:
            p.use_smooth = True
        me.set_sharp_from_angle(angle=math.radians(sharp))
    return ob


def _orient(bm, axis):
    if axis == "X":
        bmesh.ops.rotate(bm, verts=bm.verts, cent=(0, 0, 0), matrix=Matrix.Rotation(math.pi / 2, 3, "Y"))
    elif axis == "Y":
        bmesh.ops.rotate(bm, verts=bm.verts, cent=(0, 0, 0), matrix=Matrix.Rotation(-math.pi / 2, 3, "X"))


def box(name, size, loc, material, col, bevel=0.02, segs=1, rot=None):
    bm = bmesh.new()
    bmesh.ops.create_cube(bm, size=1.0)
    bmesh.ops.scale(bm, vec=size, verts=bm.verts)
    if bevel:
        bmesh.ops.bevel(bm, geom=bm.edges[:], offset=min(bevel, min(size) * 0.45), segments=segs,
                        affect="EDGES", profile=0.5, clamp_overlap=True)
    if rot:
        bmesh.ops.rotate(bm, verts=bm.verts, cent=(0, 0, 0), matrix=rot)
    return finish(name, bm, material, col, loc)


def lathe(name, prof, loc, material, col, seg=24, axis="Z", rot=None, sharp=40):
    """Surface of revolution. prof = [(radius, z), ...] ordered counter-clockwise in the (r, z) plane
    (bottom-to-top on the outside) so normals point outwards. r = 0 closes with a fan."""
    bm = bmesh.new()
    rings = []
    for r, z in prof:
        if r <= 1e-6:
            rings.append([bm.verts.new((0, 0, z))])
        else:
            rings.append([bm.verts.new((r * math.cos(2 * math.pi * i / seg), r * math.sin(2 * math.pi * i / seg), z))
                          for i in range(seg)])
    for a, b in zip(rings, rings[1:]):
        for i in range(seg):
            j = (i + 1) % seg
            if len(a) == 1 and len(b) == 1:
                continue
            if len(a) == 1:
                vs = (a[0], b[j], b[i])
            elif len(b) == 1:
                vs = (a[i], a[j], b[0])
            else:
                vs = (a[i], a[j], b[j], b[i])
            if len(set(vs)) == len(vs):
                try:
                    bm.faces.new(vs)
                except ValueError:
                    pass
    bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=1e-5)
    _orient(bm, axis)
    if rot:
        bmesh.ops.rotate(bm, verts=bm.verts, cent=(0, 0, 0), matrix=rot)
    return finish(name, bm, material, col, loc, sharp=sharp)


def cyl(name, r, depth, loc, material, col, axis="Z", r2=None, seg=24, bevel=0.0):
    r2 = r if r2 is None else r2
    h = depth / 2
    if bevel:
        prof = [(0, -h), (r - bevel, -h), (r, -h + bevel), (r2, h - bevel), (r2 - bevel, h), (0, h)]
    else:
        prof = [(0, -h), (r, -h), (r2, h), (0, h)]
    return lathe(name, prof, loc, material, col, seg=seg, axis=axis)


def ring(name, r_out, r_in, width, loc, material, col, axis="Z", seg=32):
    h = width / 2
    prof = [(r_in, -h), (r_out, -h), (r_out, h), (r_in, h), (r_in, -h)]
    return lathe(name, prof, loc, material, col, seg=seg, axis=axis)


def sphere(name, r, loc, material, col, scale=(1, 1, 1), sub=2, seed=0, wobble=0.0):
    bm = bmesh.new()
    bmesh.ops.create_icosphere(bm, subdivisions=sub, radius=r)
    if wobble:
        rnd = random.Random(seed)
        for v in bm.verts:
            v.co *= 1 + rnd.uniform(-wobble, wobble)
    bmesh.ops.scale(bm, vec=scale, verts=bm.verts)
    return finish(name, bm, material, col, loc)


def poly(name, verts, faces, material, col, loc=(0, 0, 0), uv="box", smooth=False):
    bm = bmesh.new()
    vs = [bm.verts.new(v) for v in verts]
    for f in faces:
        bm.faces.new([vs[i] for i in f])
    return finish(name, bm, material, col, loc, smooth=smooth, uv=uv)


def flat(name, pts2d, loc, facing, material, col, uv="planar"):
    """Flat n-gon from 2D points (s = horizontal, t = up), counter-clockwise seen from the front."""
    if facing in ("+X", "-X"):
        vs = [(0, s, t) for s, t in pts2d]  # CCW in (y, z) faces +X
        fwd = facing == "+X"
    else:
        vs = [(s, 0, t) for s, t in pts2d]  # CCW in (x, z) faces -Y
        fwd = facing == "-Y"
    idx = list(range(len(vs)))
    ob = poly(name, vs, [idx if fwd else idx[::-1]], material, col, loc, uv=uv)
    ob["facing"] = facing
    return ob


def rect_pts(w, h):
    return [(-w / 2, -h / 2), (w / 2, -h / 2), (w / 2, h / 2), (-w / 2, h / 2)]


def arch_pts(w, h, n=12):
    hw = w / 2
    spring = h / 2 - hw
    pts = [(-hw, -h / 2), (hw, -h / 2)]
    for i in range(n + 1):
        a = math.pi * i / n
        pts.append((hw * math.cos(a), spring + hw * math.sin(a)))
    return pts


def circle_pts(r, n=24):
    return [(r * math.cos(2 * math.pi * i / n), r * math.sin(2 * math.pi * i / n)) for i in range(n)]


def sheet(name, prof, length, thickness, loc, material, col, axis="Y"):
    """Extrude a 2D polyline profile [(x, z)...] along Y into a sheet with thickness (roofs)."""
    bm = bmesh.new()
    n = len(prof)
    top, bot = [], []
    for i, (x, z) in enumerate(prof):
        a = prof[max(i - 1, 0)]
        b = prof[min(i + 1, n - 1)]
        tx, tz = b[0] - a[0], b[1] - a[1]
        L = math.hypot(tx, tz) or 1
        nx, nz = -tz / L, tx / L  # left normal (up for left-to-right profiles)
        top.append((x, z))
        bot.append((x - nx * thickness, z - nz * thickness))
    hl = length / 2
    loop = top + bot[::-1]
    front = [bm.verts.new((x, -hl, z)) for x, z in loop]
    back = [bm.verts.new((x, hl, z)) for x, z in loop]
    m = len(loop)
    for i in range(m):
        j = (i + 1) % m
        bm.faces.new((front[i], front[j], back[j], back[i]))
    bm.faces.new(front[::-1])
    bm.faces.new(back)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    return finish(name, bm, material, col, loc, sharp=35)


def tube(name, pts, radius, material, col, loc=(0, 0, 0), radii=None, cyclic=False, res=8, bevel_res=3):
    cu = bpy.data.curves.new(name, "CURVE")
    cu.dimensions = "3D"
    cu.bevel_depth = radius
    cu.bevel_resolution = bevel_res
    cu.use_fill_caps = True
    cu.resolution_u = res
    sp = cu.splines.new("BEZIER")
    sp.bezier_points.add(len(pts) - 1)
    for i, (bp, p) in enumerate(zip(sp.bezier_points, pts)):
        bp.co = p
        bp.handle_left_type = bp.handle_right_type = "AUTO"
        if radii:
            bp.radius = radii[i]
    sp.use_cyclic_u = cyclic
    tmp = bpy.data.objects.new(name + "_tmp", cu)
    col.objects.link(tmp)
    bpy.context.view_layer.update()
    me = bpy.data.meshes.new_from_object(tmp.evaluated_get(bpy.context.evaluated_depsgraph_get()))
    bpy.data.objects.remove(tmp)
    bpy.data.curves.remove(cu)
    ob = bpy.data.objects.new(name, me)
    col.objects.link(ob)
    me.materials.clear()
    me.materials.append(material)
    ob.location = loc
    for p in me.polygons:
        p.use_smooth = True
    return ob


def scroll(cx, cz, r0, r1, turns, n=14, y=0.0, start=0.0, flip=1):
    """Spiral points in the XZ plane (art-nouveau iron scroll)."""
    pts = []
    for i in range(n):
        t = i / (n - 1)
        a = start + flip * t * turns * 2 * math.pi
        r = r0 + (r1 - r0) * t
        pts.append((cx + r * math.cos(a), y, cz + r * math.sin(a)))
    return pts


def text_mesh(name, body, size, loc, material, col, rot):
    cu = bpy.data.curves.new(name, "FONT")
    cu.body = body
    cu.size = size
    cu.extrude = 0.012
    cu.bevel_depth = 0.004
    cu.align_x = "CENTER"
    cu.align_y = "CENTER"
    tmp = bpy.data.objects.new(name + "_tmp", cu)
    col.objects.link(tmp)
    bpy.context.view_layer.update()
    me = bpy.data.meshes.new_from_object(tmp.evaluated_get(bpy.context.evaluated_depsgraph_get()))
    bpy.data.objects.remove(tmp)
    me.transform(rot)
    ob = bpy.data.objects.new(name, me)
    ob.location = loc
    col.objects.link(ob)
    me.materials.append(material)
    return ob


# ============================================================== UV helpers

def box_uv(ob, tile):
    me = ob.data
    uvl = me.uv_layers.new(name="UVMap")
    mw = ob.matrix_world
    rot = mw.to_3x3()
    for p in me.polygons:
        n = rot @ p.normal
        ax = max(range(3), key=lambda i: abs(n[i]))
        for li in p.loop_indices:
            co = mw @ me.vertices[me.loops[li].vertex_index].co
            if ax == 2:
                u, v = co.x, co.y
            elif ax == 0:
                u, v = (-co.y if n.x < 0 else co.y), co.z
            else:
                u, v = (co.x if n.y < 0 else -co.x), co.z
            uvl.data[li].uv = (u / tile, v / tile)


def planar_uv(ob):
    me = ob.data
    uvl = me.uv_layers.new(name="UVMap")
    facing = ob.get("facing", "-X")
    cos = [v.co for v in me.vertices]
    if facing in ("-X", "+X"):
        get = (lambda c: (-c.y if facing == "-X" else c.y, c.z))
    else:
        get = (lambda c: (c.x if facing == "-Y" else -c.x, c.z))
    pts = [get(c) for c in cos]
    u0, u1 = min(p[0] for p in pts), max(p[0] for p in pts)
    v0, v1 = min(p[1] for p in pts), max(p[1] for p in pts)
    for li, loop in enumerate(me.loops):
        u, v = get(cos[loop.vertex_index])
        uvl.data[li].uv = ((u - u0) / (u1 - u0 or 1), (v - v0) / (v1 - v0 or 1))


def apply_uvs(col):
    bpy.context.view_layer.update()
    for ob in col.all_objects:
        if ob.type != "MESH" or ob.data.uv_layers:
            continue
        if ob.get("uv_mode") == "planar":
            planar_uv(ob)
        else:
            box_uv(ob, ob.data.materials[0].get("tile", 2.0))


def select_only(obs, active=None):
    for o in bpy.context.view_layer.objects:
        o.select_set(False)
    for o in obs:
        o.select_set(True)
    bpy.context.view_layer.objects.active = active or obs[0]


def join(objs, name, origin=(0, 0, 0)):
    apply_uvs(objs[0].users_collection[0])
    select_only(objs)
    bpy.ops.object.join()
    target = bpy.context.view_layer.objects.active
    target.name = name
    target.data.name = name
    cur = scene.cursor
    cur.location = origin
    bpy.ops.object.origin_set(type="ORIGIN_CURSOR")
    cur.location = (0, 0, 0)
    target.select_set(False)
    return target


def root(name, col, children, bake_h=(0.0, 4.5), res=None):
    e = bpy.data.objects.new(name, None)
    e.empty_display_type = "ARROWS"
    col.objects.link(e)
    for c in children:
        mw = c.matrix_world.copy()
        c.parent = e
        c.matrix_world = mw
        c["bake_h0"], c["bake_h1"] = bake_h
        if res and c.name in res:
            c["bake_res"] = res[c.name]
    return e


def spherical_normals(ob, mat_index_set, centre, squash=(1, 1, 1)):
    """Point shading normals of foliage outwards from the crown centre: soft, painterly volumes."""
    me = ob.data
    c = Vector(centre)
    normals = []
    for v in me.vertices:
        normals.append(v.normal.copy())
    crown = set()
    for p in me.polygons:
        if p.material_index in mat_index_set:
            crown.update(p.vertices)
    for i in crown:
        d = me.vertices[i].co - c
        d = Vector((d.x / squash[0], d.y / squash[1], d.z / squash[2]))
        normals[i] = (d.normalized() * 0.8 + me.vertices[i].normal * 0.2).normalized()
    me.normals_split_custom_set_from_vertices(normals)


# ============================================================ materials

TEAL = mat("loco_teal", "loco_teal", tile=2.0)
DARK = mat("metal_dark", "metal_dark", tile=2.0)
BRASS = mat("brass", "brass", tile=1.0)
RED = mat("red_paint", "red_paint", tile=1.0)
WOODW = mat("wood_wagon", "wood_wagon", tile=2.0)
WOODB = mat("wood_brown", "wood_brown", tile=2.0)
SLATE = mat("roof_slate", "roof_slate", tile=2.5)
VERD = mat("roof_verdigris", "roof_verdigris", tile=2.0)
BRICK = mat("brick", "brick", tile=2.0)
CREAM = mat("stone_cream", "stone_cream", tile=3.0)
PLASTER = mat("plaster", "plaster", tile=3.0)
PAVING = mat("stone_paving", "stone_paving", tile=2.0)
STONE = mat("stone", "stone", tile=2.0)
BARK = mat("bark", "bark", tile=1.5)
LEAVES = mat("leaves", "leaves", tile=4.0)
CONIFER = mat("leaves_conifer", "leaves_conifer", tile=2.0)
COAL = mat("coal", "coal", tile=1.0)
WINDOW = mat("window", "window")
DOOR = mat("door", "door")
CLOCK = mat("clock_face", "clock_face")
GRASS = mat("terrain_grass", "terrain_grass")
PINK = mat("flower_pink", color="#e87aa0", tile=1.0)
YELLOW = mat("flower_yellow", color="#f2c84b", tile=1.0)
LAMP = mat("lamp_glow", emit="#ffbf6b", strength=6.0)
HEX = mat("hextech_glow", emit="#5fe0ff", strength=8.0)


# ============================================================ locomotive

def wheelset(name, y, r, col, spokes=14, centre=RED, crank=True):
    parts = [cyl(f"{name}_axle", 0.08, 1.46, (0, y, r), DARK, col, axis="X", seg=12)]
    w = 0.14
    ri = r * 0.84
    for s in (-1, 1):
        x = s * 0.72
        # tyre with flange on the inside (towards the track centre)
        fz = -s * (w / 2 + 0.03)
        prof = [(ri, -w / 2), (r, -w / 2), (r, w / 2), (ri, w / 2), (ri, -w / 2)]
        parts.append(lathe(f"{name}_tyre{s}", prof, (x, y, r), DARK, col, seg=32, axis="X"))
        flange = [(ri, -0.015), (r + 0.035, -0.015), (r + 0.035, 0.015), (ri, 0.015), (ri, -0.015)]
        parts.append(lathe(f"{name}_flange{s}", flange, (x + fz, y, r), DARK, col, seg=32, axis="X"))
        # rim, hub, spokes
        parts.append(ring(f"{name}_rim{s}", ri, ri - 0.06, 0.1, (x, y, r), centre, col, axis="X", seg=32))
        hub = [(0, -0.09), (r * 0.24, -0.09), (r * 0.24, 0.06), (r * 0.15, 0.13), (0, 0.13)]
        parts.append(lathe(f"{name}_hub{s}", hub if s > 0 else [(a, -b) for a, b in hub][::-1], (x, y, r), centre,
                           col, seg=20, axis="X"))
        parts.append(cyl(f"{name}_hubcap{s}", r * 0.1, 0.05, (x + s * 0.14, y, r), BRASS, col, axis="X", seg=12))
        L = ri - r * 0.2
        for k in range(spokes):
            a = 2 * math.pi * k / spokes
            rot = Matrix.Rotation(a, 3, "X")
            c = rot @ Vector((0, 0, r * 0.2 + L / 2))
            parts.append(box(f"{name}_spoke{s}_{k}", (0.07, 0.05, L), (x + c.x, y + c.y, r + c.z), centre, col,
                             bevel=0.012, rot=rot))
        if crank:
            # crescent counterweight opposite the crank pin
            for k in range(5):
                a = math.pi + (k - 2) * 0.22
                rot = Matrix.Rotation(a, 3, "X")
                c = rot @ Vector((0, 0, r * 0.62))
                parts.append(box(f"{name}_cw{s}_{k}", (0.1, r * 0.28, r * 0.3), (x + s * 0.01 + c.x, y + c.y, r + c.z),
                                 centre, col, bevel=0.02, rot=rot))
            parts.append(cyl(f"{name}_crankpin{s}", 0.06, 0.2, (x + s * 0.12, y, r + r * 0.5), BRASS, col, axis="X",
                             seg=12, bevel=0.01))
    return parts


def buffer(name, x, y, z, sgn, col, head=BRASS):
    prof = [(0, 0), (0.13, 0), (0.13, 0.08), (0.08, 0.1), (0.08, 0.34), (0.2, 0.36), (0.21, 0.4), (0.16, 0.43),
            (0, 0.44)]
    rot = Matrix.Rotation(-math.pi / 2 if sgn > 0 else math.pi / 2, 3, "X")
    return lathe(name, prof, (x, y, z), head, col, seg=20, rot=rot)


def build_locomotive():
    col = collection("Locomotive_Steam")
    b = []
    R = 0.72
    drivers = (-2.05, -0.5, 1.05)
    b.append(box("frame", (1.2, 8.8, 0.55), (0, 0, 0.95), DARK, col, bevel=0.03))
    b.append(box("footplate", (2.64, 9.2, 0.1), (0, 0.05, 1.3), DARK, col, bevel=0.04, segs=2))
    for s in (-1, 1):
        b.append(box(f"valance{s}", (0.05, 9.2, 0.22), (s * 1.3, 0.05, 1.17), TEAL, col, bevel=0.02))
        b.append(box(f"valance_line{s}", (0.02, 9.0, 0.03), (s * 1.33, 0.05, 1.2), BRASS, col, bevel=0.008))
    for yb, sgn in ((4.62, 1), (-4.57, -1)):
        b.append(box(f"bufferbeam{sgn}", (2.64, 0.2, 0.5), (0, yb, 1.05), RED, col, bevel=0.04, segs=2))
        b.append(box(f"bufferbeam_line{sgn}", (2.5, 0.02, 0.36), (0, yb + sgn * 0.1, 1.05), BRASS, col, bevel=0.005))
        for x in (-0.85, 0.85):
            b.append(buffer(f"buffer{sgn}{x}", x, yb + sgn * 0.08, 1.05, sgn, col))
        b.append(box(f"hook{sgn}", (0.1, 0.35, 0.14), (0, yb + sgn * 0.25, 1.0), DARK, col, bevel=0.02))
        b.append(cyl(f"marker_lamp{sgn}", 0.09, 0.14, (0.95, yb + sgn * 0.12, 1.42), BRASS, col, seg=12, bevel=0.02))
        b.append(cyl(f"marker_lens{sgn}", 0.06, 0.02, (0.95, yb + sgn * 0.2, 1.42), LAMP, col,
                     axis="Y", seg=12))
    # boiler with brass bands
    b.append(cyl("boiler", 0.82, 4.95, (0, 1.12, 2.22), TEAL, col, axis="Y", seg=48))
    for yb in (-1.1, 0.35, 1.8, 3.25):
        b.append(ring(f"band{yb}", 0.845, 0.8, 0.07, (0, yb, 2.22), BRASS, col, axis="Y", seg=48))
    b.append(ring("firebox_band", 0.87, 0.8, 0.1, (0, -1.3, 2.22), BRASS, col, axis="Y", seg=48))
    # smokebox with a domed door
    b.append(cyl("smokebox", 0.9, 0.95, (0, 4.07, 2.22), DARK, col, axis="Y", seg=48, bevel=0.03))
    door = [(0, 0.2), (0.25, 0.19), (0.5, 0.15), (0.7, 0.08), (0.78, 0.0), (0.78, -0.02), (0, -0.02)]
    b.append(lathe("smokebox_door", door[::-1], (0, 4.55, 2.22), DARK, col, seg=48, axis="Y"))
    b.append(ring("smokebox_rim", 0.82, 0.74, 0.05, (0, 4.56, 2.22), BRASS, col, axis="Y", seg=48))
    for z in (2.0, 2.44):
        b.append(box(f"door_strap{z}", (1.1, 0.04, 0.06), (-0.2, 4.72, z), BRASS, col, bevel=0.01))
    b.append(cyl("door_handle", 0.07, 0.14, (0, 4.8, 2.22), BRASS, col, axis="Y", seg=12, bevel=0.02))
    b.append(cyl("number_disc", 0.16, 0.03, (0, 4.74, 2.62), BRASS, col, axis="Y", seg=24))
    # chimney: flared base, slim shaft, bell top with copper crown
    ch = [(0, 0), (0.42, 0), (0.34, 0.08), (0.27, 0.22), (0.25, 0.7), (0.3, 0.86), (0.37, 0.95), (0.4, 1.0),
          (0.3, 1.02), (0, 1.0)]
    b.append(lathe("chimney", ch, (0, 4.05, 2.95), DARK, col, seg=32))
    b.append(ring("chimney_crown", 0.41, 0.3, 0.1, (0, 4.05, 3.95), BRASS, col, seg=32))
    # bell-shaped steam dome and sand dome
    dome = [(0, 0), (0.52, 0), (0.44, 0.06), (0.36, 0.16), (0.35, 0.36), (0.38, 0.42), (0.34, 0.5), (0.24, 0.6),
            (0.1, 0.65), (0, 0.66)]
    b.append(lathe("steam_dome", dome, (0, 1.55, 2.93), BRASS, col, seg=32))
    sand = [(x * 0.72, z * 0.72) for x, z in dome]
    b.append(lathe("sand_dome", sand, (0, 0.05, 2.97), TEAL, col, seg=28))
    b.append(cyl("sand_dome_cap", 0.1, 0.05, (0, 0.05, 3.45), BRASS, col, seg=12))
    # safety valves and whistle
    valve = [(0, 0), (0.1, 0), (0.06, 0.08), (0.05, 0.25), (0.1, 0.32), (0.07, 0.36), (0, 0.36)]
    for x in (-0.12, 0.12):
        b.append(lathe(f"safety_valve{x}", valve, (x, -0.95, 3.0), BRASS, col, seg=16))
    whistle = [(0, 0), (0.04, 0), (0.04, 0.2), (0.07, 0.22), (0.07, 0.42), (0.05, 0.45), (0, 0.45)]
    b.append(lathe("whistle", whistle, (0.35, -1.25, 3.3), BRASS, col, seg=16))
    # side tanks with rounded tops
    for s in (-1, 1):
        b.append(box(f"tank{s}", (0.72, 3.9, 1.3), (s * 0.95, 0.75, 1.99), TEAL, col, bevel=0.1, segs=3))
        b.append(box(f"tank_line_top{s}", (0.02, 3.6, 0.03), (s * 1.315, 0.75, 2.5), BRASS, col, bevel=0.008))
        b.append(box(f"tank_line_bot{s}", (0.02, 3.6, 0.03), (s * 1.315, 0.75, 1.48), BRASS, col, bevel=0.008))
        for y in (-1.0, 2.5):
            b.append(box(f"tank_line_v{s}{y}", (0.02, 0.03, 1.02), (s * 1.315, y + 0.75 - 0.75, 1.99), BRASS, col,
                         bevel=0.008))
        b.append(cyl(f"tank_filler{s}", 0.13, 0.1, (s * 0.95, 2.3, 2.67), BRASS, col, seg=16, bevel=0.02))
        # cylinders and steam chest
        cylp = [(0, -0.5), (0.3, -0.5), (0.34, -0.46), (0.34, -0.4), (0.31, -0.37), (0.31, 0.37), (0.34, 0.4),
                (0.34, 0.46), (0.3, 0.5), (0, 0.5)]
        b.append(lathe(f"cylinder{s}", cylp, (s * 1.1, 3.1, 0.92), DARK, col, seg=24, axis="Y"))
        b.append(cyl(f"cylinder_cover{s}", 0.26, 0.04, (s * 1.1, 3.62, 0.92), BRASS, col, axis="Y", seg=24))
        b.append(box(f"step{s}", (0.36, 0.3, 0.04), (s * 1.18, -3.35, 0.72), DARK, col, bevel=0.01))
        b.append(box(f"step_hanger{s}", (0.04, 0.06, 0.55), (s * 1.3, -3.35, 1.0), DARK, col, bevel=0.01))
        # handrails on stanchions
        b.append(tube(f"handrail{s}", [(s * 0.88, -1.0, 2.9), (s * 0.9, 1.5, 2.92), (s * 0.9, 3.55, 2.9)], 0.022,
                      BRASS, col))
        for y in (-0.9, 1.3, 3.4):
            b.append(cyl(f"stanchion{s}{y}", 0.015, 0.18, (s * 0.86, y, 2.86), BRASS, col, axis="X", seg=6))
    # cab: rounded side openings, spectacle windows, arched roof with overhang
    y0, y1 = -3.95, -1.3
    cy, cl = (y0 + y1) / 2, y1 - y0
    b.append(box("cab_front", (2.5, 0.1, 2.3), (0, y1, 2.5), TEAL, col, bevel=0.03))
    b.append(box("cab_back", (2.5, 0.1, 2.3), (0, y0, 2.5), TEAL, col, bevel=0.03))
    for s in (-1, 1):
        b.append(box(f"cab_side_low{s}", (0.1, cl, 1.1), (s * 1.2, cy, 1.9), TEAL, col, bevel=0.04, segs=2))
        b.append(box(f"cab_pillar_f{s}", (0.1, 0.4, 1.2), (s * 1.2, y1 - 0.2, 3.05), TEAL, col, bevel=0.03))
        b.append(box(f"cab_pillar_b{s}", (0.1, 0.4, 1.2), (s * 1.2, y0 + 0.2, 3.05), TEAL, col, bevel=0.03))
        b.append(tube(f"cab_opening_trim{s}", [(s * 1.26, y1 - 0.4, 2.45), (s * 1.26, cy, 2.47),
                                                (s * 1.26, y0 + 0.4, 2.45)], 0.025, BRASS, col))
        b.append(flat(f"cab_numberplate{s}", rect_pts(0.6, 0.25), (s * 1.26, cy, 2.05), "+X" if s > 0 else "-X",
                      BRASS, col))
    for x in (-0.62, 0.62):
        for yy, facing in ((y1 + 0.06, "+Y"), (y0 - 0.06, "-Y")):
            b.append(flat(f"spectacle{x}{facing}", circle_pts(0.27), (x, yy, 3.05), facing, WINDOW, col))
            sg = 1 if facing == "+Y" else -1
            b.append(ring(f"spectacle_rim{x}{facing}", 0.31, 0.26, 0.05, (x, yy + sg * 0.01, 3.05), BRASS, col,
                          axis="Y", seg=24))
    arc = [(1.5 * math.sin(a), 3.62 + 0.3 * math.cos(a)) for a in np.linspace(-1.35, 1.35, 15)]
    arc = [(x, z) for x, z in arc]
    b.append(sheet("cab_roof", arc, cl + 0.55, 0.07, (0, cy, 0), DARK, col))
    b.append(box("cab_roof_vent", (0.5, 0.8, 0.12), (0, cy, 3.96), DARK, col, bevel=0.04, segs=2))
    # coal bunker
    b.append(box("bunker", (2.5, 0.8, 1.35), (0, -4.37, 1.99), TEAL, col, bevel=0.06, segs=2))
    b.append(box("bunker_rim", (2.54, 0.84, 0.07), (0, -4.37, 2.67), BRASS, col, bevel=0.015))
    rnd = random.Random(3)
    for i in range(16):
        b.append(sphere(f"coal{i}", rnd.uniform(0.14, 0.24), (rnd.uniform(-1.0, 1.0), rnd.uniform(-4.65, -4.05),
                                                                 2.62 + rnd.uniform(0, 0.12)), COAL, col,
                        scale=(1, 1, 0.7), sub=1, seed=i, wobble=0.25))
    # headlamp
    lamp = [(0, -0.18), (0.14, -0.18), (0.19, -0.1), (0.2, 0.12), (0.23, 0.16), (0.23, 0.2), (0, 0.2)]
    b.append(lathe("headlamp", lamp, (0, 4.5, 3.18), BRASS, col, seg=20, axis="Y"))
    b.append(cyl("headlamp_lens", 0.18, 0.02, (0, 4.71, 3.18), LAMP, col, axis="Y", seg=20))
    b.append(cyl("headlamp_top", 0.06, 0.12, (0, 4.5, 3.44), BRASS, col, seg=10, bevel=0.01))
    body = join(b, "Body")

    moving = []
    for i, y in enumerate(drivers):
        moving.append(join(wheelset(f"drv{i}", y, R, col), f"Wheelset_Driver_{i}", origin=(0, y, R)))
    moving.append(join(wheelset("pony", 3.5, 0.45, col, spokes=10, centre=DARK, crank=False), "Wheelset_Pony_0",
                       origin=(0, 3.5, 0.45)))
    rods = []
    for s in (-1, 1):
        rods.append(box(f"coupling_rod{s}", (0.05, drivers[2] - drivers[0] + 0.36, 0.13),
                        (s * 0.93, (drivers[0] + drivers[2]) / 2, R + R * 0.5), BRASS, col, bevel=0.02, segs=2))
        for y in drivers:
            rods.append(cyl(f"rod_boss{s}{y}", 0.11, 0.07, (s * 0.93, y, R + R * 0.5), BRASS, col, axis="X", seg=16,
                            bevel=0.015))
        rods.append(box(f"connecting_rod{s}", (0.05, 2.4, 0.11), (s * 1.0, 2.2, 1.02), DARK, col, bevel=0.02, segs=2))
        rods.append(box(f"crosshead{s}", (0.1, 0.3, 0.2), (s * 1.1, 2.45, 0.92), BRASS, col, bevel=0.02))
    rod_ob = join(rods, "SideRods")
    res = {"Body": 2048, "SideRods": 256}
    res.update({m.name: 512 for m in moving})
    return col, root("Locomotive_Steam", col, [body, rod_ob] + moving, bake_h=(0.3, 4.2), res=res)


# ================================================================= wagon

def build_wagon():
    col = collection("Wagon_Covered")
    b = []
    L = 7.2
    b.append(box("underframe", (1.3, L - 0.4, 0.3), (0, 0, 0.92), DARK, col))
    for s in (-1, 1):
        b.append(box(f"solebar{s}", (0.12, L, 0.32), (s * 1.2, 0, 1.1), DARK, col, bevel=0.02))
        for y in np.linspace(-L / 2 + 0.3, L / 2 - 0.3, 9):
            b.append(cyl(f"rivet{s}{y}", 0.025, 0.03, (s * 1.27, y, 1.1), BRASS, col, axis="X", seg=8))
    b.append(box("floor", (2.62, L, 0.1), (0, 0, 1.3), WOODB, col, bevel=0.02))
    b.append(box("van_body", (2.5, L - 0.2, 2.1), (0, 0, 2.4), WOODW, col, bevel=0.04, segs=2))
    arc = [(1.52 * math.sin(a), 3.42 + 0.32 * math.cos(a)) for a in np.linspace(-1.3, 1.3, 15)]
    b.append(sheet("van_roof", arc, L + 0.2, 0.07, (0, 0, 0), SLATE, col))
    for s in (-1, 1):
        for y in (-(L - 0.3) / 2, (L - 0.3) / 2, -1.55, 1.55):
            b.append(box(f"strap{s}{y}", (0.05, 0.13, 2.1), (s * 1.27, y, 2.4), DARK, col, bevel=0.015))
        for z in (1.62, 3.3):
            b.append(box(f"strap_h{s}{z}", (0.05, L - 0.2, 0.1), (s * 1.27, 0, z), DARK, col, bevel=0.015))
        for y in (-2.4, 2.4):
            b.append(box(f"diag{s}{y}", (0.04, 1.95, 0.1), (s * 1.28, y, 2.45), DARK, col, bevel=0.01,
                         rot=Matrix.Rotation(math.copysign(0.72, y) * s, 3, "X")))
        b.append(box(f"door{s}", (0.08, 1.9, 1.95), (s * 1.31, 0, 2.38), WOODB, col, bevel=0.03, segs=2))
        for z in (1.6, 3.15):
            b.append(box(f"door_band{s}{z}", (0.03, 1.9, 0.1), (s * 1.36, 0, z), DARK, col, bevel=0.01))
        b.append(box(f"door_brace{s}", (0.03, 2.35, 0.1), (s * 1.36, 0, 2.38), DARK, col, bevel=0.01,
                     rot=Matrix.Rotation(-0.78 * s, 3, "X")))
        b.append(cyl(f"door_rail{s}", 0.03, 4.2, (s * 1.34, 0, 3.4), DARK, col, axis="Y", seg=8))
        b.append(tube(f"door_handle{s}", [(s * 1.37, 0.72, 2.2), (s * 1.44, 0.75, 2.38), (s * 1.37, 0.72, 2.56)],
                      0.02, BRASS, col))
        # brass plate in the triangle the diagonal strap leaves free
        b.append(flat(f"brand_plate{s}", rect_pts(0.7, 0.3), (s * 1.3, -2.95 * s, 1.95 if s > 0 else 2.9),
                      "+X" if s > 0 else "-X", BRASS, col))
        for y in (-2.2, 2.2):
            b.append(box(f"axlebox{s}{y}", (0.2, 0.42, 0.38), (s * 0.95, y, 0.52), DARK, col, bevel=0.04, segs=2))
            b.append(cyl(f"axlebox_cap{s}{y}", 0.1, 0.04, (s * 1.06, y, 0.52), BRASS, col, axis="X", seg=12))
            for k in range(4):
                b.append(box(f"leaf{s}{y}{k}", (0.1, 1.3 - k * 0.25, 0.04), (s * 0.95, y, 0.78 - k * 0.045), DARK,
                             col, bevel=0.01))
            b.append(box(f"horn{s}{y}", (0.08, 0.08, 0.5), (s * 0.95, y - 0.3, 0.72), DARK, col, bevel=0.01))
            b.append(box(f"horn2{s}{y}", (0.08, 0.08, 0.5), (s * 0.95, y + 0.3, 0.72), DARK, col, bevel=0.01))
    for yb, sgn in ((L / 2 + 0.05, 1), (-L / 2 - 0.05, -1)):
        b.append(box(f"bufferbeam{sgn}", (2.62, 0.16, 0.42), (0, yb, 1.05), RED, col, bevel=0.03, segs=2))
        for x in (-0.85, 0.85):
            b.append(buffer(f"buffer{sgn}{x}", x, yb + sgn * 0.06, 1.05, sgn, col, head=DARK))
        b.append(box(f"hook{sgn}", (0.1, 0.35, 0.14), (0, yb + sgn * 0.22, 1.0), DARK, col, bevel=0.02))
        b.append(box(f"end_step{sgn}", (0.4, 0.2, 0.04), (0.9, yb + sgn * 0.08, 0.72), DARK, col, bevel=0.01))
    body = join(b, "Body")
    moving = []
    for i, y in enumerate((-2.2, 2.2)):
        moving.append(join(wheelset(f"ws{i}", y, 0.46, col, spokes=8, centre=DARK, crank=False), f"Wheelset_{i}",
                           origin=(0, y, 0.46)))
    res = {"Body": 2048}
    res.update({m.name: 512 for m in moving})
    return col, root("Wagon_Covered", col, [body] + moving, bake_h=(0.3, 3.8), res=res)


# =============================================================== station

def finial(name, loc, col, h=0.5, mat_=BRASS, glow=None):
    prof = [(0, 0), (0.06, 0), (0.035, 0.1), (0.05, 0.2), (0.025, 0.3), (0.01, h)]
    parts = [lathe(name, prof + [(0, h + 0.001)], loc, mat_, col, seg=10)]
    if glow:
        parts.append(sphere(name + "_orb", 0.07, (loc[0], loc[1], loc[2] + 0.22), glow, col, sub=1))
    return parts


def arched_window(tag, face_x, y, zc, w, h, facing, col, out):
    sg = -1 if facing == "-X" else 1
    parts = [flat(f"surround{tag}", arch_pts(w + 0.3, h + 0.2), (face_x + sg * 0.012, y, zc + 0.05), facing, CREAM,
                  col, uv="box"),
             flat(f"win{tag}", arch_pts(w, h), (face_x + sg * 0.03, y, zc), facing, WINDOW, col),
             box(f"keystone{tag}", (0.1, 0.22, 0.3), (face_x + sg * 0.05, y, zc + h / 2 + 0.08), CREAM, col, bevel=0.03),
             box(f"sill{tag}", (0.2, w + 0.35, 0.08), (face_x + sg * 0.09, y, zc - h / 2 - 0.05), CREAM, col,
                 bevel=0.02)]
    if out:
        # flower box
        parts.append(box(f"flowerbox{tag}", (0.28, w + 0.1, 0.22), (face_x + sg * 0.2, y, zc - h / 2 - 0.2), WOODB,
                         col, bevel=0.03))
        rnd = random.Random(sum(map(ord, tag)))
        for k in range(9):
            m = PINK if k % 3 else YELLOW
            if k % 4 == 0:
                m = LEAVES
            parts.append(sphere(f"flower{tag}{k}", rnd.uniform(0.07, 0.11),
                                (face_x + sg * rnd.uniform(0.14, 0.28), y + rnd.uniform(-w / 2, w / 2),
                                 zc - h / 2 - 0.06 + rnd.uniform(0, 0.08)), m, col, sub=1, seed=k, wobble=0.2))
    return parts


def build_station():
    col = collection("Station_Small")
    P = 0.55
    # ---------------- platform
    plat = [box("platform", (7.2, 18.0, P), (5.3, 0, P / 2), STONE, col, bevel=0.04, segs=2),
            box("platform_top", (6.8, 17.6, 0.04), (5.45, 0, P + 0.01), PAVING, col, bevel=0.0),
            box("platform_edge", (0.45, 18.1, 0.1), (1.92, 0, P + 0.02), CREAM, col, bevel=0.03, segs=2)]
    # ---------------- building
    x0, x1, y0, y1 = 5.0, 8.6, -4.2, 4.2
    bx, W, D = (x0 + x1) / 2, x1 - x0, y1 - y0
    top = 4.3
    bld = [box("plinth", (W + 0.16, D + 0.16, 0.7), (bx, 0, P + 0.35), STONE, col, bevel=0.03, segs=2),
           box("walls", (W, D, top - P), (bx, 0, (top + P) / 2), CREAM, col, bevel=0.02),
           box("string_course", (W + 0.1, D + 0.1, 0.1), (bx, 0, 3.55), CREAM, col, bevel=0.03, segs=2),
           box("cornice", (W + 0.3, D + 0.3, 0.14), (bx, 0, top), CREAM, col, bevel=0.05, segs=2),
           box("cornice2", (W + 0.42, D + 0.42, 0.08), (bx, 0, top + 0.1), CREAM, col, bevel=0.03, segs=2)]
    for cx in (x0, x1):
        for cy_ in (y0, y1):
            bld.append(box(f"pilaster{cx}{cy_}", (0.4, 0.4, top - P), (cx, cy_, (top + P) / 2), CREAM, col,
                           bevel=0.04, segs=2))
            bld.append(box(f"capital{cx}{cy_}", (0.5, 0.5, 0.14), (cx, cy_, top - 0.25), CREAM, col, bevel=0.04))
    # steep slate roof
    ridge = 6.7
    slope = math.atan2(ridge - top, W / 2 + 0.3)
    rl = math.hypot(W / 2 + 0.3, ridge - top) + 0.35
    for s in (-1, 1):
        cxr = bx + s * (W / 4 + 0.22)
        bld.append(box(f"roof{s}", (rl, D + 0.9, 0.14), (cxr, 0, (top + ridge) / 2 + 0.16), SLATE, col, bevel=0.04,
                       rot=Matrix.Rotation(s * slope, 3, "Y")))
    bld.append(cyl("ridge", 0.09, D + 0.95, (bx, 0, ridge + 0.26), VERD, col, axis="Y", seg=12))
    for yy in (y0, y1):
        tri = (0, 1, 2) if yy == y0 else (2, 1, 0)
        bld.append(poly(f"gable{yy}", [(x0, yy, top + 0.15), (x1, yy, top + 0.15), (bx, yy, ridge)], [tri], CREAM,
                        col))
        facing = "-Y" if yy == y0 else "+Y"
        sg = -1 if yy == y0 else 1
        bld.append(flat(f"oculus{yy}", circle_pts(0.38), (bx, yy + sg * 0.03, 5.25), facing, WINDOW, col))
        bld.append(ring(f"oculus_rim{yy}", 0.5, 0.36, 0.08, (bx, yy + sg * 0.03, 5.25), CREAM, col, axis="Y",
                        seg=28))
    # chimney
    bld.append(box("chimney", (0.55, 0.7, 1.7), (bx + 0.95, y0 + 1.6, ridge - 0.2), BRICK, col, bevel=0.03))
    bld.append(box("chimney_cap", (0.7, 0.85, 0.12), (bx + 0.95, y0 + 1.6, ridge + 0.68), CREAM, col, bevel=0.03))
    for k, dy in enumerate((-0.15, 0.15)):
        pot = [(0, 0), (0.11, 0), (0.09, 0.3), (0.12, 0.36), (0.1, 0.4), (0, 0.4)]
        bld.append(lathe(f"chimney_pot{k}", pot, (bx + 0.95, y0 + 1.6 + dy, ridge + 0.74), RED, col, seg=14))
    # windows (arched), doors
    for face_x, facing in ((x0, "-X"), (x1, "+X")):
        for yy in (-2.4, 2.4):
            bld += arched_window(f"{facing}{yy}", face_x, yy, 2.45, 1.2, 1.9, facing, col, out=True)
        sg = -1 if facing == "-X" else 1
        bld.append(flat(f"door_surround{facing}", arch_pts(1.75, 2.85), (face_x + sg * 0.012, 0, P + 1.4), facing,
                        CREAM, col, uv="box"))
        bld.append(flat(f"door{facing}", arch_pts(1.35, 2.6), (face_x + sg * 0.03, 0, P + 1.3), facing, DOOR, col))
        bld.append(box(f"door_key{facing}", (0.12, 0.26, 0.34), (face_x + sg * 0.06, 0, P + 2.72), CREAM, col,
                       bevel=0.02))
        bld.append(box(f"door_step{facing}", (0.5, 1.9, 0.08), (face_x + sg * 0.25, 0, P + 0.04), STONE, col,
                       bevel=0.03))
    for yy, facing in ((y0, "-Y"), (y1, "+Y")):
        sg = -1 if facing == "-Y" else 1
        bld.append(flat(f"end_surround{facing}", arch_pts(1.5, 2.1), (bx, yy + sg * 0.012, 2.5), facing, CREAM, col,
                        uv="box"))
        bld.append(flat(f"end_win{facing}", arch_pts(1.2, 1.9), (bx, yy + sg * 0.03, 2.45), facing, WINDOW, col))
    # wall clock + lamp brackets by the door
    bld.append(ring("clock_case", 0.46, 0.0, 0.1, (x0 - 0.07, 0, 3.62 + 0.0), BRASS, col, axis="X", seg=28))
    bld.append(flat("clock_face", circle_pts(0.38), (x0 - 0.125, 0, 3.62), "-X", CLOCK, col))
    for dy in (-1.1, 1.1):
        bld.append(tube(f"wall_lamp_arm{dy}", [(x0 - 0.02, dy, 2.9), (x0 - 0.3, dy, 3.0), (x0 - 0.42, dy, 2.85)],
                        0.025, DARK, col))
        lan = [(0, 0), (0.08, 0), (0.12, 0.08), (0.12, 0.26), (0.16, 0.3), (0.02, 0.4), (0, 0.4)]
        bld.append(lathe(f"wall_lantern{dy}", lan, (x0 - 0.42, dy, 2.45), DARK, col, seg=8))
        bld.append(cyl(f"wall_lantern_glow{dy}", 0.1, 0.18, (x0 - 0.42, dy, 2.62), LAMP, col, seg=8))
    building = join(bld, "Building")

    # ---------------- canopy on cast-iron columns
    cx0, cx1 = 2.25, x0
    h_in, h_out = 4.05, 3.55
    prof = []
    for t in np.linspace(0, 1, 12):
        x = cx0 - 0.25 + (cx1 - cx0 + 0.25) * t
        z = h_out + (h_in - h_out) * t + 0.22 * math.sin(math.pi * t)
        prof.append((x, z))
    can = [sheet("canopy_roof", prof, 12.4, 0.06, (0, 0, 0), VERD, col)]
    # pointed valance boards along the front edge
    vs, fs = [], []
    n = 62
    for k in range(n):
        y_a = -6.2 + 12.4 * k / n
        y_b = -6.2 + 12.4 * (k + 1) / n
        i = len(vs)
        vs += [(cx0 - 0.23, y_a, h_out - 0.03), (cx0 - 0.23, (y_a + y_b) / 2, h_out - 0.3),
               (cx0 - 0.23, y_b, h_out - 0.03)]
        fs.append((i + 2, i + 1, i))
    can.append(poly("valance", vs, fs, VERD, col))
    can.append(box("canopy_beam", (0.14, 12.2, 0.18), (2.6, 0, h_out - 0.02), DARK, col, bevel=0.02))
    col_prof = [(0, 0), (0.16, 0), (0.16, 0.08), (0.12, 0.14), (0.1, 0.2), (0.075, 0.3), (0.07, 2.4), (0.09, 2.5),
                (0.08, 2.56), (0.16, 2.66), (0.18, 2.72), (0.0, 2.73)]
    for py in (-5.6, -1.9, 1.9, 5.6):
        can.append(lathe(f"column{py}", col_prof, (2.6, py, P), VERD, col, seg=16))
        for side in (-1, 1):
            # art-nouveau scroll brackets under the roof
            can.append(tube(f"bracket{py}{side}", [(2.6, py, P + 2.1), (2.6 + side * 0.25, py, P + 2.45),
                                                     (2.6 + side * 0.55, py, P + 2.7)], 0.025, DARK, col))
            can.append(tube(f"bracket_curl{py}{side}", scroll(2.6 + side * 0.18, P + 2.38, 0.12, 0.02, 0.8, n=12,
                                                             y=py, start=math.pi if side > 0 else 0, flip=side),
                            0.018, DARK, col))
    # name board hung from the beam
    sy = 3.75
    can.append(box("sign_board", (0.08, 2.7, 0.55), (2.62, sy, h_out - 0.6), DARK, col, bevel=0.02))
    can.append(box("sign_frame", (0.06, 2.84, 0.69), (2.665, sy, h_out - 0.6), BRASS, col, bevel=0.02))
    for dy in (-1.1, 1.1):
        can.append(cyl(f"sign_hanger{dy}", 0.012, 0.3, (2.62, sy + dy, h_out - 0.2), BRASS, col, seg=6))
    txt_rot = Matrix.Rotation(-math.pi / 2, 4, "Z") @ Matrix.Rotation(math.pi / 2, 4, "X")
    can.append(text_mesh("sign_text", "OPENRAIL", 0.34, (2.565, sy, h_out - 0.6), BRASS, col, txt_rot))
    can.append(text_mesh("sign_text_back", "OPENRAIL", 0.34, (2.72, sy, h_out - 0.6), BRASS, col,
                         Matrix.Rotation(math.pi / 2, 4, "Z") @ Matrix.Rotation(math.pi / 2, 4, "X")))
    # benches with iron scroll ends
    for i, by_ in enumerate((-2.1, 2.1)):
        for k in range(3):
            can.append(box(f"bench_slat{i}{k}", (0.13, 1.9, 0.05), (4.35 + k * 0.15, by_, P + 0.46), WOODB, col,
                           bevel=0.015))
        for k in range(2):
            can.append(box(f"bench_back{i}{k}", (0.05, 1.9, 0.13), (4.7, by_, P + 0.66 + k * 0.17), WOODB, col,
                           bevel=0.015, rot=Matrix.Rotation(-0.2, 3, "Y")))
        for dy in (-0.8, 0.8):
            can.append(tube(f"bench_end{i}{dy}", [(4.25, by_ + dy, P), (4.35, by_ + dy, P + 0.35),
                                                   (4.6, by_ + dy, P + 0.44), (4.72, by_ + dy, P + 0.9),
                                                   (4.62, by_ + dy, P + 1.0)], 0.03, DARK, col))
            can.append(tube(f"bench_leg{i}{dy}", [(4.7, by_ + dy, P), (4.62, by_ + dy, P + 0.44)], 0.03, DARK, col))
    # swan-neck lamp posts
    for i, ly in enumerate((-7.8, 7.8)):
        base = [(0, 0), (0.2, 0), (0.2, 0.1), (0.14, 0.2), (0.12, 0.45), (0.07, 0.6), (0.055, 3.3), (0.08, 3.36),
                (0.0, 3.4)]
        can.append(lathe(f"lamp_post{i}", base, (2.5, ly, P), VERD, col, seg=14))
        can.append(tube(f"lamp_neck{i}", [(2.5, ly, P + 3.3), (2.5, ly, P + 3.6), (2.75, ly, P + 3.75),
                                           (2.98, ly, P + 3.6)], 0.04, VERD, col))
        lan = [(0, 0), (0.1, 0), (0.18, 0.1), (0.2, 0.34), (0.26, 0.4), (0.14, 0.52), (0.04, 0.6), (0, 0.62)]
        can.append(lathe(f"lamp_lantern{i}", lan, (2.98, ly, P + 2.9), DARK, col, seg=8))
        can.append(sphere(f"lamp_globe{i}", 0.15, (2.98, ly, P + 3.12), LAMP, col, sub=2))
    canopy = join(can, "Canopy")
    platform = join(plat, "Platform")
    res = {"Building": 2048, "Canopy": 2048, "Platform": 2048}
    return col, root("Station_Small", col, [platform, building, canopy], bake_h=(0.0, 8.0), res=res)


# ===================================================== terrain + trees

def build_terrain():
    col = collection("Terrain_Sample")
    bm = bmesh.new()
    size = 24.0
    bmesh.ops.create_grid(bm, x_segments=64, y_segments=64, size=size / 2)
    for v in bm.verts:
        x, y = v.co.x, v.co.y
        u = (x / size + 0.5)
        w = (y / size + 0.5)
        h = (0.35 * math.sin(u * 5.1 + 1.3) * math.cos(w * 4.3) + 0.2 * math.sin(u * 11 + w * 7) +
             0.12 * math.cos(w * 13 - u * 3))
        centre = 0.5 + 0.14 * math.sin(w * 2 * math.pi + 0.6) + 0.04 * math.sin(w * 2 * math.pi * 3)
        d = abs(u - centre)
        h -= 0.18 * max(0.0, 1 - d / 0.08)
        edge = min(u, 1 - u, w, 1 - w)
        h *= min(1.0, edge / 0.1)
        v.co.z = h
    ground = finish("Ground", bm, GRASS, col, smooth=True, uv="terrain")
    me = ground.data
    uvl = me.uv_layers.new(name="UVMap")
    for li, loop in enumerate(me.loops):
        co = me.vertices[loop.vertex_index].co
        uvl.data[li].uv = (co.x / size + 0.5, co.y / size + 0.5)
    for p in me.polygons:
        p.use_smooth = True
    props = []
    rnd = random.Random(4)
    for i in range(9):
        x, y = rnd.uniform(-10, 10), rnd.uniform(-10, 10)
        s = rnd.uniform(0.25, 0.7)
        props.append(sphere(f"rock{i}", s, (x, y, 0.0), STONE, col, scale=(1.3, 1.0, 0.6), sub=1, seed=i,
                            wobble=0.25))
    bushes = []
    for i, (x, y) in enumerate(((-7, 6), (8, -7), (6, 8.5), (-9, -4))):
        c = Vector((x, y, 0.45))
        for k in range(5):
            o = Vector((rnd.uniform(-0.5, 0.5), rnd.uniform(-0.5, 0.5), rnd.uniform(0, 0.35)))
            bushes.append(sphere(f"bush{i}{k}", rnd.uniform(0.45, 0.65), c + o, LEAVES, col, scale=(1, 1, 0.8), sub=3,
                                 seed=i * 7 + k, wobble=0.1))
    props_ob = join(props + bushes, "Props")
    # per-bush spherical normals: recompute using the nearest bush centre
    me = props_ob.data
    centres = [Vector((x, y, 0.55)) for x, y in ((-7, 6), (8, -7), (6, 8.5), (-9, -4))]
    leaf_idx = [i for i, m in enumerate(me.materials) if m.name.startswith("M_leaves")]
    normals = [v.normal.copy() for v in me.vertices]
    crown = set()
    for p in me.polygons:
        if p.material_index in leaf_idx:
            crown.update(p.vertices)
    for i in crown:
        co = me.vertices[i].co
        c = min(centres, key=lambda c: (c - co).length)
        normals[i] = ((co - c).normalized() * 0.8 + me.vertices[i].normal * 0.2).normalized()
    me.normals_split_custom_set_from_vertices(normals)
    return col, root("Terrain_Sample", col, [ground, props_ob], bake_h=(-0.5, 1.5),
                     res={"Ground": 2048, "Props": 1024})


def build_tree_deciduous():
    col = collection("Tree_Deciduous")
    rnd = random.Random(7)
    parts = [lathe("trunk", [(0, 0), (0.42, 0), (0.3, 0.2), (0.24, 0.6), (0.2, 2.2), (0.16, 3.3), (0, 3.4)],
                   (0, 0, 0), BARK, col, seg=12)]
    for i, (ang, tilt, ln) in enumerate(((0.3, 0.7, 1.7), (2.4, 0.8, 1.5), (4.3, 0.6, 1.6), (5.4, 0.5, 1.2))):
        z0 = 2.0 + i * 0.3
        d = Vector((math.cos(ang) * math.sin(tilt), math.sin(ang) * math.sin(tilt), math.cos(tilt)))
        p0 = Vector((0, 0, z0))
        p1 = p0 + d * ln * 0.5 + Vector((0, 0, 0.2))
        p2 = p0 + d * ln
        parts.append(tube(f"branch{i}", [tuple(p0), tuple(p1), tuple(p2)], 0.11, BARK, col, radii=[1.0, 0.7, 0.35]))
    # fluffy crown: many blobs around an ellipsoid
    centre = Vector((0, 0, 4.7))
    blobs = [(centre, 1.6)]
    for k in range(14):
        a = rnd.uniform(0, 2 * math.pi)
        e = rnd.uniform(-0.35, 0.9)
        d = Vector((math.cos(a) * math.cos(e) * 1.5, math.sin(a) * math.cos(e) * 1.5, math.sin(e) * 1.2))
        blobs.append((centre + d, rnd.uniform(0.75, 1.1)))
    for i, (c, r) in enumerate(blobs):
        parts.append(sphere(f"crown{i}", r, tuple(c), LEAVES, col, scale=(1, 1, 0.9), sub=3, seed=i, wobble=0.04))
    ob = join(parts, "Tree")
    leaf = {i for i, m in enumerate(ob.data.materials) if m.name.startswith("M_leaves")}
    spherical_normals(ob, leaf, tuple(centre), squash=(1.2, 1.2, 1.0))
    return col, root("Tree_Deciduous", col, [ob], bake_h=(0.0, 6.5), res={"Tree": 1024})


def build_tree_conifer():
    col = collection("Tree_Conifer")
    parts = [lathe("trunk", [(0, 0), (0.3, 0), (0.2, 0.25), (0.16, 1.5), (0.1, 6.0), (0, 6.1)], (0, 0, 0), BARK,
                   col, seg=10)]
    tiers = [(1.1, 2.0, 1.9), (2.1, 1.7, 1.7), (3.0, 1.4, 1.6), (3.9, 1.1, 1.4), (4.7, 0.8, 1.2), (5.4, 0.5, 1.0)]
    for i, (z, r, h) in enumerate(tiers):
        # drooping skirt: concave cone with a soft lip
        prof = [(0, 0.0), (r * 0.55, 0.05), (r, -0.12), (r * 0.96, 0.02), (r * 0.6, h * 0.45), (r * 0.25, h * 0.8),
                (0, h)]
        t = lathe(f"tier{i}", prof, (0, 0, z), CONIFER, col, seg=11, rot=Matrix.Rotation(i * 0.4, 3, "Z"), sharp=60)
        for v in t.data.vertices:
            v.co.x *= 1 + 0.08 * math.sin(v.co.y * 5 + i)
            v.co.y *= 1 + 0.08 * math.cos(v.co.x * 5 + i)
        parts.append(t)
    ob = join(parts, "Tree")
    leaf = {i for i, m in enumerate(ob.data.materials) if m.name.startswith("M_leaves")}
    spherical_normals(ob, leaf, (0, 0, 2.6), squash=(0.7, 0.7, 1.6))
    return col, root("Tree_Conifer", col, [ob], bake_h=(0.0, 6.5), res={"Tree": 1024})


# ================================================================ baking

def kuwahara(rgb, r):
    H, W, _ = rgb.shape
    lum = rgb @ np.array([0.3, 0.59, 0.11], dtype=np.float32)
    P = np.pad(rgb, ((r, r), (r, r), (0, 0)), mode="edge")
    PL = np.pad(lum, r, mode="edge")
    k = r + 1

    def boxm(a):
        c = np.cumsum(np.cumsum(a, 0, dtype=np.float64), 1)
        pad = ((1, 0), (1, 0)) + (((0, 0),) if a.ndim == 3 else ())
        c = np.pad(c, pad)
        return ((c[k:, k:] - c[:-k, k:] - c[k:, :-k] + c[:-k, :-k]) / (k * k)).astype(np.float32)

    M, ML, ML2 = boxm(P), boxm(PL), boxm(PL * PL)
    V = ML2 - ML ** 2
    offs = [(0, 0), (0, r), (r, 0), (r, r)]
    vs = np.stack([V[oy:oy + H, ox:ox + W] for oy, ox in offs])
    idx = vs.argmin(0)
    out = np.empty_like(rgb)
    for q, (oy, ox) in enumerate(offs):
        m = idx == q
        out[m] = M[oy:oy + H, ox:ox + W][m]
    return out


def setup_cycles():
    scene.render.engine = "CYCLES"
    scene.cycles.samples = 8 if FAST else 32
    scene.cycles.use_denoising = False
    scene.render.bake.margin = 10
    scene.render.bake.use_clear = True
    try:
        prefs = bpy.context.preferences.addons["cycles"].preferences
        for t in ("OPTIX", "CUDA", "HIP", "ONEAPI", "METAL"):
            try:
                prefs.compute_device_type = t
            except TypeError:
                continue
            prefs.get_devices()
            devs = [d for d in prefs.devices if d.type == t]
            if devs:
                for d in prefs.devices:
                    d.use = d.type == t
                scene.cycles.device = "GPU"
                print("bake device", t, [d.name for d in devs])
                return
    except Exception as exc:  # noqa: BLE001
        print("GPU setup failed:", exc)
    print("bake device CPU")


def _sock(node, name, kind, out=False):
    socks = node.outputs if out else node.inputs
    return [s for s in socks if s.name == name and s.type == kind][0]


def bake_material(m, img, h0, h1):
    """Copy of `m` whose emission is the painted-light colour; target image node active."""
    mb = m.copy()
    nt = mb.node_tree
    N, Lk = nt.nodes, nt.links
    bsdf = N["Principled BSDF"]
    out = N["Material Output"]
    bc = bsdf.inputs["Base Color"]
    if bc.is_linked:
        base = bc.links[0].from_socket
    else:
        rgb = N.new("ShaderNodeRGB")
        rgb.outputs[0].default_value = bc.default_value
        base = rgb.outputs[0]
    geo = N.new("ShaderNodeNewGeometry")
    sep_n = N.new("ShaderNodeSeparateXYZ")
    Lk.new(geo.outputs["Normal"], sep_n.inputs[0])
    sep_p = N.new("ShaderNodeSeparateXYZ")
    Lk.new(geo.outputs["Position"], sep_p.inputs[0])

    def maprange(src, a, b, c, d):
        mr = N.new("ShaderNodeMapRange")
        mr.clamp = True
        Lk.new(src, mr.inputs["Value"])
        mr.inputs["From Min"].default_value = a
        mr.inputs["From Max"].default_value = b
        mr.inputs["To Min"].default_value = c
        mr.inputs["To Max"].default_value = d
        return mr.outputs["Result"]

    def math_(op, a, b):
        n = N.new("ShaderNodeMath")
        n.operation = op
        n.use_clamp = False
        for i, v in enumerate((a, b)):
            if isinstance(v, (int, float)):
                n.inputs[i].default_value = v
            else:
                Lk.new(v, n.inputs[i])
        return n.outputs[0]

    up = maprange(sep_n.outputs["Z"], -1, 1, 0.0, 0.32)
    hz = maprange(sep_p.outputs["Z"], h0, h1, 0.0, 0.22)
    ao = N.new("ShaderNodeAmbientOcclusion")
    ao.samples = 16
    ao.inputs["Distance"].default_value = 0.7
    aof = maprange(ao.outputs["AO"], 0, 1, 0.45, 1.0)
    light = math_("MULTIPLY", math_("ADD", math_("ADD", up, hz), 0.5), aof)
    tint = N.new("ShaderNodeMix")
    tint.data_type = "RGBA"
    tint.clamp_factor = True
    Lk.new(light, _sock(tint, "Factor", "VALUE"))
    _sock(tint, "A", "RGBA").default_value = (*srgb("#6a80b0"), 1)   # cool blue shadows
    _sock(tint, "B", "RGBA").default_value = (*srgb("#fff6e6"), 1)   # warm daylight
    mul = N.new("ShaderNodeMix")
    mul.data_type = "RGBA"
    mul.blend_type = "MULTIPLY"
    _sock(mul, "Factor", "VALUE").default_value = 1.0
    Lk.new(base, _sock(mul, "A", "RGBA"))
    Lk.new(_sock(tint, "Result", "RGBA", out=True), _sock(mul, "B", "RGBA"))
    boost = N.new("ShaderNodeMix")  # lift the result so lit areas stay close to the painted colour
    boost.data_type = "RGBA"
    boost.blend_type = "MULTIPLY"
    _sock(boost, "Factor", "VALUE").default_value = 1.0
    Lk.new(_sock(mul, "Result", "RGBA", out=True), _sock(boost, "A", "RGBA"))
    _sock(boost, "B", "RGBA").default_value = (1.25, 1.22, 1.18, 1)
    # warm edge highlights from the difference between bevelled and true normals
    bev = N.new("ShaderNodeBevel")
    bev.samples = 8
    bev.inputs["Radius"].default_value = 0.03
    dot = N.new("ShaderNodeVectorMath")
    dot.operation = "DOT_PRODUCT"
    Lk.new(bev.outputs["Normal"], dot.inputs[0])
    Lk.new(geo.outputs["Normal"], dot.inputs[1])
    edge = maprange(dot.outputs["Value"], 0.985, 0.8, 0.0, 0.45)
    edge = math_("MULTIPLY", edge, maprange(sep_n.outputs["Z"], -1, 1, 0.3, 1.0))
    add = N.new("ShaderNodeMix")
    add.data_type = "RGBA"
    add.blend_type = "SCREEN"
    Lk.new(edge, _sock(add, "Factor", "VALUE"))
    Lk.new(_sock(boost, "Result", "RGBA", out=True), _sock(add, "A", "RGBA"))
    _sock(add, "B", "RGBA").default_value = (*srgb("#ffe2a8"), 1)
    em = N.new("ShaderNodeEmission")
    Lk.new(_sock(add, "Result", "RGBA", out=True), em.inputs["Color"])
    Lk.new(em.outputs[0], out.inputs["Surface"])
    target = N.new("ShaderNodeTexImage")
    target.image = img
    N.active = target
    return mb


def bake_object(ob, asset):
    me = ob.data
    res = int(ob.get("bake_res", 1024))
    if FAST:
        res = max(128, res // 4)
    h0, h1 = ob.get("bake_h0", 0.0), ob.get("bake_h1", 4.0)
    name = f"{asset}_{ob.name}"
    select_only([ob])
    bake_uv = me.uv_layers.new(name="BakeUV")
    me.uv_layers.active = bake_uv
    bpy.ops.object.mode_set(mode="EDIT")
    bpy.ops.mesh.select_all(action="SELECT")
    bpy.ops.uv.smart_project(angle_limit=math.radians(55), island_margin=0.004, area_weight=0.0,
                             correct_aspect=True, scale_to_bounds=False)
    bpy.ops.uv.pack_islands(margin=0.004, rotate=True)
    bpy.ops.object.mode_set(mode="OBJECT")
    img = bpy.data.images.new(name + "_albedo", res, res, alpha=False)
    originals = list(me.materials)
    temps = [bake_material(m, img, h0, h1) for m in originals]
    for i, t in enumerate(temps):
        me.materials[i] = t
    bpy.ops.object.bake(type="EMIT", margin=10, use_clear=True)
    # painterly post-process
    px = np.empty(res * res * 4, dtype=np.float32)
    img.pixels.foreach_get(px)
    px = px.reshape(res, res, 4)
    rgb = kuwahara(px[..., :3].copy(), 3 if res >= 1024 else 2)
    px[..., :3] = np.clip(rgb, 0, 1)
    img.pixels.foreach_set(px.ravel())
    path = os.path.join(BAKED, name + ".png")
    img.filepath_raw = path
    img.file_format = "PNG"
    img.save()
    bpy.data.images.remove(img)
    img = bpy.data.images.load(path)
    # final material set: one baked albedo + untouched emissive materials
    final = bpy.data.materials.new(f"M_{asset}_{ob.name}")
    final.use_nodes = True
    fb = final.node_tree.nodes["Principled BSDF"]
    fb.inputs["Roughness"].default_value = 0.75
    tn = final.node_tree.nodes.new("ShaderNodeTexImage")
    tn.image = img
    final.node_tree.links.new(tn.outputs["Color"], fb.inputs["Base Color"])
    new_mats = [final]
    remap = {}
    for i, m in enumerate(originals):
        if m.get("emissive"):
            if m not in new_mats:
                new_mats.append(m)
            remap[i] = new_mats.index(m)
        else:
            remap[i] = 0
    idx = [remap[p.material_index] for p in me.polygons]
    me.materials.clear()
    for m in new_mats:
        me.materials.append(m)
    for p, i in zip(me.polygons, idx):
        p.material_index = i
    for t in temps:
        bpy.data.materials.remove(t)
    me.uv_layers.remove(me.uv_layers["UVMap"])
    me.uv_layers[0].name = "UVMap"
    print("baked", name, res)


# ================================================================ export

def export(root_ob, path):
    select_only([root_ob] + list(root_ob.children_recursive), active=root_ob)
    bpy.ops.export_scene.gltf(filepath=path, export_format="GLB", use_selection=True, export_apply=True,
                              export_yup=True, export_texcoords=True, export_normals=True,
                              export_materials="EXPORT", export_image_format="AUTO")
    print("exported", path, os.path.getsize(path))


ASSETS = [
    ("vehicles/locomotive_steam.glb", build_locomotive, (0, 0, 0)),
    ("vehicles/wagon_covered.glb", build_wagon, (0, -9.4, 0)),
    ("buildings/station_small.glb", build_station, (0, 0, 0)),
    ("nature/terrain_sample.glb", build_terrain, (24, 0, -0.05)),
    ("nature/tree_deciduous.glb", build_tree_deciduous, (20, -5, 0)),
    ("nature/tree_conifer.glb", build_tree_conifer, (27, 6, 0)),
]

setup_cycles()
roots = {}
for rel, fn, _ in ASSETS:
    col, r = fn()
    roots[rel] = (col, r)
    for c in scene.collection.children:  # bake each asset alone so no other asset darkens its AO
        c.hide_render = c != col
    for ob in list(r.children):
        if ob.type == "MESH":
            bake_object(ob, r.name)
    path = os.path.join(EXPORT, rel)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    export(r, path)
    # free generic node names (Body, Tree...) for the next asset; the .glb keeps the clean names
    for ob in r.children:
        ob.name = f"{r.name}_{ob.name}"
for rel, _, off in ASSETS:
    roots[rel][1].location = off

# ============================================================== previews
world = bpy.data.worlds.new("Dusk")
world.use_nodes = True
bg = world.node_tree.nodes["Background"]
bg.inputs["Color"].default_value = (*srgb("#a9c8ec"), 1)
bg.inputs["Strength"].default_value = 1.0
scene.world = world
sun_data = bpy.data.lights.new("Sun", "SUN")
sun_data.energy = 3.6
sun_data.color = srgb("#fff0d8")
sun_data.angle = math.radians(4)
sun = bpy.data.objects.new("Sun", sun_data)
sun.rotation_euler = (math.radians(55), math.radians(8), math.radians(-35))
scene.collection.objects.link(sun)
rim_data = bpy.data.lights.new("Rim", "SUN")
rim_data.energy = 0.6
rim_data.color = srgb("#8fb4ff")
rim = bpy.data.objects.new("Rim", rim_data)
rim.rotation_euler = (math.radians(70), 0, math.radians(150))
scene.collection.objects.link(rim)
prev = collection("Preview_Only")
for x in (-0.72, 0.72):
    box(f"rail{x}", (0.07, 44, 0.14), (x, -4, -0.07), DARK, prev, bevel=0.005)
for i in range(-14, 14):
    box(f"sleeper{i}", (2.6, 0.25, 0.15), (0, i * 0.8 - 4, -0.2), WOODB, prev, bevel=0.02)
box("ballast", (3.4, 44, 0.3), (0, -4, -0.4), STONE, prev, bevel=0.12, segs=2)
box("ground", (80, 80, 0.1), (5, 0, -0.6), mat("preview_ground", color="#5f7d48"), prev, bevel=0)
apply_uvs(prev)

cam_data = bpy.data.cameras.new("Cam")
cam = bpy.data.objects.new("Cam", cam_data)
scene.collection.objects.link(cam)
scene.camera = cam
try:
    scene.render.engine = "BLENDER_EEVEE"
except TypeError:
    scene.render.engine = "BLENDER_EEVEE_NEXT"
scene.view_settings.view_transform = "Standard"
scene.view_settings.look = "None"
scene.render.resolution_x = 1600
scene.render.resolution_y = 900
try:
    scene.eevee.use_shadows = True
    scene.eevee.taa_render_samples = 64
except AttributeError:
    pass

bpy.ops.wm.save_as_mainfile(filepath=os.path.join(BLEND, "openrail_assets.blend"), relative_remap=True)


def shot(name, target, dist, height, yaw, lens=50, show=None):
    for c in scene.collection.children:
        c.hide_render = show is not None and c.name not in show
    t = Vector(target)
    cam.location = t + Vector((math.cos(yaw) * dist, math.sin(yaw) * dist, height))
    cam.rotation_euler = (t - cam.location).to_track_quat("-Z", "Y").to_euler()
    cam_data.lens = lens
    scene.render.filepath = os.path.join(PREVIEW, name + ".png")
    bpy.ops.render.render(write_still=True)
    print("rendered", name)


if RENDER:
    shot("locomotive_steam", (0, 0.4, 1.9), 13, 3.2, math.radians(-38), show={"Locomotive_Steam", "Preview_Only"})
    shot("locomotive_front", (0, 2.5, 2.0), 10, 2.2, math.radians(60), show={"Locomotive_Steam", "Preview_Only"})
    shot("wagon_covered", (0, -9.4, 1.9), 12, 3.0, math.radians(-30), show={"Wagon_Covered", "Preview_Only"})
    shot("station_small", (5.5, 0, 3.6), 25, 7.5, math.radians(-155), show={"Station_Small", "Preview_Only"})
    shot("nature", (24, 0, 2.2), 25, 8, math.radians(-60), lens=40,
         show={"Terrain_Sample", "Tree_Deciduous", "Tree_Conifer"})
    shot("overview", (6, -3, 1.5), 36, 13, math.radians(-135), lens=35)
