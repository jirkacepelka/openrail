// Painterly surface for objects (trains, buildings, props).
// Stepped, warm key light with a saturated terminator, cool shadows from the
// ambient light, brush-stroke value/hue variation and a crisp rim light.
shader_type spatial;
render_mode cull_back, diffuse_lambert, specular_disabled;

#include "res://art/shaders/painterly_common.gdshaderinc"

group_uniforms paint;
uniform vec4 albedo : source_color = vec4(0.8, 0.3, 0.2, 1.0);
uniform sampler2D albedo_texture : source_color, filter_linear_mipmap, repeat_enable, hint_default_white;
uniform bool use_uv_texture = false;
// Give each MultiMesh instance (e.g. each tree) one of three colours, picked
// from its position; `albedo` is ignored then.
uniform bool vary_per_instance = false;
uniform vec4 instance_color_a : source_color = vec4(0.34, 0.52, 0.24, 1.0);
uniform vec4 instance_color_b : source_color = vec4(0.46, 0.54, 0.22, 1.0);
uniform vec4 instance_color_c : source_color = vec4(0.28, 0.46, 0.30, 1.0);
// Cut-out foliage and similar: pixels with alpha below this are discarded.
uniform float alpha_scissor : hint_range(0.0, 1.0) = 0.5;
// World units per brush pattern repeat is 1 / brush_scale.
uniform float brush_scale = 0.08;
uniform float value_jitter : hint_range(0.0, 1.0) = 0.1;
uniform float hue_jitter : hint_range(0.0, 0.2) = 0.01;

group_uniforms light;
uniform float bands : hint_range(1.0, 6.0, 1.0) = 2.0;
uniform float band_softness : hint_range(0.0, 0.5) = 0.06;
uniform float terminator_noise : hint_range(0.0, 1.0) = 0.12;
// Colour the light takes on right at the light/shadow edge (a warm, slightly saturated edge).
uniform vec4 terminator_color : source_color = vec4(1.0, 0.72, 0.5, 1.0);
uniform float terminator_width : hint_range(0.01, 1.0) = 0.3;
uniform float light_strength = 1.0;

group_uniforms rim;
uniform vec4 rim_color : source_color = vec4(1.0, 0.97, 0.9, 1.0);
uniform float rim_strength : hint_range(0.0, 4.0) = 0.7;
uniform float rim_width : hint_range(0.0, 1.0) = 0.22;

group_uniforms highlight;
uniform float gloss : hint_range(0.8, 1.0) = 0.992;
uniform float highlight_strength : hint_range(0.0, 2.0) = 0.12;

varying vec3 world_pos;
varying vec3 world_normal;
varying vec3 instance_tint;

void vertex() {
	if (vary_per_instance) {
		vec2 origin = MODEL_MATRIX[3].xz;
		float r = or_hash(floor(origin * 3.0) * 0.013);
		float v = 0.86 + 0.26 * or_hash(floor(origin * 3.0) * 0.017 + 0.5);
		instance_tint = (r < 0.55 ? instance_color_a.rgb : r < 0.8 ? instance_color_b.rgb : instance_color_c.rgb) * v;
	} else {
		instance_tint = vec3(1.0);
	}
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	float brush = or_brush_triplanar(world_pos, world_normal, brush_scale);
	vec4 base = albedo;
	if (use_uv_texture) {
		base *= texture(albedo_texture, UV);
	}
	if (vary_per_instance) {
		base.rgb = instance_tint;
	}
	ALPHA = base.a;
	ALPHA_SCISSOR_THRESHOLD = alpha_scissor;
	ALBEDO = or_paint_albedo(base.rgb, brush, value_jitter, hue_jitter);
	ROUGHNESS = 1.0;
	METALLIC = 0.0;
}

void light() {
	float brush = or_brush_triplanar(world_pos * 1.7, world_normal, brush_scale);
	float ndl = dot(NORMAL, LIGHT);
	float lit = or_toon_ramp(ndl, ATTENUATION, brush, terminator_noise, bands, band_softness);
	// The first lit band takes on the terminator colour, higher bands go neutral.
	vec3 tint = mix(terminator_color.rgb, vec3(1.0), smoothstep(0.0, terminator_width, lit));
	DIFFUSE_LIGHT += LIGHT_COLOR / PI * lit * tint * light_strength;

	// Rim: bright only on the side that faces away from the camera toward the light.
	float fres = 1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0);
	float rim = smoothstep(1.0 - rim_width, 1.0 - rim_width + 0.05, fres);
	float behind = clamp(dot(-VIEW, LIGHT) * 0.5 + 0.5, 0.0, 1.0);
	SPECULAR_LIGHT += LIGHT_COLOR / PI * rim * behind * rim_strength * rim_color.rgb * ATTENUATION;

	// Small painted highlight instead of physically based specular.
	vec3 h = normalize(LIGHT + VIEW);
	float spec = smoothstep(gloss - 0.01, gloss + 0.01, dot(NORMAL, h)) * step(0.0, ndl) * SPECULAR_AMOUNT;
	SPECULAR_LIGHT += LIGHT_COLOR / PI * spec * highlight_strength * ATTENUATION;
}
