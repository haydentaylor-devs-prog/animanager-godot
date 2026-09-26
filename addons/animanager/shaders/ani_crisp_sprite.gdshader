shader_type canvas_item;
// "Pixel art AA" sampling for playground attachment/effect sprites
// (2026-09-26). A nearest-filtered sprite at a NON-INTEGER effective
// scale (weapon fit scale x zoom, effect scale sliders) renders
// uneven texel columns that redistribute as the sprite drifts
// sub-pixel — visible shimmer/jitter against the rig's parts, which
// sit at the integer zoom scale. Same cure as Angel-Squadron's HD-2D
// character quads: snap sampling to texel centers and blend only
// across the one-screen-pixel band at each texel seam, so texels
// stay sharp squares with stable edges at any scale and rotation.
// Requires the CanvasItem's texture_filter = LINEAR (the blend band
// needs bilinear samples to blend with).

// Width of the antialiased seam band, in screen pixels.
uniform float seam_softness : hint_range(0.25, 1.0) = 0.55;

varying vec4 v_modulate;

void vertex() {
	// Vertex COLOR carries the item's (self_)modulate; capture it
	// before the default pipeline multiplies it with the texture.
	v_modulate = COLOR;
}

void fragment() {
	vec2 tex_size = vec2(textureSize(TEXTURE, 0));
	vec2 texel = UV * tex_size;
	vec2 seam = floor(texel + 0.5);
	vec2 band = fwidth(texel) * seam_softness;
	texel = seam + clamp((texel - seam) / max(band, vec2(0.00001)), -0.5, 0.5);
	COLOR = v_modulate * texture(TEXTURE, texel / tex_size);
}
