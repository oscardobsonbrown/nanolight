const std = @import("std");

pub const Note = struct {
    id: []const u8,
    markdown: []const u8 = "",
    draft: ?[]const u8 = null,
    x: f64 = 0,
    y: f64 = 0,
    width: f64 = 390,
    height: f64 = 320,
    visible: bool = true,

    pub fn text(note: Note) []const u8 {
        return note.draft orelse note.markdown;
    }
};

pub const EditChoice = enum { save, discard };

const Document = struct {
    version: u32 = 1,
    notes: []const Note,
};

pub const Store = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    notes: std.ArrayList(Note) = .empty,

    pub fn load(store: *Store) !void {
        const data = std.Io.Dir.cwd().readFileAlloc(store.io, store.path, store.gpa, .limited(16 << 20)) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer store.gpa.free(data);
        const parsed = try std.json.parseFromSlice(Document, store.gpa, data, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        if (parsed.value.version != 1) return error.UnsupportedVersion;
        for (parsed.value.notes, 0..) |note, i| {
            if (note.id.len == 0 or !std.math.isFinite(note.x) or !std.math.isFinite(note.y) or
                !std.math.isFinite(note.width) or !std.math.isFinite(note.height) or note.width < 280 or note.height < 200)
                return error.InvalidNote;
            for (parsed.value.notes[0..i]) |previous| {
                if (std.mem.eql(u8, previous.id, note.id)) return error.InvalidNote;
            }
        }
        for (parsed.value.notes) |note| {
            const id = try store.gpa.dupe(u8, note.id);
            errdefer store.gpa.free(id);
            const markdown = try store.gpa.dupe(u8, note.markdown);
            errdefer store.gpa.free(markdown);
            const draft = if (note.draft) |text| try store.gpa.dupe(u8, text) else null;
            errdefer if (draft) |text| store.gpa.free(text);
            var copy = note;
            copy.id = id;
            copy.markdown = markdown;
            copy.draft = draft;
            try store.notes.append(store.gpa, copy);
        }
    }

    pub fn save(store: *Store) !void {
        const data = try std.json.Stringify.valueAlloc(store.gpa, Document{ .notes = store.notes.items }, .{});
        defer store.gpa.free(data);
        if (data.len > 16 << 20) return error.NotesTooLarge;
        var file = try std.Io.Dir.cwd().createFileAtomic(store.io, store.path, .{
            .permissions = .fromMode(0o600),
            .make_path = true,
            .replace = true,
        });
        defer file.deinit(store.io);
        try file.file.writeStreamingAll(store.io, data);
        try file.replace(store.io);
    }

    pub fn deinit(store: *Store) void {
        for (store.notes.items) |note| store.free(note);
        store.notes.deinit(store.gpa);
        store.gpa.free(store.path);
    }

    pub fn free(store: *Store, note: Note) void {
        store.gpa.free(note.id);
        store.gpa.free(note.markdown);
        if (note.draft) |draft| store.gpa.free(draft);
    }

    pub fn finishEdit(store: *Store, index: usize, choice: EditChoice, close: bool) !void {
        const note = &store.notes.items[index];
        const previous = note.*;
        if (close) note.visible = false;
        if (previous.draft) |draft| {
            if (choice == .save) note.markdown = draft;
            note.draft = null;
        }
        errdefer note.* = previous;
        try store.save();
        if (previous.draft) |draft| store.gpa.free(if (choice == .save) previous.markdown else draft);
    }

    pub fn find(store: *Store, id: []const u8) ?usize {
        for (store.notes.items, 0..) |note, index| {
            if (std.mem.eql(u8, note.id, id)) return index;
        }
        return null;
    }
};

test "note text and frame survive reload and a bad file is preserved" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(dir);
    const path = try std.fs.path.join(gpa, &.{ dir, "notes.json" });
    var store: Store = .{ .gpa = gpa, .io = io, .path = path };
    defer store.deinit();
    try store.notes.append(gpa, .{
        .id = try gpa.dupe(u8, "test"),
        .markdown = try gpa.dupe(u8, "# Draft 🌿\n\n**Text**"),
        .visible = false,
        .width = 461,
    });
    try store.save();

    const restored_path = try gpa.dupe(u8, path);
    var restored: Store = .{ .gpa = gpa, .io = io, .path = restored_path };
    defer restored.deinit();
    try restored.load();
    const note = restored.notes.items[restored.find("test").?];
    try std.testing.expectEqualStrings(store.notes.items[0].markdown, note.markdown);
    try std.testing.expectEqual(461, note.width);
    try std.testing.expect(!note.visible);
    restored.free(restored.notes.orderedRemove(0));
    try restored.save();
    try restored.load();
    try std.testing.expectEqual(0, restored.notes.items.len);

    try tmp.dir.writeFile(io, .{ .sub_path = "notes.json", .data = "broken" });
    try std.testing.expectError(error.SyntaxError, restored.load());
    const bytes = try tmp.dir.readFileAlloc(io, "notes.json", gpa, .limited(30));
    defer gpa.free(bytes);
    try std.testing.expectEqualStrings("broken", bytes);
}

test "autosave preserves drafts separately and close can save or discard them" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(dir);
    const path = try std.fs.path.join(gpa, &.{ dir, "notes.json" });
    var store: Store = .{ .gpa = gpa, .io = io, .path = path };
    defer store.deinit();
    try store.notes.append(gpa, .{ .id = try gpa.dupe(u8, "note"), .markdown = try gpa.dupe(u8, "Saved"), .draft = try gpa.dupe(u8, "Draft") });
    try store.save();

    var restored: Store = .{ .gpa = gpa, .io = io, .path = try gpa.dupe(u8, path) };
    defer restored.deinit();
    try restored.load();
    try std.testing.expectEqualStrings("Draft", restored.notes.items[0].text());
    try std.testing.expectEqualStrings("Saved", restored.notes.items[0].markdown);

    const unwritable = try std.fs.path.join(gpa, &.{ dir, "notes.json", "cannot-write" });
    defer gpa.free(unwritable);
    const restored_path = restored.path;
    restored.path = unwritable;
    const result = restored.finishEdit(0, .discard, true);
    restored.path = restored_path;
    try std.testing.expectError(error.NotDir, result);
    try std.testing.expect(restored.notes.items[0].visible);
    try std.testing.expectEqualStrings("Draft", restored.notes.items[0].text());
    try restored.finishEdit(0, .discard, true);
    try std.testing.expectEqualStrings("Saved", restored.notes.items[0].text());
    try std.testing.expect(restored.notes.items[0].draft == null);
    try std.testing.expect(!restored.notes.items[0].visible);

    try store.finishEdit(0, .save, true);
    try std.testing.expectEqualStrings("Draft", store.notes.items[0].markdown);
    try std.testing.expect(store.notes.items[0].draft == null);
    try std.testing.expect(!store.notes.items[0].visible);
}
