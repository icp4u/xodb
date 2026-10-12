#version 450
layout(location=0) in vec4 position_size;
layout(location=1) in vec4 tint;
layout(push_constant) uniform Push { mat4 vp; vec2 viewport; float mode; float exposure; float scale; } pc;
layout(location=0) out vec4 color;
layout(location=1) out vec3 normal;
layout(location=2) out vec2 uv;
layout(location=3) out float emission;
const vec2 corners[6]=vec2[](vec2(-1,-1),vec2(1,-1),vec2(1,1),vec2(-1,-1),vec2(1,1),vec2(-1,1));
void main() {
    uv=corners[gl_VertexIndex];
    gl_Position=pc.vp*vec4(position_size.xyz,1);
    gl_Position.xy+=uv*clamp(position_size.w*pc.scale,0,256)/pc.viewport*gl_Position.w;
    color=tint;normal=vec3(0);emission=0;
}
