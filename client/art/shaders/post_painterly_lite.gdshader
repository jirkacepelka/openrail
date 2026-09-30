// Light version of post_painterly.gdshader for the Mobile and Compatibility
// (OpenGL) renderers, which have no normal-roughness buffer. It keeps the
// colour grade and vignette so the palette still matches, and skips the paint
// filter and ink lines, which are also the expensive part on weak GPUs.
// ArtStyle picks this shader automatically when not running on Forward+.
shader_type spatial;
render_mode unshaded, fog_disabled, depth_draw_never, depth_test_disabled, cull_disabled, shadows_disabled;

uniform sampler2D screen_tex : hint_screen_texture, filter_linear, repeat_disable;

group_uniforms grade;
uniform float saturation : hint_range(0.0, 2.0) = 1.2;
uniform float contrast : hint_range(0.5, 2.0) = 1.1;
uniform vec4 shadow_tint : source_color = vec4(0.72, 0.82, 1.0, 1.0);
uniform vec4 highlight_tint : source_color = vec4(1.0, 0.95, 0.86, 1.0);
uniform float split_tone_strength : hint_range(0.0, 1.0) = 0.35;

group_uniforms canvas;
uniform float vignette_strength : hint_range(0.0, 1.0) = 0.12;

void vertex() {
	POSITION = vec4(VERTEX.xy, 1.0, 1.0);
}

void fragment() {
	vec2 uv = SCREEN_UV;
	// On these renderers the value read back is already sRGB-decoded once more
	// than the output expects; re-encode it, or the whole frame turns dark.
	vec3 col = pow(max(texture(screen_tex, uv).rgb, vec3(0.0)), vec3(1.0 / 2.2));

	// Same grade as post_painterly.gdshader (keep the two in sync), with a bit
	// more saturation and contrast to make up for the simpler lighting.
	float lum = dot(col, vec3(0.2126, 0.7152, 0.0722));
	col = mix(vec3(lum), col, saturation);
	col = max(col, vec3(0.0));
	col = pow(col / 0.18, vec3(contrast)) * 0.18;
	float tone = smoothstep(0.02, 0.6, lum);
	vec3 split = mix(shadow_tint.rgb, highlight_tint.rgb, tone);
	col *= mix(vec3(1.0), split / max(dot(split, vec3(0.333)), 0.001), split_tone_strength);

	vec2 vc = uv - 0.5;
	col *= 1.0 - vignette_strength * smoothstep(0.25, 0.75, dot(vc, vc) * 2.0);

	ALBEDO = col;
	ALPHA = 1.0;
}
