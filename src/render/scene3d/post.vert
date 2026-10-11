#version 450
layout(push_constant) uniform Push { vec4 rect; vec4 settings; } pc;
layout(location=0) out vec2 uv;
const vec2 corners[6]=vec2[](vec2(0,0),vec2(1,0),vec2(1,1),vec2(0,0),vec2(1,1),vec2(0,1));
void main() {
    vec2 position=pc.rect.xy+corners[gl_VertexIndex]*pc.rect.zw;
    uv=position/pc.settings.xy;
    gl_Position=vec4(uv*2-1,0,1);
}
