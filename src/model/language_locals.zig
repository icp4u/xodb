//! Named stopped-language bindings; layout and value decoding stay in C.
const std = @import("std");
const Session = @import("session.zig").Session;
const Tab = @import("language_tabs.zig").Tab;
pub const Child = @import("../language/locals_types.zig").Child;
pub const Value = @import("../language/locals_types.zig").Value;
pub const Row = @import("../language/locals_types.zig").Row;
pub const Result = @import("../language/locals_types.zig").Result;
pub fn supported(language: Tab) bool {
    return language == .lua or language == .perl or language == .python or language == .javascript or language == .ruby or language == .elisp or language == .gdscript;
}
pub fn read(session: *Session, a: std.mem.Allocator, language: Tab, tid: i32, segment: usize, frame: usize, start: usize, limit: usize) !Result {
    if (session.target.snapshot().state != .stopped) return error.NotStopped;
    if (tid <= 0 or segment >= 64 or frame >= 64 or start > 4096 or limit == 0 or limit > 32) return error.InvalidArguments;
    return switch (language) {
        .elisp => blk: {
            try session.languages.require(.elisp);
            const observed = try @import("language_selection.zig").cachedRead(.elisp, session, tid);
            break :blk @import("../language/elisp.zig").readLocals(&session.languageContext(), a, observed, tid, segment, frame, start, limit);
        },
        .gdscript => blk: {
            try session.languages.require(.gdscript);
            const observed = try @import("language_selection.zig").cachedRead(.gdscript, session, tid);
            break :blk @import("../language/gdscript.zig").readLocals(&session.languageContext(), a, observed, tid, segment, frame, start, limit);
        },
        .ruby => blk: {
            try session.languages.require(.ruby);
            const observed = try @import("language_selection.zig").cachedRead(.ruby, session, tid);
            break :blk @import("../language/ruby.zig").readLocals(&session.languageContext(), a, observed, tid, segment, frame, start, limit);
        },
        .lua => @import("../language/lua.zig").readLocals(&session.languageContext(), a, tid, segment, frame, start, limit),
        .perl => blk: {
            try session.languages.require(.perl);
            const observed = try @import("language_selection.zig").cachedRead(.perl, session, tid);
            break :blk @import("../language/perl.zig").readLocals(&session.languageContext(), a, observed, tid, segment, frame, start, limit);
        },
        .python => blk: {
            try session.languages.require(.python);
            const observed = try @import("language_selection.zig").cachedRead(.python, session, tid);
            break :blk @import("../language/python.zig").readLocals(&session.languageContext(), a, observed, tid, segment, frame, start, limit);
        },
        .javascript => blk: {
            try session.languages.require(.javascript);
            const observed = try @import("language_selection.zig").cachedRead(.javascript, session, tid);
            break :blk @import("../language/javascript.zig").readContext(&session.languageContext(), a, observed, tid, segment, frame, start, limit);
        },
        else => error.InvalidArguments,
    };
}

/// Only memory-backed language operations are allowed; each runtime decides its
/// supported expression subset. No interpreter evaluation or target calls.
pub fn evaluate(session: *Session, a: std.mem.Allocator, language: Tab, tid: i32, segment: usize, frame: usize, text: []const u8) !Result {
    if (session.target.snapshot().state != .stopped) return error.NotStopped;
    if (tid <= 0 or segment >= 64 or frame >= 64 or text.len == 0 or text.len > 128 or std.mem.indexOfScalar(u8, text, 0) != null) return error.InvalidArguments;
    return switch (language) {
        .elisp => error.ElispExpressionsUnavailable,
        .gdscript => blk: {
            try session.languages.require(.gdscript);
            const path = try @import("../language/gdscript_values.zig").parse(text);
            const observed = try @import("language_selection.zig").cachedRead(.gdscript, session, tid);
            break :blk @import("../language/gdscript.zig").evaluateLocal(&session.languageContext(), a, observed, tid, segment, frame, text, path);
        },
        .ruby => blk: {
            try session.languages.require(.ruby);
            // Syntax refusal must precede any cached-stack/target read.
            _ = try @import("../language/ruby.zig").checkedExpression(a, text);
            const observed = try @import("language_selection.zig").cachedRead(.ruby, session, tid);
            break :blk @import("../language/ruby.zig").evaluateLocal(&session.languageContext(), a, observed, tid, segment, frame, text);
        },
        .lua => @import("../language/lua.zig").evaluateLocal(&session.languageContext(), a, tid, segment, frame, text),
        .perl => blk: {
            try session.languages.require(.perl);
            try @import("../language/perl.zig").checkExpression(a, text);
            const observed = try @import("language_selection.zig").cachedRead(.perl, session, tid);
            break :blk @import("../language/perl.zig").evaluateLocal(&session.languageContext(), a, observed, tid, segment, frame, text);
        },
        .python => blk: {
            try session.languages.require(.python);
            try @import("../language/python.zig").checkExpression(a, text);
            const observed = try @import("language_selection.zig").cachedRead(.python, session, tid);
            break :blk @import("../language/python.zig").evaluateLocal(&session.languageContext(), a, observed, tid, segment, frame, text);
        },
        .javascript => blk: {
            try session.languages.require(.javascript);
            const observed = try @import("language_selection.zig").cachedRead(.javascript, session, tid);
            break :blk @import("../language/javascript.zig").evaluateLocal(&session.languageContext(), observed, segment, frame);
        },
        else => error.InvalidArguments,
    };
}
