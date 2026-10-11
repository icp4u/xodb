#version 450
layout(set=0,binding=0) uniform sampler2D atlas;
layout(push_constant) uniform Push { mat4 vp; vec2 viewport; float mode; float exposure; } pc;
layout(location=0) in vec4 color;
layout(location=1) in vec3 normal;
layout(location=2) in vec2 uv;
layout(location=3) in float emission;
layout(location=0) out vec4 result;
void main() {
    float alpha=clamp(color.a,0,1);
    if (pc.mode<0.5 && alpha<0.999) discard;
    if (pc.mode>4.5 && alpha>=0.999) discard;
    if (pc.mode>3.5 && pc.mode<4.5) alpha*=texture(atlas,uv).r;
    else if (pc.mode>1.5 && pc.mode<2.5) {
        float radius=length(uv);
        alpha*=1-smoothstep(0.65,1,radius);
    }
    if (alpha<=0.001) discard;
    float light=(pc.mode<0.5 || pc.mode>4.5)?0.24+0.65*max(dot(normal,normalize(vec3(0.3,0.8,0.6))),0):1.2;
    result=vec4(max(color.rgb,vec3(0))*(light+clamp(emission,0,8)),alpha);
}
