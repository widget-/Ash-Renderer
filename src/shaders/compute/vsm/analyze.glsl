#version 450
#extension GL_EXT_buffer_reference2 : require
#extension GL_EXT_scalar_block_layout : require
#extension GL_EXT_shader_explicit_arithmetic_types_int64 : require
#extension GL_EXT_nonuniform_qualifier : require

#include "../../interop/structures.glsl"

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
layout(constant_id = 0) const uint MAX_REQUESTS = 1024;

// One u32 "requested this frame" flag per virtual page. Cleared before the
// analysis dispatch; the analysis claims a page atomically and only the first
// claimer per page emits a request, deduping per-pixel requests to per-page.
layout(buffer_reference, scalar, buffer_reference_align = 4) buffer PageClaimBuffer {
    uint flags[];
};

void main() {
    ivec2 pixel_coord = ivec2(gl_GlobalInvocationID.xy);
    
    VsmGlobal u_Global = VsmGlobal(push.vsm_ptr);
    VsmRequestBuffer requests = VsmRequestBuffer(u_Global.request_ptr);

    ivec2 screen_size = textureSize(global_textures[nonuniformEXT(u_Global.scene_depth_index)], 0);
    
    if (pixel_coord.x >= screen_size.x || pixel_coord.y >= screen_size.y) return;

    vec2 uv = (vec2(pixel_coord) + 0.5) / vec2(screen_size);

    // 1. Sample Depth
    float depth = texture(global_textures[nonuniformEXT(u_Global.scene_depth_index)], uv).r;
    
    // Skip skybox. This renderer uses reverse-Z (near->1.0, far->0.0), so the
    // background/cleared depth is near 0.0, not 1.0.
    if (depth <= 0.001) return; 

    // 2. Reconstruct World Position
    vec4 clip_pos = vec4(uv.x * 2.0 - 1.0, uv.y * 2.0 - 1.0, depth, 1.0);
    vec4 view_pos = u_Global.inv_view_proj * clip_pos;
    vec4 world_pos = view_pos / view_pos.w;

    // 3. Project to Light Space (Level 0 for now)
    vec4 shadow_pos = u_Global.light_view_projections[0] * world_pos;
    
    // 4. Check Bounds
    if (shadow_pos.x >= -1.0 && shadow_pos.x <= 1.0 &&
        shadow_pos.y >= -1.0 && shadow_pos.y <= 1.0 &&
        shadow_pos.z >= -1.0 && shadow_pos.z <= 1.0) 
    {
        // 5. Convert to Page Coordinates
        vec2 page_uv = shadow_pos.xy * 0.5 + 0.5;
        uint page_x = uint(page_uv.x * float(u_Global.page_table_size));
        uint page_y = uint(page_uv.y * float(u_Global.page_table_size));
        
        page_x = min(page_x, u_Global.page_table_size - 1);
        page_y = min(page_y, u_Global.page_table_size - 1);
        
        uint layer = 0;
        
        // 6. Bindless Residency Check
        // Use the global_page_tables array from structures.glsl
        uint page_entry = texelFetch(global_page_tables[nonuniformEXT(u_Global.page_table_index)], ivec3(page_x, page_y, layer), 0).r;
        
        if (page_entry != 0xFFFFFFFFu) return; // Already allocated and resident

        // 7. Dedupe: claim the page so only the first pixel covering it emits a
        // request. The claim buffer is a u32 flag per virtual page, cleared at
        // the start of this frame.
        uint psz = u_Global.page_table_size;
        uint page_index = (layer * psz + page_y) * psz + page_x;
        PageClaimBuffer claims = PageClaimBuffer(u_Global.page_claim_ptr);
        uint first = atomicAdd(claims.flags[page_index], 1);
        if (first != 0) return; // someone already claimed this page this frame

        // 8. Request Page
        uint idx = atomicAdd(requests.count, 1);
        if (idx < MAX_REQUESTS) { 
            requests.data[idx].virtual_x = page_x;
            requests.data[idx].virtual_y = page_y;
            requests.data[idx].priority = distance(world_pos.xyz, u_Global.camera_position.xyz);
            requests.data[idx].layer = layer;
        } else {
            atomicAdd(requests.overflow_count, 1);
        }
    }
}
