shader_type canvas_item;
render_mode unshaded;

uniform sampler2D night_texture : source_color, filter_nearest, repeat_disable;
uniform sampler2D morning_texture : source_color, filter_nearest, repeat_disable;
uniform sampler2D evening_texture : source_color, filter_nearest, repeat_disable;
uniform vec4 palette;

void fragment() {
	vec3 rgb = vec3(0.0);
	if (palette.x > 0.0) {
		rgb += texture(night_texture, UV).rgb * palette.x;
	}
	if (palette.y > 0.0) {
		rgb += texture(morning_texture, UV).rgb * palette.y;
	}
	if (palette.z > 0.0) {
		rgb += texture(TEXTURE, UV).rgb * palette.z;
	}
	if (palette.w > 0.0) {
		rgb += texture(evening_texture, UV).rgb * palette.w;
	}
	COLOR = vec4(rgb, 1.0);
}
