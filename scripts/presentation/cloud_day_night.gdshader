shader_type canvas_item;
render_mode unshaded;

uniform sampler2D night_texture : source_color, filter_nearest, repeat_disable;
uniform vec2 relative_heights;
uniform vec4 sky_tint_top : source_color;
uniform vec4 sky_tint_bottom : source_color;
uniform float night_mix = 0.0;
varying vec4 sprite_modulate;

void vertex() {
	sprite_modulate = COLOR;
}

void fragment() {
	vec2 y = (UV.y - 0.5) / relative_heights + 0.5;
	vec2 inside = step(vec2(0.0), y) * step(y, vec2(1.0));
	vec4 day = texture(TEXTURE, vec2(UV.x, clamp(y.x, 0.0, 1.0))) * inside.x;
	vec4 night = texture(night_texture, vec2(UV.x, clamp(y.y, 0.0, 1.0))) * inside.y;
	// Blend premultiplied colors so differently shaped silhouettes fade into transparent sky.
	float opacity = mix(day.a, night.a, night_mix);
	vec3 rgb = mix(day.rgb * day.a, night.rgb * night.a, night_mix) / max(opacity, 0.0001);
	float sky_height = smoothstep(0.0, 0.67, SCREEN_UV.y);
	vec3 sky_tint = mix(sky_tint_top.rgb, sky_tint_bottom.rgb, sky_height);
	rgb = mix(sky_tint, rgb, mix(0.44, 0.28, night_mix));
	opacity *= mix(0.92, 0.80, night_mix);
	COLOR = vec4(rgb, opacity) * sprite_modulate;
}
