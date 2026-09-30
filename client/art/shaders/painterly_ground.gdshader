// Painterly terrain: large washes of colour broken up by brush strokes,
// lit with the same stepped ramp as painterly.gdshader.
shader_type spatial;
render_mode cull_back, diffuse_lambert, specular_disabled;

#include "res://art/shaders/painterly_common.gdshaderinc"

group_uniforms paint;
uniform vec4 color_meadow : source_color = vec4(0.42, 0.52, 0.30, 1.0);
uniform vec4 color_dry : source_color = vec4(0.70, 0.60, 0.36, 1.0);
uniform vec4 color_moss : source_color = vec4(0.24, 0.36, 0.28, 1.0);
// Size of the colour washes, in world units.
uniform float wash_size = 900.0;
uniform float brush_scale = 0.02;
uniform float value_jitter : hint_range(0.0, 1.0) = 0.3;
uniform float hue_jitter : hint_range(0.0, 0.2) = 0.03;

group_uniforms light;
uniform float bands : hint_range(1.0, 6.0, 1.0) = 3.0;
uniform float band_softness : hint_range(0.0, 0.5) = 0.2;
uniform float terminator_noise : hint_range(0.0, 1.0) = 0.25;
uniform vec4 terminator_color : source_color = vec4(1.0, 0.55, 0.35, 1.0);
uniform float terminator_width : hint_range(0.01, 1.0) = 0.45;
uniform float light_strength = 1.0;

varying vec3 world_pos;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 p = world_pos.xz / wash_size;
	float wash_a = smoothstep(0.35, 0.65, or_fbm(p));
	float wash_b = smoothstep(0.45, 0.7, or_fbm(p * 1.7 + vec2(31.0, 7.0)));
	vec3 base = mix(color_meadow.rgb, color_dry.rgb, wash_a);
	base = mix(base, color_moss.rgb, wash_b * 0.8);
	float brush = or_brush(world_pos.xz * brush_scale, 0.35);
	// A second, coarser layer of strokes so it doesn't read as uniform noise.
	brush = mix(brush, or_brush(world_pos.xz * brush_scale * 0.23, 1.2), 0.5);
	// Fine strokes up close, fading out with distance so the horizon doesn't shimmer.
	float near = 1.0 - smoothstep(150.0, 900.0, length(world_pos - CAMERA_POSITION_WORLD));
	brush = mix(brush, or_brush(world_pos.xz * brush_scale * 6.0, 0.5), 0.35 * near);
	brush = mix(0.5, brush, mix(0.5, 1.0, near));
	ALBEDO = or_paint_albedo(base, brush, value_jitter, hue_jitter);
	ROUGHNESS = 1.0;
	METALLIC = 0.0;
}

void light() {
	float brush = or_brush(world_pos.xz * brush_scale * 1.3, 0.8);
	float lit = or_toon_ramp(dot(NORMAL, LIGHT), ATTENUATION, brush, terminator_noise, bands, band_softness);
	vec3 tint = mix(terminator_color.rgb, vec3(1.0), smoothstep(0.0, terminator_width, lit));
	DIFFUSE_LIGHT += LIGHT_COLOR / PI * lit * tint * light_strength;
}
