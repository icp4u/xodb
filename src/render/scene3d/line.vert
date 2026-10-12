#version 450
layout(location=0) in vec4 a;
layout(location=1) in vec4 b_emission;
layout(location=2) in vec4 tint;
layout(push_constant) uniform Push { mat4 vp; vec2 viewport; float mode; float exposure; float scale; } pc;
layout(location=0) out vec4 color;
layout(location=1) out vec3 normal;
layout(location=2) out vec2 uv;
layout(location=3) out float emission;
void main() {
    gl_Position=pc.vp*vec4(gl_VertexIndex==0?a.xyz:b_emission.xyz,1);
    color=tint;normal=vec3(0);uv=vec2(0);emission=b_emission.w;
}
