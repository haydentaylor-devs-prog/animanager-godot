shader_type canvas_item;

// AniManager shaded-part shader (spec v1.6 §2.3). One instance per
// bound part when AniAnimationPlayer2D.shaded is on. Lights flat 2D
// art from the shade-mask sidecars AniMate exports with a .animrig:
//
//   material_mask — R = metal    -> matcap reflection (sliding highlight)
//                   G = lit      -> half-lambert diffuse from the normal map
//                   B = emissive -> painted color, unlit, energy-boosted
//                   black        -> flat: drawn exactly as painted
//   normal_map    — tangent-space, baked by AniMate from the part's
//                   height map. Y-DOWN convention (matches both the
//                   rig spec's §4 coordinate system and Godot's 2D
//                   canvas), +Z out of the screen, flat = (128,128,255).
//
// The normal map is authored in the PART's local (unrotated) space.
// The vertex stage grabs the canvas item's MODEL_MATRIX basis, so
// normals rotate/mirror with the bone automatically — including the
// parent rig's facing flip — with no per-frame CPU uniform updates.
//
// Channels are treated as independent 0-255 weights (per the spec)
// so future soft-brushed masks keep working; AniMate currently
// paints pure buckets.
//
// Defaults matter for graceful fallback:
//   material_mask hint_default_black  -> unmasked part = all-flat (pure albedo)
//   normal_map hint_default_transparent -> alpha 0 flags "no map"; the
//     fragment falls back to the straight-out normal. Real sidecars
//     are opaque, so alpha cleanly separates the two cases.

uniform sampler2D normal_map : hint_default_transparent, filter_nearest;
uniform sampler2D material_mask : hint_default_black, filter_nearest;
uniform sampler2D matcap : hint_default_white, filter_linear;
uniform vec3 light_dir = vec3(0.35, -0.55, 0.75);
uniform float metalness : hint_range(0.0, 1.0) = 1.0;
// How strongly the painted color tints the metal reflection, the way
// real metals color their specular (gold shines GOLD, not silver).
// 0 = legacy chrome (matcap dominates; colored trim washes to steel),
// 1 = fully albedo-tinted matcap.
uniform float metal_tint : hint_range(0.0, 1.0) = 0.6;
uniform float diffuse_wrap : hint_range(0.0, 1.0) = 0.4;
uniform float emissive_energy : hint_range(0.0, 4.0) = 1.2;
uniform vec4 rim_color : source_color = vec4(0.75, 0.88, 1.0, 1.0);
uniform float rim_power : hint_range(1.0, 8.0) = 3.0;
uniform float rim_strength : hint_range(0.0, 2.0) = 0.7;

// Normalized columns of the part's world basis (xy = X column,
// zw = Y column). Rotation + mirror only — scale is normalized away
// so rig scale doesn't distort normals.
varying flat vec4 model_basis;

void vertex() {
	model_basis = vec4(
		normalize(MODEL_MATRIX[0].xy),
		normalize(MODEL_MATRIX[1].xy)
	);
}

void fragment() {
	vec4 albedo = texture(TEXTURE, UV);
	vec3 mask = texture(material_mask, UV).rgb;
	float metal_amt = mask.r * metalness;
	float lit_amt = mask.g;
	float emissive_amt = mask.b;

	// Part-local tangent normal -> world space via the model basis.
	vec4 n_tex = texture(normal_map, UV);
	vec3 n = n_tex.rgb * 2.0 - 1.0;
	if (n_tex.a < 0.5) {
		n = vec3(0.0, 0.0, 1.0);
	}
	vec2 n_xy = model_basis.xy * n.x + model_basis.zw * n.y;
	vec3 nw = normalize(vec3(n_xy, n.z));

	vec3 light = normalize(light_dir);

	// Metal: matcap sampled by the world normal — a lit sphere image
	// gives instant metallic shading. The reflection is tinted by the
	// painted color per metal_tint; the legacy chrome term kept the
	// matcap so dominant that gold trim washed to steel.
	vec3 metal_col = texture(matcap, clamp(nw.xy * 0.5 + 0.5, vec2(0.0), vec2(1.0))).rgb;
	vec3 chrome = metal_col * (0.6 + 0.4 * albedo.rgb) + metal_col * 0.35;
	// The 1.9 scale keeps tinted brightness comparable to chrome on
	// near-white albedo, so dialing the tint doesn't dim the armor.
	vec3 tinted = metal_col * albedo.rgb * 1.9;
	vec3 metal = mix(chrome, tinted, metal_tint);

	// Lit: half-lambert diffuse, blended in by the G weight so flat
	// pixels (G=0) stay exactly as painted.
	float ndl = dot(nw, light) * 0.5 + 0.5;
	ndl = mix(ndl, 1.0, diffuse_wrap);
	vec3 nonmetal = mix(albedo.rgb, albedo.rgb * ndl, lit_amt);

	vec3 col = mix(nonmetal, metal, metal_amt);

	// Rim light on the silhouette of shaded pixels only — flat and
	// emissive areas stay clean.
	float rim = pow(1.0 - clamp(nw.z, 0.0, 1.0), rim_power) * rim_strength;
	col += rim * rim_color.rgb * max(metal_amt, lit_amt);

	// Emissive last: overrides lighting with boosted painted color.
	col = mix(col, albedo.rgb * emissive_energy, emissive_amt);

	COLOR = vec4(col, albedo.a);
}
