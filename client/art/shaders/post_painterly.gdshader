// Full-screen painterly post-process, drawn on a quad parented to the camera
// (ArtStyle sets it up). In order:
//   1. Kuwahara filter: flattens detail into brush-like patches of colour.
//   2. Ink lines from depth and normal edges, tinted by the colour underneath
//      (Arcane's lines are dark paint, not black), wobbling slightly.
//   3. Colour grade: saturation, contrast, cool shadows / warm highlights.
//   4. Canvas grain and a vignette.
// Everything runs in linear HDR, before Godot's tonemapper and glow.
shader_type spatial;
render_mode unshaded, fog_disabled, depth_draw_never, depth_test_disabled, cull_disabled, shadows_disabled;

#include "res://art/shaders/painterly_common.gdshaderinc"

uniform sampler2D screen_tex : hint_screen_texture, filter_linear, repeat_disable;
uniform sampler2D depth_tex : hint_depth_texture, filter_nearest, repeat_disable;
uniform sampler2D normal_tex : hint_normal_roughness_texture, filter_nearest, repeat_disable;

group_uniforms paint;
uniform int kuwahara_radius : hint_range(0, 6) = 3;
uniform float kuwahara_mix : hint_range(0.0, 1.0) = 0.85;

group_uniforms ink;
uniform float line_width : hint_range(0.5, 4.0) = 1.3;
uniform float line_strength : hint_range(0.0, 1.0) = 0.75;
uniform vec4 ink_color : source_color = vec4(0.12, 0.08, 0.14, 1.0);
// How much of the underlying colour the ink keeps (0 = flat ink colour).
uniform float ink_keeps_color : hint_range(0.0, 1.0) = 0.35;
uniform float depth_threshold = 0.15;
uniform float normal_threshold : hint_range(0.0, 1.0) = 0.35;
uniform float line_wobble : hint_range(0.0, 3.0) = 1.0;
// Lines fade out beyond this camera distance, so the far landscape stays soft.
uniform float line_fade_distance = 6000.0;

group_uniforms grade;
uniform float saturation : hint_range(0.0, 2.0) = 1.12;
uniform float contrast : hint_range(0.5, 2.0) = 1.08;
uniform vec4 shadow_tint : source_color = vec4(0.55, 0.62, 0.9, 1.0);
uniform vec4 highlight_tint : source_color = vec4(1.0, 0.9, 0.75, 1.0);
uniform float split_tone_strength : hint_range(0.0, 1.0) = 0.5;

group_uniforms canvas;
uniform float grain_strength : hint_range(0.0, 0.3) = 0.06;
uniform float vignette_strength : hint_range(0.0, 1.0) = 0.35;

void vertex() {
	// Cover the whole screen regardless of the camera.
	POSITION = vec4(VERTEX.xy, 1.0, 1.0);
}

float linear_depth(vec2 uv, mat4 inv_proj) {
	float d = texture(depth_tex, uv).r;
	if (d <= 0.0) {
		return 1.0e6; // sky: treat as very far instead of dividing by zero
	}
	vec4 view = inv_proj * vec4(uv * 2.0 - 1.0, d, 1.0);
	float z = -view.z / view.w;
	// Near the far plane depth precision runs out: z can flip sign or become
	// infinite, and inf - inf in the edge filter would turn into NaN.
	return (z > 0.0 && z < 1.0e6) ? z : 1.0e6;
}

vec3 view_normal(vec2 uv) {
	return normalize(texture(normal_tex, uv).xyz * 2.0 - 1.0);
}

vec3 kuwahara(vec2 uv, vec2 px, int r) {
	vec3 mean[4];
	vec3 sq[4];
	for (int k = 0; k < 4; k++) {
		mean[k] = vec3(0.0);
		sq[k] = vec3(0.0);
	}
	for (int j = -r; j <= r; j++) {
		for (int i = -r; i <= r; i++) {
			vec3 c = min(texture(screen_tex, uv + vec2(float(i), float(j)) * px).rgb, vec3(8.0));
			// Quadrant index: 0 = (-,-), 1 = (+,-), 2 = (-,+), 3 = (+,+); axes belong to both.
			if (i <= 0 && j <= 0) { mean[0] += c; sq[0] += c * c; }
			if (i >= 0 && j <= 0) { mean[1] += c; sq[1] += c * c; }
			if (i <= 0 && j >= 0) { mean[2] += c; sq[2] += c * c; }
			if (i >= 0 && j >= 0) { mean[3] += c; sq[3] += c * c; }
		}
	}
	float n = float((r + 1) * (r + 1));
	vec3 best = mean[0] / n;
	float best_var = 1e20;
	for (int k = 0; k < 4; k++) {
		vec3 m = mean[k] / n;
		vec3 v = abs(sq[k] / n - m * m);
		float var = v.r + v.g + v.b;
		if (var < best_var) {
			best_var = var;
			best = m;
		}
	}
	return best;
}

void fragment() {
	vec2 uv = SCREEN_UV;
	vec2 px = 1.0 / VIEWPORT_SIZE;
	vec3 src = texture(screen_tex, uv).rgb;

	// 1. Paint.
	vec3 col = src;
	if (kuwahara_radius > 0) {
		col = mix(src, kuwahara(uv, px, kuwahara_radius), kuwahara_mix);
	}

	// 2. Ink.
	vec2 wobble = (vec2(or_noise(uv * 90.0), or_noise(uv * 90.0 + 13.7)) - 0.5) * px * line_wobble * 2.0;
	vec2 luv = uv + wobble;
	vec2 o = px * line_width;
	// Raw (reversed-Z) depth is linear in screen space across any flat surface,
	// so its second derivative is ~0 on planes, even at grazing angles, and
	// only spikes at silhouettes. Linear depth would draw lines all over a
	// ground plane seen at a shallow angle.
	float rc = texture(depth_tex, luv).r;
	float rl = texture(depth_tex, luv - vec2(o.x, 0.0)).r;
	float rr = texture(depth_tex, luv + vec2(o.x, 0.0)).r;
	float rd = texture(depth_tex, luv - vec2(0.0, o.y)).r;
	float ru = texture(depth_tex, luv + vec2(0.0, o.y)).r;
	float d2 = abs(rl + rr - 2.0 * rc) + abs(rd + ru - 2.0 * rc);
	float depth_edge = smoothstep(depth_threshold, depth_threshold * 2.0, d2 / max(rc, 1.0e-7));
	float dc = linear_depth(luv, INV_PROJECTION_MATRIX);

	vec3 nc = view_normal(luv);
	float ndiff = 0.0;
	ndiff = max(ndiff, 1.0 - dot(nc, view_normal(luv + vec2(o.x, 0.0))));
	ndiff = max(ndiff, 1.0 - dot(nc, view_normal(luv - vec2(o.x, 0.0))));
	ndiff = max(ndiff, 1.0 - dot(nc, view_normal(luv + vec2(0.0, o.y))));
	ndiff = max(ndiff, 1.0 - dot(nc, view_normal(luv - vec2(0.0, o.y))));
	float normal_edge = smoothstep(normal_threshold, normal_threshold + 0.2, ndiff);
	// The sky has no normals; only its silhouette against geometry counts.
	if (rc <= 0.0) {
		normal_edge = 0.0;
	}

	float edge = max(depth_edge, normal_edge);
	edge *= 1.0 - smoothstep(line_fade_distance * 0.5, line_fade_distance, dc);
	// Break lines up a little, like a dry brush.
	edge *= smoothstep(0.2, 0.5, or_noise(uv * vec2(260.0, 190.0)) + 0.35);
	vec3 ink = mix(ink_color.rgb, ink_color.rgb * 0.4 + col * 0.6, ink_keeps_color) * 0.5;
	col = mix(col, ink, edge * line_strength);

	// 3. Grade.
	float lum = dot(col, vec3(0.2126, 0.7152, 0.0722));
	col = mix(vec3(lum), col, saturation);
	col = max(col, vec3(0.0));
	col = pow(col / 0.18, vec3(contrast)) * 0.18;
	float tone = smoothstep(0.02, 0.6, lum);
	vec3 split = mix(shadow_tint.rgb, highlight_tint.rgb, tone);
	col *= mix(vec3(1.0), split / max(dot(split, vec3(0.333)), 0.001), split_tone_strength);

	// 4. Canvas.
	vec2 fc = FRAGCOORD.xy;
	float weave = sin(fc.x * 1.9) * sin(fc.y * 1.7) * 0.5 + 0.5;
	float grain = mix(or_hash(fc), weave, 0.5);
	col *= 1.0 + (grain - 0.5) * grain_strength;
	vec2 vc = uv - 0.5;
	col *= 1.0 - vignette_strength * smoothstep(0.25, 0.75, dot(vc, vc) * 2.0);

	ALBEDO = col;
	ALPHA = 1.0;
}
