# OpenRail art style

**Česky:** OpenRail má vypadat jako malovaný obraz, inspirovaný vizuálem
animovaného seriálu Arcane: ručně malované textury, stylizované teplé světlo
se studenými stíny, barevné "tušové" obrysy a jemná zrnitost plátna. Tento
dokument popisuje pravidla stylu a jak je používat v Godotu a Blenderu.
Z Arcane bereme jen způsob malby a svícení, ne architekturu, prostředí ani
motivy seriálu: domy, vozidla a krajina mají vlastní, realističtější design.

![Style preview scene](img/style-preview.png)

*`client/art/style_preview.tscn`, rendered with `client/tools/screenshot.gd`.*

We take inspiration only from Arcane's *rendering technique* (painted
textures, graphic lighting, colour-rich shadows, coloured ink lines). Its
architecture, setting, technology and motifs are out of scope: OpenRail's
buildings, vehicles and landscapes follow their own, real-world-grounded
design, just painted this way. We don't copy its characters, locations,
logos or assets; everything in OpenRail is our own and CC BY-SA 4.0.

## Pillars

1. **Painted, not photographed.** Surfaces read as brushwork: hand-painted
   albedo, value and hue shifting inside a colour, no photo textures, no
   normal-map micro detail.
2. **Graphic light.** Light falls in two or three clear steps. The edge
   between light and shadow is warm and saturated; shadows are cool
   (blue-violet), never grey or black.
3. **Ink with colour.** Silhouettes and creases get a thin, slightly wobbly
   line made of a darkened version of the colour underneath, not pure black.
4. **Golden hour by default.** Low warm sun, cool sky light, a hazy warm
   horizon. The palette is warm brass/copper/cream against teal and violet.
5. **Readable first.** It is a tycoon game: trains, tracks and stations must
   stay readable from far away. Lines fade with distance, the ground stays
   calmer than the things on it.

## Palette

`ArtStyle.PALETTE` in `client/art/art_style.gd` is the source of truth.

| Name        | Use                                   | Colour                   |
|-------------|---------------------------------------|--------------------------|
| `ink`       | lines, dark metal, rails              | `#1F1424`                |
| `soot`      | track bed, chimneys, tree trunks      | `#38333D`                |
| `brass`     | trims, rich buildings, lamps          | `#C79447`                |
| `copper`    | roofs, locomotive details             | `#B85C38`                |
| `cream`     | plaster walls, lit highlights         | `#EDD9B3`                |
| `teal`      | industrial accents, rolling stock     | `#29807A`                |
| `violet`    | shadows, night, special effects       | `#8C40B3`                |
| `glow_blue` | emissive lamps, UI highlights         | `#4DBFF2`                |
| `signal_red`| signals, locomotives, warnings        | `#C72E24`                |
| `meadow`    | grass, foliage                        | `#6B854D`                |

Saturated colours are for small accents (signals, trims, glow); large areas
(walls, ground, roofs seen from above) stay in the muted versions.

## How it works in the client

Everything lives in `client/art/`:

- `art_style.tscn` / `art_style.gd`: drop this scene into a level. It brings
  the WorldEnvironment (painted sky, cool ambient, AgX tonemap, glow, fog),
  a warm key light (`Sun`) and a cool `RimLight`, and removes other
  environments and directional lights in the scene. It attaches the
  post-process to the active camera and repaints materials (below).
- `shaders/painterly.gdshader`: objects. Stepped toon ramp with a
  brush-broken terminator, warm terminator colour, world-space brush strokes
  (no UVs needed), rim light, a small painted highlight. With
  `use_uv_texture` it multiplies a hand-painted albedo texture.
- `shaders/painterly_ground.gdshader`: terrain. Large colour washes plus
  brush strokes that calm down with distance.
- `shaders/painted_sky.gdshader`: sky gradient, painted two-tone clouds,
  sun glow.
- `shaders/post_painterly.gdshader`: full screen. Kuwahara paint filter, ink
  lines from depth and normals, colour grade (saturation, contrast, cool
  shadows / warm highlights), canvas grain, vignette.
- `shaders/painterly_common.gdshaderinc`: shared noise, brush and ramp code.
- `style_preview.tscn`: a sandbox village for judging changes.

### Materials

Gameplay code that builds meshes can call `ArtStyle.paint(color)` for a
shared painterly material. It can also keep using a `StandardMaterial3D`:
ArtStyle converts those automatically (keeping colour and albedo texture),
including meshes added at runtime. Unshaded materials become ink, except
very bright ones (lamps, markers), which are left glowing.

Imported glTF models are converted per surface. A material whose name
starts with `M_` is replaced by `client/art/materials/<name>.tres` when that
file exists; otherwise it gets the automatic conversion. That's how a model
from `openrail-assets` gets a hand-tuned look without touching the model.

### Main knobs

| Where | Knob | Effect |
|-------|------|--------|
| painterly | `bands`, `band_softness` | number of light steps and how hard they are |
| painterly | `terminator_color`, `terminator_width` | colour of the light/shadow edge |
| painterly | `value_jitter`, `hue_jitter`, `brush_scale` | strength and size of brush variation |
| painterly | `rim_strength`, `rim_width` | rim light |
| post | `kuwahara_radius`, `kuwahara_mix` | how "painted" the whole frame looks (cost grows with radius²) |
| post | `line_width`, `line_strength`, `ink_keeps_color` | ink lines |
| post | `line_fade_distance` | camera distance where lines disappear |
| post | `shadow_tint`, `highlight_tint`, `split_tone_strength` | colour grade |
| Environment | `ambient_light_color` | colour of all shadows |
| Sun | `light_color`, rotation | time of day |

## Rules for assets (Blender)

- **Textures:** hand-painted albedo only, one texture per material, no
  normal, roughness or metal maps (the shader ignores them). Paint light
  variation and wear into the albedo but no baked shadows; the engine lights
  it. Visible brush strokes are good.
- **Texel density:** about 256 px per metre for vehicles and props seen up
  close, 64 to 128 px per metre for buildings and terrain tiles. Power-of-two
  sizes.
- **Shapes:** chunky, slightly exaggerated silhouettes and bevels; the ink
  lines come from silhouettes and sharp creases, so keep hard edges where you
  want a line and smooth normals where you don't.
- **Materials:** name them `M_<Thing>_<Part>` (for example `M_Loco_Body`).
  Keep them simple Principled BSDF with just the albedo texture; the client
  replaces them by name.
- **Orientation and scale:** metres, vehicles face −Z, origin at the top of
  the rail.
- **Foliage:** alpha-tested cards (alpha clip in Blender) are fine; they keep
  their alpha threshold after conversion.

## Previewing without the editor

```sh
cargo build -p openrail-gdext   # only needed for main.tscn
godot --path client --script res://tools/screenshot.gd -- \
    --scene res://art/style_preview.tscn --out /tmp/preview.png \
    --look-from 60,45,130 --look-at -20,5,0
```

On a machine without a GPU this works under `xvfb-run` with Mesa's software
Vulkan (`VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/lvp_icd.json`); that's how
the screenshot above was made.

## Performance notes

The post-process costs one Kuwahara pass (`(2r+1)²` samples, 49 at the
default radius 3) plus 10 depth/normal taps per pixel, which is fine on
desktop GPUs at 1080p. On low-end hardware lower `kuwahara_radius` to 2 or
set `post_process = false` on ArtStyle. It needs the Forward+ renderer
(normal-roughness buffer).
