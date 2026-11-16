shader_type canvas_item;

uniform float phase;
varying vec4 tint;

void vertex() {
	tint = COLOR;
}

void fragment() {
	// Fade out the movement above the stone so the stone and feet stay in place.
	float upper_body = 1.0 - smoothstep(0.20, 0.66, UV.y);
	vec2 breath = vec2(2.4 * sin(phase), 0.9 * (1.0 - cos(phase)));
	COLOR = texture(TEXTURE, UV - breath * upper_body * TEXTURE_PIXEL_SIZE) * tint;
}
