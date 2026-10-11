#version 450
layout(set=0,binding=0) uniform sampler2D scene_image;
layout(set=0,binding=1) uniform sampler2D bloom_image;
layout(push_constant) uniform Push { vec4 rect; vec4 settings; } pc;
layout(location=0) in vec2 uv;
layout(location=0) out vec4 result;
void main() {
    vec3 hdr=texture(scene_image,uv).rgb+texture(bloom_image,uv).rgb*pc.settings.w;
    result=vec4(1-exp(-max(hdr,vec3(0))*pc.settings.z),1);
}
