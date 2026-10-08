#version 450
// One instanced cell: the quad's corners come from gl_VertexIndex.
layout(location=0) in vec4 rect;
layout(location=1) in vec4 fill;
layout(location=2) in vec4 accent;
layout(location=3) in vec4 overlay;
layout(location=4) in uint kind;
layout(location=0) flat out vec4 cell_rect;
layout(location=1) flat out vec4 cell_fill;
layout(location=2) flat out vec4 cell_accent;
layout(location=3) flat out vec4 cell_overlay;
layout(location=4) flat out uint cell_kind;
layout(push_constant) uniform View { vec2 size; } view;
const vec2 corners[6] = vec2[](vec2(0, 0), vec2(1, 0), vec2(1, 1), vec2(0, 0), vec2(1, 1), vec2(0, 1));
void main() {
    vec2 p = rect.xy + corners[gl_VertexIndex] * rect.zw;
    gl_Position = vec4(p / view.size * 2.0 - 1.0, 0.0, 1.0);
    cell_rect = rect;
    cell_fill = fill;
    cell_accent = accent;
    cell_overlay = overlay;
    cell_kind = kind;
}
