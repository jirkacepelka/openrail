// Shared helpers for OpenRail's painterly (Arcane-inspired) look.
// See docs/art-style.md for what each knob is for.

float or_hash(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

float or_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	float a = or_hash(i);
	float b = or_hash(i + vec2(1.0, 0.0));
	float c = or_hash(i + vec2(0.0, 1.0));
	float d = or_hash(i + vec2(1.0, 1.0));
	return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

float or_fbm(vec2 p) {
	float v = 0.0;
	float a = 0.5;
	for (int i = 0; i < 4; i++) {
		v += a * or_noise(p);
		p = p * 2.03 + vec2(17.1, 9.2);
		a *= 0.5;
	}
	return v;
}

// Brush strokes: fbm squashed along one axis so it reads as long dabs of paint.
float or_brush(vec2 p, float angle) {
	float c = cos(angle);
	float s = sin(angle);
	vec2 q = mat2(vec2(c, s), vec2(-s, c)) * p;
	q.x *= 0.3;
	return or_fbm(q);
}

// World-space brush pattern projected from three axes, so models need no UVs.
float or_brush_triplanar(vec3 wp, vec3 n, float scale) {
	vec3 w = pow(abs(n), vec3(4.0));
	w /= (w.x + w.y + w.z);
	return or_brush(wp.zy * scale, 0.6) * w.x
		+ or_brush(wp.xz * scale, 0.35) * w.y
		+ or_brush(wp.xy * scale, 0.9) * w.z;
}

vec3 or_rgb2hsv(vec3 c) {
	vec4 K = vec4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
	vec4 p = mix(vec4(c.bg, K.wz), vec4(c.gb, K.xy), step(c.b, c.g));
	vec4 q = mix(vec4(p.xyw, c.r), vec4(c.r, p.yzx), step(p.x, c.r));
	float d = q.x - min(q.w, q.y);
	float e = 1.0e-10;
	return vec3(abs(q.z + (q.w - q.y) / (6.0 * d + e)), d / (q.x + e), q.x);
}

vec3 or_hsv2rgb(vec3 c) {
	vec4 K = vec4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
	vec3 p = abs(fract(c.xxx + K.xyz) * 6.0 - K.www);
	return c.z * mix(K.xxx, clamp(p - K.xxx, 0.0, 1.0), c.y);
}

// Paint variation: shift value and hue a little following the brush pattern.
vec3 or_paint_albedo(vec3 base, float brush, float value_jitter, float hue_jitter) {
	vec3 hsv = or_rgb2hsv(base);
	hsv.x = fract(hsv.x + (brush - 0.5) * hue_jitter);
	hsv.z = clamp(hsv.z * (1.0 + (brush - 0.5) * value_jitter), 0.0, 1.0);
	return or_hsv2rgb(hsv);
}

// Stepped light with a soft, brush-broken terminator.
// Returns the light amount in 0..1 (already including shadows/attenuation).
float or_toon_ramp(float ndl, float attenuation, float brush, float terminator_noise, float bands, float softness) {
	float x = clamp(ndl + (brush - 0.5) * terminator_noise, 0.0, 1.0);
	x *= attenuation;
	float t = x * bands;
	float stepped = (floor(t) + smoothstep(0.5 - softness, 0.5 + softness, fract(t))) / bands;
	return clamp(stepped, 0.0, 1.0);
}
