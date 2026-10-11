#version 450
layout(location=0) in vec4 anchor;
layout(location=1) in vec4 rect;
layout(location=2) in vec4 atlas_uv;
layout(location=3) in vec4 tint;
layout(push_constant) uniform Push { mat4 vp; vec2 viewport; float mode; float exposure; } pc;
layout(location=0) out vec4 color;
layout(location=1) out vec3 normal;
layout(location=2) out vec2 uv;
layout(location=3) out float emission;
const vec2 corners[6]=vec2[](vec2(0,0),vec2(1,0),vec2(1,1),vec2(0,0),vec2(1,1),vec2(0,1));
void main() {
    vec2 p=corners[gl_VertexIndex];
    gl_Position=pc.vp*vec4(anchor.xyz,1);
    gl_Position.xy+=(rect.xy+p*rect.zw)*2/pc.viewport*gl_Position.w;
    uv=atlas_uv.xy+p*atlas_uv.zw;
    color=tint;normal=vec3(0);emission=0;
}
