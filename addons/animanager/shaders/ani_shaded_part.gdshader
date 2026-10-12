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
// 1 = fully albedo-tinted matcap; values past 1 extrapolate the tint
// harder (chrome term subtracted). 2.0 chosen by eye on the Herald —
// gold trim reads rich while pale armor stays steel.
uniform float metal_tint : hint_range(0.0, 3.0) = 2.0;
uniform float diffuse_wrap : hint_range(0.0, 1.0) = 0.4;
// ── Painterly lit ramp (2026-10-12) ─────────────────────────────────
// The plain half-lambert multiply (albedo * ndl) only darkens toward
// black, which reads flat on non-metal art. The painterly ramp instead
// shades the Lit bucket with VARIATIONS of the painted color, the way
// an artist would: the shadow side mixes toward shadow_color in OKLab
// (cooler + more saturated), the light side toward highlight_color
// (warmer + lighter), with the authored albedo at the ramp's midpoint.
// painterly = 0 (default) is bit-identical to the legacy half-lambert,
// so pre-existing rigs render unchanged. cel_bands >= 2 posterizes the
// lighting term into that many flat tone zones (0/1 = smooth ramp);
// cel_softness widens the transition between zones.
// MIRROR CONTRACT: ImageUtils.renderLitPreview in the AniMate app
// re-implements this math — change both together.
uniform float painterly : hint_range(0.0, 1.0) = 0.0;
uniform vec4 shadow_color : source_color = vec4(0.15, 0.12, 0.35, 1.0);
uniform float shadow_strength : hint_range(0.0, 1.0) = 0.55;
uniform vec4 highlight_color : source_color = vec4(1.0, 0.93, 0.78, 1.0);
uniform float highlight_strength : hint_range(0.0, 1.0) = 0.4;
// Gain on the lighting term's deviation from flat before it samples
// the ramp. Gentle height maps (broad Auto-Dome shapes) tilt normals
// only a few degrees, which leaves the ramp nearly unsampled without
// amplification; steep art saturates harmlessly against the clamp.
// 6.0 picked on the first live test's dome.
uniform float painterly_contrast : hint_range(0.5, 16.0) = 6.0;
uniform int cel_bands : hint_range(0, 8) = 0;
uniform float cel_softness : hint_range(0.0, 1.0) = 0.15;
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

// ── Painterly helpers ───────────────────────────────────────────────
// Hue work happens in OKLab so shadow/highlight shifts stay
// perceptually clean (HSV rotations produce brightness artifacts).
// Gamma 2.2 stands in for the exact sRGB curve — both ends of the
// mirror contract use the same approximation, which is all that
// matters for preview parity.

vec3 srgb_to_lin(vec3 c) {
	return pow(max(c, vec3(0.0)), vec3(2.2));
}

vec3 lin_to_srgb(vec3 c) {
	return pow(max(c, vec3(0.0)), vec3(1.0 / 2.2));
}

vec3 lin_to_oklab(vec3 c) {
	float l = 0.4122214708 * c.r + 0.5363325363 * c.g + 0.0514459929 * c.b;
	float m = 0.2119034982 * c.r + 0.6806995451 * c.g + 0.1073969566 * c.b;
	float s = 0.0883024619 * c.r + 0.2817188376 * c.g + 0.6299787005 * c.b;
	float lc = pow(max(l, 0.0), 1.0 / 3.0);
	float mc = pow(max(m, 0.0), 1.0 / 3.0);
	float sc = pow(max(s, 0.0), 1.0 / 3.0);
	return vec3(
		0.2104542553 * lc + 0.7936177850 * mc - 0.0040720468 * sc,
		1.9779984951 * lc - 2.4285922050 * mc + 0.4505937099 * sc,
		0.0259040371 * lc + 0.7827717662 * mc - 0.8086757660 * sc);
}

vec3 oklab_to_lin(vec3 c) {
	float lc = c.x + 0.3963377774 * c.y + 0.2158037573 * c.z;
	float mc = c.x - 0.1055613458 * c.y - 0.0638541728 * c.z;
	float sc = c.x - 0.0894841775 * c.y - 1.2914855480 * c.z;
	float l = lc * lc * lc;
	float m = mc * mc * mc;
	float s = sc * sc * sc;
	return vec3(
		4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
		-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
		-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s);
}

// Posterize the lighting term into cel_bands flat tone zones spanning
// [0,1] (bands=3 -> plateaus at 0, 0.5, 1), with smoothstepped
// transitions cel_softness wide. bands < 2 passes through untouched.
float cel_quantize(float t) {
	if (cel_bands < 2) {
		return t;
	}
	float steps = float(cel_bands - 1);
	float s = t * steps;
	float f = floor(s);
	float w = max(cel_softness * 0.5, 0.0005);
	float e = smoothstep(0.5 - w, 0.5 + w, s - f);
	return clamp((f + e) / steps, 0.0, 1.0);
}

// Albedo-derived shading ramp sampled by the lighting term t: the
// painted color sits at t=0.5; below it mixes toward shadow_color,
// above toward highlight_color, all in OKLab.
vec3 painterly_ramp(vec3 albedo, float t) {
	vec3 al = lin_to_oklab(srgb_to_lin(albedo));
	vec3 sh = mix(al, lin_to_oklab(srgb_to_lin(shadow_color.rgb)),
		shadow_strength);
	vec3 hi = mix(al, lin_to_oklab(srgb_to_lin(highlight_color.rgb)),
		highlight_strength);
	vec3 lab = t < 0.5 ? mix(sh, al, t * 2.0) : mix(al, hi, t * 2.0 - 1.0);
	return clamp(lin_to_srgb(oklab_to_lin(lab)), vec3(0.0), vec3(1.0));
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
	// pixels (G=0) stay exactly as painted. The painterly ramp (when
	// on) replaces the brightness multiply with albedo-derived color
	// variation; it samples the RAW half-lambert so the shadow end of
	// the ramp is reachable (diffuse_wrap stays a legacy-path knob —
	// the ramp's midpoint-at-albedo already keeps the form bright).
	float hl = dot(nw, light) * 0.5 + 0.5;
	float ndl = mix(hl, 1.0, diffuse_wrap);
	vec3 lit_col = albedo.rgb * ndl;
	if (painterly > 0.0) {
		// Recenter so a FLAT surface (normal +Z) sits at the ramp's
		// albedo midpoint. Without this, the default light's z puts
		// flat pixels at hl ~0.88 — deep in highlight territory —
		// and the whole part washes toward the highlight color
		// (seen on the first live test). Tilts toward the light go
		// warm, away go cool, flat stays the authored color.
		float hl_flat = light.z * 0.5 + 0.5;
		float t = hl <= hl_flat
			? 0.5 * hl / max(hl_flat, 1e-4)
			: 0.5 + 0.5 * (hl - hl_flat) / max(1.0 - hl_flat, 1e-4);
		t = clamp(0.5 + (t - 0.5) * painterly_contrast, 0.0, 1.0);
		lit_col = mix(lit_col, painterly_ramp(albedo.rgb, cel_quantize(t)),
			painterly);
	}
	vec3 nonmetal = mix(albedo.rgb, lit_col, lit_amt);

	vec3 col = mix(nonmetal, metal, metal_amt);

	// Rim light on the silhouette of shaded pixels only — flat and
	// emissive areas stay clean.
	float rim = pow(1.0 - clamp(nw.z, 0.0, 1.0), rim_power) * rim_strength;
	col += rim * rim_color.rgb * max(metal_amt, lit_amt);

	// Emissive last: overrides lighting with boosted painted color.
	col = mix(col, albedo.rgb * emissive_energy, emissive_amt);

	COLOR = vec4(col, albedo.a);
}
