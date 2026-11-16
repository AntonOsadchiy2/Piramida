shader_type canvas_item;

void fragment() {
	vec3 fabric = texture(TEXTURE, UV).rgb;
	// Recolor the blue cloth while keeping the skin, gold trim and outline.
	float blue = smoothstep(0.012, 0.060, fabric.b - fabric.r);
	vec3 wine = vec3(fabric.b * 1.65, fabric.r * 0.70, fabric.g * 0.73);
	COLOR.rgb *= mix(vec3(1.0), wine / max(fabric, vec3(0.01)), blue);
}
