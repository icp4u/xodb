#version 450
layout(location=0) in vec4 center_emission;
layout(location=1) in vec4 half_wire;
layout(location=2) in vec4 tint;
layout(push_constant) uniform Push { mat4 vp; vec2 viewport; float mode; float exposure; float scale; } pc;
layout(location=0) out vec4 color;
layout(location=1) out vec3 normal;
layout(location=2) out vec2 uv;
layout(location=3) out float emission;
const vec3 corners[8]=vec3[](vec3(-1,-1,-1),vec3(1,-1,-1),vec3(1,1,-1),vec3(-1,1,-1),vec3(-1,-1,1),vec3(1,-1,1),vec3(1,1,1),vec3(-1,1,1));
const int faces[36]=int[](0,2,1,0,3,2,4,5,6,4,6,7,0,4,7,0,7,3,1,2,6,1,6,5,0,1,5,0,5,4,3,7,6,3,6,2);
const int edges[24]=int[](0,1,1,2,2,3,3,0,4,5,5,6,6,7,7,4,0,4,1,5,2,6,3,7);
const vec3 normals[6]=vec3[](vec3(0,0,-1),vec3(0,0,1),vec3(-1,0,0),vec3(1,0,0),vec3(0,-1,0),vec3(0,1,0));
void main() {
    bool edge=pc.mode>0.5 && pc.mode<1.5;
    int index=edge?edges[gl_VertexIndex]:faces[gl_VertexIndex];
    gl_Position=pc.vp*vec4(center_emission.xyz+corners[index]*half_wire.xyz,1);
    color=tint;
    if (!edge && half_wire.w>0.5) color.a=0;
    normal=edge?vec3(0):normals[gl_VertexIndex/6];
    emission=center_emission.w;
    uv=vec2(0);
}
