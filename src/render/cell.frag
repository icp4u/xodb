#version 450
// Cell patterns in screen space, so hatching runs on across neighbouring cells.
layout(location=0) flat in vec4 cell_rect;
layout(location=1) flat in vec4 cell_fill;
layout(location=2) flat in vec4 cell_accent;
layout(location=3) flat in vec4 cell_overlay;
layout(location=4) flat in uint cell_kind;
layout(location=0) out vec4 color;
void main() {
    vec2 p = floor(gl_FragCoord.xy);
    vec2 local = gl_FragCoord.xy - cell_rect.xy;
    vec4 c = cell_fill;
    uint base = cell_kind & 3u;
    if (base == 1u) {
        if (mod(p.x + p.y, 4.0) < 1.5) c = cell_accent;  // hatched: unknown
    } else if (base == 2u) {
        if (mod(p.x, 3.0) < 1.0 && mod(p.y, 3.0) < 1.0) c = cell_accent;  // dotted: pending
    } else if (base == 3u) {
        float f = float((cell_kind >> 8) & 255u) / 255.0;
        if (local.y >= cell_rect.w * (1.0 - f)) c = cell_accent;  // lower part: huge
    }
    if ((cell_kind & 4u) != 0u && mod(p.x - p.y, 5.0) < 1.0) c = vec4(c.rgb * 0.55, c.a);
    float b = max(1.0, floor(min(cell_rect.z, cell_rect.w) * 0.22 + 0.5));
    bool near_left = local.x < b, near_top = local.y < b;
    bool near_right = local.x >= cell_rect.z - b, near_bottom = local.y >= cell_rect.w - b;
    if ((cell_kind & 8u) != 0u && (near_left || near_top || near_right || near_bottom)) c = cell_overlay;  // collapse ring
    if ((cell_kind & 16u) != 0u && (near_left || near_top)) c = cell_overlay;  // split edge
    color = c;
}
