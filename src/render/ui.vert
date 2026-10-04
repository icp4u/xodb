#version 450
layout(location=0) in vec2 position;
layout(location=1) in vec2 uv;
layout(location=2) in vec4 color;
layout(location=3) in vec2 local;
layout(location=4) in vec2 half_size;
layout(location=5) in vec3 shape;
layout(location=0) out vec2 texcoord;
layout(location=1) out vec4 tint;
layout(location=2) out vec2 sample_position;
layout(location=3) out vec2 rect_half_size;
layout(location=4) out vec3 rect_shape;
layout(push_constant) uniform View { vec2 size; } view;
void main() {
    gl_Position = vec4(position / view.size * 2.0 - 1.0, 0.0, 1.0);
    texcoord = uv;
    tint = color;
    sample_position = local;
    rect_half_size = half_size;
    rect_shape = shape;
}
