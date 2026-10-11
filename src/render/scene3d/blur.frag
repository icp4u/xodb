#version 450
layout(set=0,binding=0) uniform sampler2D source_image;
layout(push_constant) uniform Push { vec4 rect; vec4 settings; } pc;
layout(location=0) in vec2 uv;
layout(location=0) out vec4 result;
void main() {
    vec2 texel=1.0/vec2(textureSize(source_image,0));
    vec3 color=vec3(0);
    if (pc.settings.z<0.5) {
        for(int y=-1;y<=1;y+=2) for(int x=-1;x<=1;x+=2)
            color+=max(texture(source_image,uv+vec2(x,y)*texel*0.5).rgb-vec3(pc.settings.w),vec3(0))*0.25;
    } else {
        vec2 direction=pc.settings.z<1.5?vec2(texel.x,0):vec2(0,texel.y);
        color=texture(source_image,uv).rgb*0.227027;
        const float weights[4]=float[](0.194595,0.121622,0.054054,0.016216);
        for(int i=1;i<=4;i++) color+=(texture(source_image,uv+direction*i).rgb+texture(source_image,uv-direction*i).rgb)*weights[i-1];
    }
    result=vec4(color,1);
}
