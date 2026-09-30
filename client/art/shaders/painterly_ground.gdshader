// Painterly terrain. Smooth washes of grass that blend into dirt and rock by
// slope and height, a patchwork of fields with hedges, darker forest floor
// under woods, and brush strokes that only show up close to the camera.
// Lit with the same stepped ramp as painterly.gdshader.
//
// Works on the flat ground plane and on real terrain meshes: slope comes from
// the surface normal, height from the world position. ArtStyle's Vegetation
// node passes its forest/farmland mask in `veg_mask` so fields and woods line
// up with the trees it plants.
shader_type spatial;
render_mode cull_back, diffuse_lambert, specular_disabled;

#include "res://art/shaders/painterly_common.gdshaderinc"

group_uniforms grass;
uniform vec4 color_lush : source_color = vec4(0.36, 0.52, 0.24, 1.0);
uniform vec4 color_dry : source_color = vec4(0.60, 0.60, 0.33, 1.0);
uniform vec4 color_cool : source_color = vec4(0.28, 0.46, 0.30, 1.0);
uniform vec4 color_forest_floor : source_color = vec4(0.22, 0.36, 0.19, 1.0);
// Size of the grass colour washes, in metres.
uniform float wash_size = 1400.0;

group_uniforms slopes;
uniform vec4 color_dirt : source_color = vec4(0.58, 0.45, 0.32, 1.0);
uniform vec4 color_rock : source_color = vec4(0.56, 0.55, 0.56, 1.0);
// Slope (1 - normal.y) where dirt and then bare rock take over.
uniform float dirt_slope = 0.12;
uniform float rock_slope = 0.3;
// Heights (metres) where the grass turns drier and rockier.
uniform float highland_start = 90.0;
uniform float highland_end = 240.0;
// Tilts normals away from the vertical so gentle hills catch light and
// shade like a painter would exaggerate them (1 = physically right).
uniform float relief = 3.5;
uniform vec4 color_slope_shade : source_color = vec4(0.26, 0.42, 0.28, 1.0);

group_uniforms fields;
uniform vec4 color_wheat : source_color = vec4(0.78, 0.62, 0.30, 1.0);
uniform vec4 color_young : source_color = vec4(0.42, 0.56, 0.25, 1.0);
uniform vec4 color_ploughed : source_color = vec4(0.56, 0.41, 0.29, 1.0);
uniform vec4 color_fallow : source_color = vec4(0.62, 0.58, 0.36, 1.0);
uniform vec4 color_hedge : source_color = vec4(0.22, 0.38, 0.22, 1.0);
uniform float field_size = 110.0;
uniform float furrow_spacing = 7.0;
uniform float hedge_width = 4.0;

group_uniforms masks;
// R = forest density, G = farmland, laid over the world rectangle
// veg_mask_rect (x, z of the corner, width, depth).
uniform sampler2D veg_mask : filter_linear, repeat_disable, hint_default_black;
uniform vec4 veg_mask_rect = vec4(-8192.0, -8192.0, 16384.0, 16384.0);
uniform bool use_veg_mask = false;

group_uniforms paint;
uniform float brush_scale = 0.02;
uniform float value_jitter : hint_range(0.0, 1.0) = 0.12;
uniform float hue_jitter : hint_range(0.0, 0.2) = 0.015;
// Up to this distance the ground gets fine strokes (grass tufts, clods).
uniform float detail_distance = 600.0;

group_uniforms light;
uniform float bands : hint_range(1.0, 6.0, 1.0) = 3.0;
uniform float band_softness : hint_range(0.0, 0.5) = 0.12;
uniform float terminator_noise : hint_range(0.0, 1.0) = 0.1;
uniform vec4 terminator_color : source_color = vec4(1.0, 0.75, 0.55, 1.0);
uniform float terminator_width : hint_range(0.01, 1.0) = 0.45;
uniform float light_strength = 1.0;

varying vec3 world_pos;
varying vec3 world_normal;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

vec2 masks_at(vec2 xz, float fw) {
	// Beyond the mask (or without one): a few fields and woods from noise.
	vec2 p = xz / 2600.0;
	float farm = smoothstep(0.52, 0.6, or_fbm_soft(p, fw / 2600.0, 3));
	float forest = smoothstep(0.56, 0.62, or_fbm_soft(p * 1.3 + vec2(5.2, 1.3), fw / 2000.0, 3));
	vec2 m = vec2(forest * (1.0 - farm), farm);
	if (use_veg_mask) {
		vec2 uv = (xz - veg_mask_rect.xy) / veg_mask_rect.zw;
		vec2 inside = smoothstep(vec2(0.0), vec2(0.03), uv) * smoothstep(vec2(0.0), vec2(0.03), 1.0 - uv);
		m = mix(m, texture(veg_mask, uv).rg, inside.x * inside.y);
	}
	return m;
}

vec3 field_color(vec2 xz, float fw, out float hedge) {
	// Farmland is split into estates (large Voronoi cells), each with its own
	// orientation, then into long strips of fields like real field systems.
	vec2 warp = vec2(or_noise(xz / 400.0), or_noise(xz / 400.0 + 7.7)) - 0.5;
	vec3 estate = or_voronoi(xz / (field_size * 4.0) + warp * 0.25);
	float ang = or_hash(estate.yz + 1.3) * PI;
	vec2 dir = vec2(cos(ang), sin(ang));
	vec2 q = vec2(dot(xz, dir), dot(xz, vec2(-dir.y, dir.x)));
	// Rows of fields; each row has its own field width and offset.
	float row_len = field_size * 1.4;
	float row = floor(q.y / field_size);
	float w = field_size * (0.35 + 0.9 * or_hash(vec2(row, estate.y)));
	float col_q = q.x / w + or_hash(vec2(row + 4.1, estate.z)) * 3.0;
	float col = floor(col_q);
	vec2 id = vec2(row, col) + estate.yz * 13.0;
	float edge_m = min(
		min(fract(q.y / field_size), 1.0 - fract(q.y / field_size)) * field_size,
		min(fract(col_q), 1.0 - fract(col_q)) * w);
	edge_m = min(edge_m, estate.x * field_size * 4.0);
	float r = or_hash(id + 3.1);
	float r2 = or_hash(id + 11.7);
	vec3 crop = r < 0.3 ? color_wheat.rgb
		: r < 0.58 ? color_young.rgb
		: r < 0.78 ? color_ploughed.rgb
		: color_fallow.rgb;
	crop *= 0.93 + 0.14 * r2;
	// Furrows along the field.
	float along = (r2 < 0.5 ? q.y : q.x) / furrow_spacing;
	float stripes = mix(0.5 + 0.5 * sin(along * TAU), 0.5, smoothstep(0.1, 0.35, fw / furrow_spacing));
	crop *= 0.94 + 0.09 * stripes;
	// Hedges and grass margins, soft so they don't alias from far away.
	float hw = max(hedge_width, fw * 1.2);
	hedge = (1.0 - smoothstep(hw * 0.5, hw, edge_m)) * (1.0 - smoothstep(4.0, 12.0, fw));
	hedge *= step(0.4, or_hash(id + 5.3)); // not every field has a hedge
	return crop;
}

void fragment() {
	vec2 xz = world_pos.xz;
	// Metres per pixel here, to fade detail that would only alias.
	float fw = max(length(fwidth(xz)), 0.001);
	float dist = length(world_pos - CAMERA_POSITION_WORLD);

	// 1. Grass: big, soft, domain-warped washes between lush, dry and cool greens.
	vec2 wp = xz / wash_size;
	vec2 warp = vec2(or_fbm_soft(wp * 0.7, fw / wash_size, 3), or_fbm_soft(wp * 0.7 + 4.1, fw / wash_size, 3));
	float wash_a = or_fbm_soft(wp + warp * 1.2, fw / wash_size, 5);
	float wash_b = or_fbm_soft(wp * 1.9 + warp + vec2(31.0, 7.0), fw / wash_size * 1.9, 4);
	vec3 base = mix(color_lush.rgb, color_dry.rgb, smoothstep(0.38, 0.68, wash_a));
	base = mix(base, color_cool.rgb, smoothstep(0.5, 0.75, wash_b) * 0.7);

	// Height: drier and paler grass up high.
	float highland = smoothstep(highland_start, highland_end, world_pos.y);
	base = mix(base, mix(color_dry.rgb, color_rock.rgb, 0.35), highland * 0.6);

	// 2. Fields and woods from the vegetation mask.
	vec2 m = masks_at(xz, fw);
	float slope = 1.0 - clamp(world_normal.y, 0.0, 1.0);
	float farm = m.g * (1.0 - smoothstep(dirt_slope * 0.6, dirt_slope, slope));
	if (farm > 0.001) {
		float hedge;
		vec3 crop = field_color(xz, fw, hedge);
		base = mix(base, crop, farm);
		base = mix(base, color_hedge.rgb, hedge * farm * 0.85);
	}
	// Woods: the trees stop at visibility range, so paint a canopy of crowns
	// underneath that carries the forest out to the horizon.
	float crowns = or_fbm_soft(xz / 9.0, fw / 9.0, 3);
	vec3 canopy = mix(color_forest_floor.rgb, color_forest_floor.rgb * vec3(1.35, 1.3, 1.1), smoothstep(0.45, 0.65, crowns));
	base = mix(base, canopy, smoothstep(0.15, 0.6, m.r));

	// 3. Slopes: deeper, cooler grass as it steepens, then dirt, then rock,
	// with a ragged boundary.
	base = mix(base, color_slope_shade.rgb, smoothstep(0.02, dirt_slope, slope) * 0.55 * (1.0 - farm));
	float ragged = (or_fbm_soft(xz / 40.0, fw / 40.0, 3) - 0.5) * 0.12;
	float dirt = smoothstep(dirt_slope - 0.05, dirt_slope + 0.05, slope + ragged);
	float rock = smoothstep(rock_slope - 0.06, rock_slope + 0.06, slope + ragged + highland * 0.12);
	base = mix(base, color_dirt.rgb, dirt);
	base = mix(base, color_rock.rgb, rock);

	// 4. Brush strokes: broad everywhere, fine only near the camera.
	float near = 1.0 - smoothstep(detail_distance * 0.4, detail_distance, dist);
	float brush = or_brush(xz * brush_scale * 0.23, 1.2);
	brush = mix(0.5, brush, 1.0 - smoothstep(0.5, 2.0, fw * brush_scale * 0.23 * 4.0));
	if (near > 0.0) {
		float fine = or_brush(xz * brush_scale * 8.0, 0.5) * 0.6 + or_brush(xz * brush_scale * 30.0, 2.1) * 0.4;
		brush = mix(brush, fine, 0.55 * near);
	}
	ALBEDO = or_paint_albedo(base, brush, value_jitter, hue_jitter);
	vec3 relief_n = normalize(vec3(world_normal.x * relief, world_normal.y, world_normal.z * relief));
	NORMAL = normalize((VIEW_MATRIX * vec4(relief_n, 0.0)).xyz);
	ROUGHNESS = 1.0;
	METALLIC = 0.0;
}

void light() {
	float brush = or_brush(world_pos.xz * brush_scale * 1.3, 0.8);
	float lit = or_toon_ramp(dot(NORMAL, LIGHT), ATTENUATION, brush, terminator_noise, bands, band_softness);
	vec3 tint = mix(terminator_color.rgb, vec3(1.0), smoothstep(0.0, terminator_width, lit));
	DIFFUSE_LIGHT += LIGHT_COLOR / PI * lit * tint * light_strength;
}
