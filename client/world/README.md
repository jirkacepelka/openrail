# World: terrain, tracks and towns

Client-side scenery generated from the simulation's state. Nothing here
changes the simulation or its hash: it only reads `SimWorld` getters.

## Ground height (`ground.gd`)

`Ground.height_at(sim, x, z)` is the one place that knows the ground height
at Godot (x, z) (sim (x, y)). Everything placed on the land asks it. It calls
`SimWorld.terrain_height`, a pure function of the world seed computed in
`openrail-sim` (`terrain.rs`, fixed point), so the client, the server and
every remote view (the seed comes with the server's Welcome) agree exactly.
The terrain is not part of the world state. Also: `point_at`,
`normal_at`, `slope_at`, `is_water`, `water_level`.

For many points at once use `SimWorld.terrain_heights_at(points)` (a
`PackedVector2Array` of sim positions) or `terrain_heights(x0, y0, step, nx,
ny)` (a grid, row by row, x fastest); `terrain_wetness` gives the wetness
on the same grid.

The landscape: plains at 20 to 80 m with rolling hills, hilly regions up to
about 250 m, a few lakes and one river through a wide valley. Everything
below `terrain_water_level()` (12 m) is water; `terrain.gd` draws one water
surface at that height.

## Terrain mesh (`terrain.gd`)

A quadtree of square chunks around the camera: 8192 m cells far away,
split into 2048 m and then 512 m cells as the camera gets closer. Each chunk
is a heightfield grid of at most 33 x 33 vertices: 16 or 32 m spacing for
512 m chunks, 64 or 128 m for 2048 m chunks, 256 m beyond. Skirts hang from
every chunk edge to hide cracks between levels. Chunks are rebuilt a few per frame, nearest first
(`budget_ms`); `build_all_now()` finishes at once (tests, screenshots). The
material is the painterly ground shader (`art/shaders/painterly_ground.gdshader`).

### Vertex data for terrain shading

Every terrain vertex carries, for the art team's shader:

| Attribute | Content |
| --- | --- |
| `VERTEX` | position relative to the chunk corner (`MODEL_MATRIX` gives world space) |
| `NORMAL` | smooth normal from the height field (matches across chunks of the same level) |
| `UV` | world (x, z) / 100: one UV unit per 100 m, continuous over all chunks |
| `COLOR.r` | height normalised: 0 at 0 m, 1 at 250 m (clamped) |
| `COLOR.g` | slope as rise over run, clamped to 0..1 (1 = 45 degrees or steeper) |
| `COLOR.b` | wetness 0..1: 1 at the river and lake shores, fading over about 900 m, plus some large-scale moisture variation |
| `COLOR.a` | always 1 |
| `CUSTOM0` (RGBA float) | unclamped: height in metres, slope (rise over run), wetness, water depth in metres (0 above water) |

In a spatial shader: `COLOR` as usual, `CUSTOM0` for the raw values. Skirt
vertices copy the data of the edge vertex above them. Typical uses: rock on
`COLOR.g > 0.35`, lush grass and reeds on high `COLOR.b`, sand or mud where
`CUSTOM0.w` is small but positive, drier colours with height.

## Tracks (`track_mesh.gd`)

Each straight sim track is drawn as a ballast bed (its sides meet the
ground beside the track), two rails and sleepers (a `MultiMesh`), following
the terrain every 10 m; over water it stays 1.5 m above the surface. The
simulation still measures tracks in 2D. Materials `M_Ballast`, `M_Rail`,
`M_Sleeper` (and `M_Water` for the water surface) are plain
`StandardMaterial3D`s that `ArtStyle` repaints; save
`client/art/materials/M_<name>.tres` to restyle one.

## Trains (`trains.gd`, `rail_paths.gd`)

`game/world_labels.gd` creates a `Trains` node. Every sim train is drawn
as the steam locomotive (`assets/vehicles/locomotive_steam.glb`) and
covered wagons (`wagon_covered.glb`), one wagon per 40 passengers of
`train_capacity()` (2 to 6; 3 today), at the models' real size (10.2 m
and 8.3 m over buffers, standard gauge).

- `RailPaths` holds the network as rail-top paths: every straight track
  with its rail height sampled like `track_mesh.gd` draws it, so wheels sit
  exactly on the rails, over hills and water crossings too. `advance()`
  walks along the rails across nodes.
- The sim point of a train (`trains()` gives `track`, `forward`, `x`, `y`)
  is the front of the train. The cars trail it along the tracks the train
  came from (straightest continuation otherwise). Each car stands on its
  front and rear axle, both on the rails, so it turns and pitches with
  them; wheels turn with the distance travelled, the side rods circle.
- The drawn train chases the sim point (smooth between ticks). When a
  train turns round, its locomotive runs round to the other end and the
  train eases out of its old place, so no car stands past a buffer stop.
- Rendering is instanced: one `MultiMeshInstance3D` per model part for all
  trains (`Loco_Body`, `Wagon_Wheelset_0`, ...), refilled every frame for
  cars within `draw_distance` (4.5 km) of the camera; standing trains keep
  their places, far ones move 4 times a second. The parts use the models'
  `M_<Asset>_<Mesh>` materials as `ArtStyle` painted them.
- Each train has a node `Train_<id>` with a `Node3D` per car (`Loco`,
  `Wagon1`, ...) at the car's origin (rail top, centre, facing -Z):
  `cars_of(id)`, `train_position(id)` (the middle, for labels).

Without the model files (a clone without Git LFS) coloured boxes stand in.

## Stations (`stations.gd`)

A `Stations` node puts `assets/buildings/station_small.glb` at every
station node, its track axis along the track through the node (the
straightest pair of tracks there, or the only one at a terminus) and the
platform beside it. The platform is lengthened with copies of the model's
`Platform` mesh so a whole train fits: centred on a through station (trains
stop with their front at the node), running into the line from a terminus,
where the building stands at the buffer stop end. Every platform piece sits
on the rail top at its place, following the grade, on a stone plinth
(`M_Station_Small_Plinth`) reaching down to the ground. The platform goes
on the side without other tracks, else the side facing the nearest town.
Stations are rebuilt when the tracks at their node change. The waiting
passengers label floats above (world_labels).

Checking: `tests/smoke_build.gd` runs a train round a bend over hills and
checks every axle against the rails. `tools/train_shots.gd` builds a line
between two towns and takes close-ups of the train on the bend and at the
station:

```
xvfb-run -a -s "-screen 0 1920x1080x24" godot --resolution 1920x1080 \
    --path client --script res://tools/train_shots.gd -- --out /tmp/train
```

## Towns (`towns*.gd`)

`game/world_labels.gd` creates a `Towns` node (`towns.gd`) and calls
`sync()` on every refresh; it builds any town that is new or whose name,
position or population changed. Each town is a node `Town_<name>` at the town
centre with four merged meshes:

| Child | Content | Visible |
| --- | --- | --- |
| `Ground` | streets, square, yards, fields (follow the ground) | always |
| `Buildings` | walls, roofs, foundations | up to 2.6 km (`DETAIL_END`) |
| `Details` | windows, doors, chimneys | up to 1.5 km (`OPENINGS_END`) |
| `Cluster` | one box per building, spires kept | beyond 2.6 km |

The name and population label floats 75 m above the centre (world_labels).

### Layout (`towns_layout.gd`)

`TownsLayout.generate(center, name, population)` is deterministic: the seed
is a hash of the name and the rounded centre, and it uses only its own
`RandomNumberGenerator`, so every client builds the same town. It returns
plain dictionaries (see the doc comment):

- a paved **square** with the **church** (nave and tower with a copper spire)
  in it and, in towns of 2000+, a town hall on one side,
- 3 to 5 **main streets** leaving the square, continued as country roads out
  through the fields,
- **cross streets** between neighbouring main streets, at a different
  distance in every sector (an inner and an outer one in bigger towns), and
  organic **lanes** branching off, which stop at or join the next street,
- **buildings** along the street frontage, chosen by distance from the
  centre: 3 to 4 storey apartment blocks around the square in towns (2 to 3
  storeys in smaller ones), terraced row houses, family houses with gardens,
  barns and workshops at the edge; old-town houses get rear wings,
- **yards** behind houses, and a patchwork of **fields** (strips of crops,
  a differently turned grid in every sector between main streets),
- a **station plot** (`station_plot`, 200 x 50 m, in the widest gap between
  main streets, about 90 m from the centre) kept free of buildings and yards
  for a future station. `Towns.layout(i)["station_plot"]` gives it.

Size scales with population: the built-up radius is about 150 m at 500
people (a village of about 50 houses) and 400 m at 5000 (about 580 buildings,
dense centre). Fields reach about 500 m beyond that; `game/world_gen.gd`
keeps towns at least 2 km apart so neighbours do not overlap.

### Meshes and materials (`towns_mesh.gd`)

`TownsMesh.build(layout, sim)` makes the four meshes, one surface per
material. Buildings stand level at their highest corner with a stone
foundation down to the lowest corner; streets, yards and fields are
resampled every 8 to 30 m so they follow the ground, each layer a few
centimetres above the one below (fields < yards < sidewalks < streets <
square).

Materials are plain `StandardMaterial3D`s named `M_town_*`, shared by all
towns (`TownsMesh.material(name, colour)`):

| Group | Names |
| --- | --- |
| walls | `M_town_wall_cream`, `_ochre`, `_white`, `_salmon`, `_sage`, `_grey`, `_brick`, `_timber`, `_church` |
| roofs | `M_town_roof_terracotta`, `_red`, `_brown`, `_slate`, `_clay`, `_copper` (spires) |
| details | `M_town_window`, `M_town_door`, `M_town_foundation`, `M_town_chimney` |
| paving | `M_town_street_main`, `M_town_street_cobble`, `M_town_street_gravel`, `M_town_sidewalk`, `M_town_square` |
| green | `M_town_yard_lawn`, `_garden`, `_beds`, `M_town_field_wheat`, `_barley`, `_young`, `_potato`, `_ploughed`, `_rapeseed`, `_meadow` |

`ArtStyle` repaints them with the painterly shader in their colour; to
restyle one, save `client/art/materials/M_town_<name>.tres` and it is used
instead.

### Checking

- `tests/towns.gd` (headless): the layout is deterministic, the building
  count grows with population, nothing is built on the station plot or a
  street, and the game scene loads with every town drawn. Prints `TOWNS OK`.
- `tools/towns_screenshot.gd`: screenshots of one town from given distances
  and angles with a camera of its own, e.g.

  ```
  xvfb-run -a -s "-screen 0 1920x1080x24" godot --path client \
      --script res://tools/towns_screenshot.gd -- --out /tmp/town \
      --town -1 --views 400:40:30,2000:40:30
  ```
