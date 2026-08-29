#version 450
#extension GL_GOOGLE_include_directive : require
#extension GL_EXT_nonuniform_qualifier : require
#extension GL_EXT_buffer_reference2 : require
#extension GL_EXT_scalar_block_layout : require
#extension GL_EXT_shader_explicit_arithmetic_types_int64 : require

#include "interop/structures.glsl"

// Shadow map fragment shader - outputs variance moments for VSM
layout(location = 0) in vec2 inUV;

// Output variance moments to color attachment 0 (R32G32_SFLOAT)
layout(location = 0) out vec2 outMoments;


void main() {
    // Note: no material alpha-testing here. ShadowPushBlock has no
    // material_ptr/material_index/alpha_cutoff fields, so the old block that
    // read push.material_ptr read out-of-range push constant bytes (garbage).
    float depth = gl_FragCoord.z;
    outMoments = vec2(depth, depth * depth);
}
