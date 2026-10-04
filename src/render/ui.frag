#version 450
layout(binding=0) uniform sampler2D atlas;
layout(location=0) in vec2 texcoord;
layout(location=1) in vec4 tint;
layout(location=2) in vec2 sample_position; // pixels from the rectangle's centre
layout(location=3) in vec2 rect_half_size;
layout(location=4) in vec3 rect_shape;      // corner radius, border thickness, edge softness
layout(location=0) out vec4 color;
// Rounded-rectangle distance. The corner, border, and softness treatment is adapted from
// RAD Debugger's rect shader (MIT; src/render/opengl/render_opengl.mdesk at 2933143b).
float rect_sdf(vec2 p, vec2 half_size, float r) { return length(max(abs(p) - half_size + r, 0.0)) - r; }
void main() {
    float coverage = texture(atlas, texcoord).r;
    if (rect_shape.x > 0.0 || rect_shape.y > 0.0 || rect_shape.z > 0.0) {
        float soft = max(rect_shape.z, 0.5);
        vec2 inner = rect_half_size - 2.0 * soft;
        coverage *= 1.0 - smoothstep(0.0, 2.0 * soft, rect_sdf(sample_position, inner, rect_shape.x));
        if (rect_shape.y > 0.0) coverage *= smoothstep(0.0, 2.0 * soft, rect_sdf(sample_position, inner - rect_shape.y, max(rect_shape.x - rect_shape.y, 0.0)));
    }
    color = vec4(tint.rgb, tint.a * coverage);
}
