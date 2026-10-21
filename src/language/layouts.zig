//! Per-image layout caches. The model owns their storage and destruction;
//! borrowed language contexts share these same slots without owning the image.
const c = @import("../c.zig").api;
const tls = @import("../binary/tls.zig");

pub const Layouts = struct {
    perl: ?c.struct_xpl_layout = null,
    python: ?c.struct_xpy_layout = null,
    lua: ?c.struct_xl_layout = null,
    elisp: ?c.struct_xel_layout = null,
    gdscript: ?GDScript = null,
    /// Why this image's DWARF gave no layouts, once that has been found out.
    gdscript_refusal: ?anyerror = null,
    ruby: ?c.struct_xrb_layout = null,
    go: ?c.struct_xgo_layout = null,
    go_value: ?*c.struct_xgv_layout = null,
    go_map: ?*c.struct_xgm_layout = null,
    javascript_dwarf: ?c.struct_xjs_dwarf_profile = null,
};

pub const GDScriptField = enum(u8) { level_stack, level_function, level_instance, level_ip, level_line, level_prev, function_name, function_source, function_script, script_path, instance_owner_id, language_track, language_max, name_string, string_name_data, string_data, engine_process_frames, engine_physics_frames, engine_in_physics };
pub const GDScriptValueType = enum(u8) { variant, variant_type, obj_data, array, dictionary, pair, stack_debug, debug_list, debug_element, property, member_element, object, node, node_path, node_path_data, packed_ref, callable, signal, function, script, instance };
pub const GDScriptValueField = enum(u8) { variant_type, variant_data, obj_id, obj_ptr, array_ptr, dict_head, dict_count, pair_next, pair_key, pair_value, debug_line, debug_pos, debug_added, debug_identifier, list_first, element_value, element_next, property_name, member_next, member_key, member_index, object_id, object_script_instance, object_class_name, node_name, node_parent, path_data, path_names, path_subnames, path_absolute, packed_ptr, callable_method, signal_name, signal_object, function_argument_count, function_stack_size, function_stack_debug, function_arguments, script_members, instance_members, instance_script };
pub const GDScriptValueKind = enum(u8) { nil, bool, int, float, string, vector2, vector2i, rect2, rect2i, vector3, vector3i, transform2d, vector4, vector4i, plane, quaternion, aabb, basis, transform3d, projection, color, string_name, node_path, rid, object, callable, signal, dictionary, array, packed_byte_array, packed_int32_array, packed_int64_array, packed_float32_array, packed_float64_array, packed_string_array, packed_vector2_array, packed_vector3_array, packed_color_array, packed_vector4_array };

/// Offsets proved from one image's DWARF and program headers.
pub const GDScript = struct {
    build_id: [64]u8 = undefined,
    build_id_len: u8 = 0,
    level_size: u32,
    offsets: [@typeInfo(GDScriptField).@"enum".fields.len]?u32,
    /// Members, sizes and `Variant::Type` values for the value reader; null
    /// where this build's DWARF does not have them.
    value_offsets: [@typeInfo(GDScriptValueField).@"enum".fields.len]?u32 = @splat(null),
    value_sizes: [@typeInfo(GDScriptValueType).@"enum".fields.len]u32 = @splat(0),
    kinds: [@typeInfo(GDScriptValueKind).@"enum".fields.len]?u32 = @splat(null),
    /// Runtime address a GDScriptInstance's vtable pointer holds.
    instance_vtable: ?u64 = null,
    /// The executable's static TLS block and the two objects in it.
    block: tls.Block,
    call_stack: u64,
    call_stack_size: u64,
    /// Runtime address of `GDScriptLanguage::singleton`.
    singleton: u64,
    engine_singleton: ?u64 = null,
    units: u64,
    pub fn at(self: *const GDScript, field: GDScriptField) u32 {
        return self.offsets[@intFromEnum(field)].?;
    }
};
