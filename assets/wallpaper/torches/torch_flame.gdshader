shader_type canvas_item;
render_mode unshaded;

uniform float phase = 0.0;

void fragment() {
	vec2 grid = vec2(16.0, 20.0);
	vec2 pixel_uv = (floor(UV * grid) + 0.5) / grid;
	float time = floor(TIME * 11.0) / 11.0 + phase;
	float height = 0.83 + 0.09 * sin(time * 13.0) + 0.06 * sin(time * 19.0);
	float rise = (1.0 - pixel_uv.y) / height;
	float lean = (0.10 * sin(time * 8.0) + 0.14 * sin(time * 11.0 + rise * 4.0)) * rise;
	float distance = abs(pixel_uv.x - 0.5 - lean);
	float width = mix(0.31, 0.018, smoothstep(0.13, 1.0, rise))
		* smoothstep(-0.02, 0.21, rise);
	float edge = distance / max(width, 0.001) + 0.19 * rise;
	float alpha = step(edge, 1.0) * step(rise, 1.0) * COLOR.a;
	vec3 color = mix(vec3(0.91, 0.29, 0.08), vec3(1.0, 0.67, 0.22), step(edge, 0.82));
	color = mix(color, vec3(1.0, 0.92, 0.60), step(edge, 0.51) * step(rise, 0.62));
	COLOR = vec4(color, alpha);
}
