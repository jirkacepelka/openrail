// Painted sky: a warm horizon under a cool zenith, soft banded clouds made
// of brush strokes, and a glow around the sun (the first directional light).
shader_type sky;

#include "res://art/shaders/painterly_common.gdshaderinc"

uniform vec4 zenith_color : source_color = vec4(0.22, 0.34, 0.52, 1.0);
uniform vec4 horizon_color : source_color = vec4(0.96, 0.72, 0.52, 1.0);
uniform vec4 ground_color : source_color = vec4(0.32, 0.30, 0.34, 1.0);
uniform vec4 cloud_light : source_color = vec4(1.0, 0.86, 0.72, 1.0);
uniform vec4 cloud_shadow : source_color = vec4(0.55, 0.50, 0.66, 1.0);
uniform float cloud_cover : hint_range(0.0, 1.0) = 0.45;
uniform float cloud_scale = 2.2;
uniform float cloud_speed = 0.004;
uniform vec4 sun_glow_color : source_color = vec4(1.0, 0.7, 0.45, 1.0);
uniform float sun_glow_size : hint_range(0.0, 1.0) = 0.25;
uniform float sun_disc_size : hint_range(0.0, 0.1) = 0.02;
uniform float energy = 1.0;

void sky() {
	vec3 dir = EYEDIR;
	float h = dir.y;
	vec3 col = mix(horizon_color.rgb, zenith_color.rgb, smoothstep(-0.02, 0.55, h));
	col = mix(col, ground_color.rgb, smoothstep(0.0, -0.15, h));

	vec3 sun_dir = LIGHT0_ENABLED ? LIGHT0_DIRECTION : vec3(0.0, 1.0, 0.0);
	float sun_dot = dot(dir, sun_dir);

	if (h > 0.0) {
		// Project onto a flat cloud layer so clouds shrink toward the horizon.
		vec2 cp = dir.xz / (h + 0.12) * cloud_scale + vec2(TIME * cloud_speed, 0.0);
		float c = or_brush(cp, 0.15);
		float mask = smoothstep(1.0 - cloud_cover, 1.0 - cloud_cover + 0.12, c);
		// Two painted tones inside the cloud: lit tops toward the sun, violet bellies.
		float lit = smoothstep(0.45, 0.7, or_brush(cp * 1.9 + vec2(3.1, 1.7), 0.15)) * 0.6
			+ 0.4 * clamp(sun_dot * 0.5 + 0.5, 0.0, 1.0);
		vec3 cloud = mix(cloud_shadow.rgb, cloud_light.rgb, step(0.5, lit));
		col = mix(col, cloud, mask * smoothstep(0.0, 0.08, h));
	}

	if (LIGHT0_ENABLED) {
		float glow = smoothstep(1.0 - sun_glow_size, 1.0, sun_dot);
		col += sun_glow_color.rgb * glow * glow * 0.8;
		col = mix(col, vec3(1.0, 0.95, 0.85) * 4.0, smoothstep(1.0 - sun_disc_size, 1.0 - sun_disc_size * 0.7, sun_dot));
	}

	COLOR = col * energy;
}
