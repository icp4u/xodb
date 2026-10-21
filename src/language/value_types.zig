//! Native value results shared by providers and their inspection owner.
const eval = @import("../debug/evaluate.zig");
const value_view = @import("../debug/value_view.zig");
pub const ValueSummary = struct { provider: ?[]const u8 = null, runtime_type: ?eval.RuntimeType = null, type: []const u8, kind: eval.Kind, size: u64, address: ?u64, bits: ?u64, display: []const u8, availability: eval.Availability, diagnostic: ?[]const u8 = null, language: eval.Language = .unknown, enumerator: ?[]const u8 = null, visualization: ?value_view.Preview = null, composite: bool = false, partial: bool = false };
pub const ValueChild = struct { index: u64, name: []const u8, value: ValueSummary };
pub const ValuePage = struct { value: ValueSummary, presentation: value_view.Presentation, total: u64, start: u64, next: ?u64, children: []ValueChild, basis: []const u8 = value_view.basis };
