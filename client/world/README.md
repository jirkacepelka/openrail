# World: towns and ground

Client-side scenery generated from the simulation's state. Nothing here
changes the simulation or its hash: it only reads `SimWorld` getters.

## Ground height (`ground.gd`)

`Ground.height_at(sim, x, z)` is the one place that knows the ground height
at Godot (x, z) (sim (x, y)). Everything placed on the land asks it. Until the
terrain lands, the file is a fallback that returns 0 (flat world); the
terrain replaces it with the real height field and the towns follow.

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
