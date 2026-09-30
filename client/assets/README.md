# Art assets

Painted 3D models for the client, exported from Blender as `.glb` (textures embedded).
Sources and the scripts that generate them live in [`art-src/`](../../art-src/README.md).

| File | What | Nodes |
| --- | --- | --- |
| `vehicles/locomotive_steam.glb` | Tank steam loco, ~10 m over buffers | `Body`, `SideRods`, `Wheelset_Driver_0..2`, `Wheelset_Pony_0` |
| `vehicles/wagon_covered.glb` | Covered goods van, ~8 m | `Body`, `Wheelset_0..1` |
| `buildings/station_small.glb` | Station building, 18 m platform (0.55 m high), canopy, benches, lamps | `Platform`, `Building`, `Canopy` |
| `nature/terrain_sample.glb` | 24 × 24 m ground tile with a path, rocks and bushes | `Ground`, `Props` |
| `nature/tree_deciduous.glb`, `nature/tree_conifer.glb` | Stylised trees, ~6.5 m | `Tree` |

## Conventions

* Metres, Y-up. Vehicles face **-Z**; origin on top of the rail, centred on the vehicle.
  Gauge 1435 mm, wheels at x = ±0.72 m.
* Wheelsets are separate nodes with the origin on the axle: spin them around local X.
* Station: the track axis is x = 0 along the vehicles' Z axis, the platform is on the +X side.
* Each mesh has one material `M_<Asset>_<Mesh>` with a baked, hand-painted albedo that already
  contains painted light (blue shadows, occlusion, warm edge highlights), plus the emissive
  `M_lamp_glow` for lamps. `ArtStyle` (`client/art/`) swaps `M_` materials for the painterly
  shader; keep its lighting soft on these so they are not shaded twice.
* Foliage has custom normals pointing out of the crown so it shades as one soft volume.
  Keep the imported normals.

Binary files are in Git LFS: run `git lfs install` once, then clone or `git lfs pull`.
