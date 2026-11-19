const std = @import("std");
const objc = @import("nanoui").objc;
const Object = objc.Object;
const msg = objc.msg;

const Range = extern struct { location: usize, length: usize };
extern "c" var NSFontAttributeName: Object;
extern "c" var NSForegroundColorAttributeName: Object;
extern "c" var NSBackgroundColorAttributeName: Object;
extern "c" var NSStrikethroughStyleAttributeName: Object;
extern "c" var NSLinkAttributeName: Object;
extern "c" var NSKernAttributeName: Object;

const Point = objc.CGPoint;
const Rect = objc.CGRect;
const checkbox_size = 13;

const Task = struct {
    length: usize,
    checked: bool,
};

const Marker = enum(usize) {
    unchecked,
    checked,
    bullet,
    divider,

    fn fromAttribute(value: Object) Marker {
        return @fromBackingInt(@intCast(msg(usize, value, "unsignedIntegerValue", .{})));
    }

    fn isTask(kind: Marker) bool {
        return kind == .unchecked or kind == .checked;
    }
};

fn taskPrefix(line: []const u8) ?Task {
    const start: usize = if (std.mem.startsWith(u8, line, "- ")) 2 else if (std.mem.startsWith(u8, line, "-")) 1 else 0;
    if (line.len < start + 2 or line[start] != '[') return null;
    const rest = line[start + 1 ..];
    const close: usize = if (rest[0] == ']') 0 else if (rest.len >= 2 and rest[1] == ']' and
        (rest[0] == ' ' or rest[0] == 'x' or rest[0] == 'X')) 1 else return null;
    const end = start + close + 2;
    if (end < line.len and line[end] == '(') return null;
    return .{ .length = end, .checked = close == 1 and rest[0] != ' ' };
}

const ListItem = struct {
    indent: []const u8,
    prefix_len: usize,
    empty: bool,
    next: []const u8,
};

fn bulletPrefix(line: []const u8) bool {
    return line.len >= 2 and std.mem.indexOfScalar(u8, "-+*", line[0]) != null and
        (line[1] == ' ' or line[1] == '\t');
}

fn divider(line: []const u8) bool {
    return std.mem.eql(u8, std.mem.trimEnd(u8, line, " \t\r"), "---");
}

fn listItem(line: []const u8, buffer: []u8) ?ListItem {
    const body = std.mem.trimStart(u8, line, " \t");
    const indent = line[0 .. line.len - body.len];
    if (body.len == 0) return null;
    var prefix: usize = undefined;
    const next = if (taskPrefix(body)) |task| next: {
        prefix = task.length;
        break :next "- [ ] ";
    } else if (bulletPrefix(body)) next: {
        prefix = 1;
        break :next std.fmt.bufPrint(buffer, "{c} ", .{body[0]}) catch return null;
    } else next: {
        const digits = std.mem.indexOfNone(u8, body, "0123456789") orelse return null;
        if (digits == 0 or digits > 9 or
            (body[digits] != '.' and body[digits] != ')') or
            digits + 1 >= body.len or !std.ascii.isWhitespace(body[digits + 1])) return null;
        const number = std.fmt.parseInt(u32, body[0..digits], 10) catch return null;
        prefix = digits + 1;
        break :next std.fmt.bufPrint(buffer, "{d}{c} ", .{ number + 1, body[digits] }) catch return null;
    };

    const label = std.mem.trimStart(u8, body[prefix..], " \t");
    return .{
        .indent = indent,
        .prefix_len = indent.len + body.len - label.len,
        .empty = label.len == 0,
        .next = next,
    };
}

fn fence(line: []const u8) bool {
    return std.mem.startsWith(u8, std.mem.trimStart(u8, line, " \t"), "```");
}

fn insideFence(previous: []const u8) bool {
    var fenced = false;
    var lines = std.mem.splitScalar(u8, previous, '\n');
    while (lines.next()) |line| {
        if (fence(line)) fenced = !fenced;
    }
    return fenced;
}

pub fn continueList(editor: Object) bool {
    if (msg(bool, editor, "hasMarkedText", .{})) return false;
    const selection = msg(Range, editor, "selectedRange", .{});
    if (selection.length != 0) return false;
    const string = msg(Object, editor, "string", .{});
    if (selection.location > msg(usize, string, "length", .{})) return false;
    const line = msg(Range, string, "lineRangeForRange:", .{selection});
    const line_string = msg(Object, string, "substringWithRange:", .{line});
    const text = std.mem.trimEnd(u8, objc.fromNSString(line_string), "\r\n");
    var buffer: [16]u8 = undefined;
    const item = listItem(text, &buffer) orelse return false;
    if (selection.location < line.location + item.prefix_len) return false;
    const previous = msg(Object, string, "substringToIndex:", .{line.location});
    if (insideFence(objc.fromNSString(previous))) return false;

    if (item.empty) {
        msg(void, editor, "insertText:replacementRange:", .{
            objc.nsString(""), Range{ .location = line.location, .length = item.prefix_len },
        });
    } else {
        const indented = msg(Object, objc.nsString("\n"), "stringByAppendingString:", .{objc.nsString(item.indent)});
        const next = msg(Object, indented, "stringByAppendingString:", .{objc.nsString(item.next)});
        msg(void, editor, "insertText:replacementRange:", .{ next, selection });
    }
    return true;
}

fn markerKey() Object {
    return objc.nsString("NanolightListMarker");
}

fn len16(text: []const u8) usize {
    return std.unicode.calcUtf16LeLen(text) catch 0;
}

fn font(size: f64, weight: f64) Object {
    return msg(Object, objc.class("NSFont"), "systemFontOfSize:weight:", .{ size, weight });
}

fn mono(size: f64) Object {
    return msg(Object, objc.class("NSFont"), "monospacedSystemFontOfSize:weight:", .{ size, @as(f64, 0) });
}

fn color(comptime selector: [:0]const u8) Object {
    return msg(Object, objc.class("NSColor"), selector, .{});
}

fn attr(storage: Object, name: Object, value: Object, offset: usize, text: []const u8) void {
    if (text.len == 0) return;
    msg(void, storage, "addAttribute:value:range:", .{ name, value, Range{ .location = offset, .length = len16(text) } });
}

fn marker(storage: Object, offset: usize, text: []const u8, active: bool) void {
    attr(storage, NSForegroundColorAttributeName, if (active) color("secondaryLabelColor") else color("clearColor"), offset, text);
    if (!active) attr(storage, NSFontAttributeName, font(1, 0), offset, text);
}

fn strike(storage: Object, offset: usize, text: []const u8) void {
    const on = msg(Object, objc.class("NSNumber"), "numberWithInt:", .{@as(c_int, 1)});
    attr(storage, NSStrikethroughStyleAttributeName, on, offset, text);
}

fn listMarkerStyle(storage: Object, offset: usize, source: []const u8, kind: Marker) void {
    const number = objc.class("NSNumber");
    attr(storage, markerKey(), msg(Object, number, "numberWithUnsignedInteger:", .{@backingInt(kind)}), offset, source);
    attr(storage, NSForegroundColorAttributeName, color("clearColor"), offset, source);
    if (kind == .divider) return;
    attr(storage, NSKernAttributeName, msg(Object, number, "numberWithDouble:", .{@as(f64, 10)}), offset, source[0..1]);
    attr(storage, NSFontAttributeName, font(1, 0), offset + 1, source[1..]);
}

fn markerTint(editor: Object) Object {
    const appearance = msg(Object, editor, "effectiveAppearance", .{});
    const dark_name = objc.nsString("NSAppearanceNameDarkAqua");
    const names = [_]Object{ dark_name, objc.nsString("NSAppearanceNameAqua") };
    const candidates = msg(Object, objc.class("NSArray"), "arrayWithObjects:count:", .{ &names, names.len });
    const best = msg(?Object, appearance, "bestMatchFromAppearancesWithNames:", .{candidates});
    const dark = if (best) |name| msg(bool, name, "isEqualToString:", .{dark_name}) else false;
    return msg(Object, objc.class("NSColor"), "colorWithSRGBRed:green:blue:alpha:", .{
        @as(f64, if (dark) 0.98 else 0.70),
        @as(f64, if (dark) 0.48 else 0.22),
        @as(f64, if (dark) 0.53 else 0.31),
        @as(f64, 1),
    });
}

fn drawMarker(bounds: Rect, tint: Object, kind: Marker) void {
    const path_class = objc.class("NSBezierPath");
    if (kind == .bullet) {
        const dot = msg(Object, path_class, "bezierPathWithOvalInRect:", .{inset(bounds, 4)});
        msg(void, tint, "setFill", .{});
        msg(void, dot, "fill", .{});
        return;
    }
    const outline = msg(Object, path_class, "bezierPathWithRoundedRect:xRadius:yRadius:", .{
        inset(bounds, 0.75), @as(f64, 3.6), @as(f64, 3.6),
    });
    msg(void, tint, "setStroke", .{});
    msg(void, outline, "setLineWidth:", .{@as(f64, 1.35)});
    msg(void, outline, "stroke", .{});
    if (kind == .checked) {
        const fill = msg(Object, path_class, "bezierPathWithRoundedRect:xRadius:yRadius:", .{
            inset(bounds, 2.8), @as(f64, 1.8), @as(f64, 1.8),
        });
        msg(void, tint, "setFill", .{});
        msg(void, fill, "fill", .{});
    }
}

fn drawDivider(box: Rect, right: f64) void {
    if (right <= box.origin.x) return;
    const path = msg(Object, objc.class("NSBezierPath"), "bezierPath", .{});
    const y = @floor(box.origin.y + box.size.height / 2) + 0.5;
    msg(void, path, "moveToPoint:", .{Point{ .x = box.origin.x, .y = y }});
    msg(void, path, "lineToPoint:", .{Point{ .x = right, .y = y }});
    msg(void, path, "setLineWidth:", .{@as(f64, 1)});
    msg(void, color("separatorColor"), "setStroke", .{});
    msg(void, path, "stroke", .{});
}

fn inset(bounds: Rect, margin: f64) Rect {
    return .{
        .origin = .{ .x = bounds.origin.x + margin, .y = bounds.origin.y + margin },
        .size = .{ .width = bounds.size.width - 2 * margin, .height = bounds.size.height - 2 * margin },
    };
}

const TaskLayout = struct {
    editor: Object,
    manager: Object,
    container: Object,
    storage: Object,
    origin: Point,
    length: usize,

    fn of(editor: Object) ?TaskLayout {
        const storage = msg(Object, editor, "textStorage", .{});
        const length = msg(usize, storage, "length", .{});
        if (length == 0) return null;
        return .{
            .editor = editor,
            .manager = msg(Object, editor, "layoutManager", .{}),
            .container = msg(Object, editor, "textContainer", .{}),
            .storage = storage,
            .origin = msg(Point, editor, "textContainerOrigin", .{}),
            .length = length,
        };
    }

    fn attribute(layout: TaskLayout, key: Object, index: usize, range: *Range) ?Object {
        return msg(?Object, layout.storage, "attribute:atIndex:longestEffectiveRange:inRange:", .{
            key, index, range, Range{ .location = 0, .length = layout.length },
        });
    }

    fn box(layout: TaskLayout, index: usize) Rect {
        const glyph = msg(usize, layout.manager, "glyphIndexForCharacterAtIndex:", .{index});
        const bounds = msg(Rect, layout.manager, "boundingRectForGlyphRange:inTextContainer:", .{
            Range{ .location = glyph, .length = 1 }, layout.container,
        });
        return .{
            .origin = .{
                .x = layout.origin.x + bounds.origin.x + 1,
                .y = layout.origin.y + bounds.origin.y + @floor((bounds.size.height - checkbox_size) / 2),
            },
            .size = .{ .width = checkbox_size, .height = checkbox_size },
        };
    }

    fn toggle(layout: TaskLayout, range: Range, checked: bool) void {
        const string = msg(Object, layout.editor, "string", .{});
        const next = range.location + range.length;
        const following = if (next < layout.length) msg(u16, string, "characterAtIndex:", .{next}) else 0;
        const space = following != ' ' and following != '\t' and following != '\r' and following != '\n';
        const value: []const u8 = if (checked)
            (if (space) "- [ ] " else "- [ ]")
        else
            (if (space) "- [x] " else "- [x]");
        msg(void, layout.editor, "insertText:replacementRange:", .{ objc.nsString(value), range });
    }
};

const VisibleMarkers = struct {
    layout: TaskLayout,
    key: Object,
    pos: usize,
    limit: usize,

    fn inRect(editor: Object, bounds: Rect) ?VisibleMarkers {
        const layout = TaskLayout.of(editor) orelse return null;
        var local = bounds;
        local.origin.x -= layout.origin.x;
        local.origin.y -= layout.origin.y;
        const glyphs = msg(Range, layout.manager, "glyphRangeForBoundingRect:inTextContainer:", .{ local, layout.container });
        if (glyphs.length == 0) return null;
        const chars = msg(Range, layout.manager, "characterRangeForGlyphRange:actualGlyphRange:", .{ glyphs, @as(?*Range, null) });
        return .{ .layout = layout, .key = markerKey(), .pos = chars.location, .limit = @min(layout.length, chars.location + chars.length) };
    }

    fn next(markers: *VisibleMarkers) ?struct { box: Rect, kind: Marker } {
        while (markers.pos < markers.limit) {
            var run: Range = undefined;
            const state = markers.layout.attribute(markers.key, markers.pos, &run);
            markers.pos = run.location + run.length;
            if (state) |value| {
                return .{ .box = markers.layout.box(run.location), .kind = .fromAttribute(value) };
            }
        }
        return null;
    }
};

pub fn drawListMarkers(editor: Object, dirty: Rect) void {
    const width = msg(Rect, editor, "bounds", .{}).size.width;
    const padding = msg(objc.CGSize, editor, "textContainerInset", .{}).width;
    // A divider can cross a dirty region even when its source text is to the left.
    var full_row = dirty;
    full_row.origin.x = 0;
    full_row.size.width = width;
    var markers = VisibleMarkers.inRect(editor, full_row) orelse return;
    var tint: ?Object = null;
    while (markers.next()) |marker_item| {
        if (marker_item.kind == .divider) {
            drawDivider(marker_item.box, width - padding - 5);
            continue;
        }
        if (tint == null) tint = markerTint(editor);
        drawMarker(marker_item.box, tint.?, marker_item.kind);
    }
}

pub fn registerTaskCursors(editor: Object) void {
    var markers = VisibleMarkers.inRect(editor, msg(Rect, editor, "visibleRect", .{})) orelse return;
    const hand = msg(Object, objc.class("NSCursor"), "pointingHandCursor", .{});
    while (markers.next()) |item| {
        if (item.kind.isTask()) msg(void, editor, "addCursorRect:cursor:", .{ item.box, hand });
    }
}

fn taskUnderMouse(layout: TaskLayout, event: Object, range: *Range) ?Marker {
    const window_point = msg(Point, event, "locationInWindow", .{});
    const point = msg(Point, layout.editor, "convertPoint:fromView:", .{ window_point, @as(?Object, null) });
    const local: Point = .{ .x = point.x - layout.origin.x, .y = point.y - layout.origin.y };
    const glyph = msg(usize, layout.manager, "glyphIndexForPoint:inTextContainer:", .{ local, layout.container });
    if (glyph >= msg(usize, layout.manager, "numberOfGlyphs", .{})) return null;
    const index = msg(usize, layout.manager, "characterIndexForGlyphAtIndex:", .{glyph});
    if (index >= layout.length) return null;
    const value = layout.attribute(markerKey(), index, range) orelse return null;
    const state = Marker.fromAttribute(value);
    if (!state.isTask()) return null;
    const box = layout.box(range.location);
    if (point.x < box.origin.x or point.x > box.origin.x + box.size.width or
        point.y < box.origin.y or point.y > box.origin.y + box.size.height) return null;
    return state;
}

pub fn hoveringTask(editor: Object, event: Object) bool {
    const layout = TaskLayout.of(editor) orelse return false;
    var range: Range = undefined;
    return taskUnderMouse(layout, event, &range) != null;
}

pub fn clickTask(editor: Object, event: Object) bool {
    const layout = TaskLayout.of(editor) orelse return false;
    var range: Range = undefined;
    const state = taskUnderMouse(layout, event, &range) orelse return false;
    layout.toggle(range, state == .checked);
    return true;
}

pub fn toggleTaskAtSelection(editor: Object) bool {
    const layout = TaskLayout.of(editor) orelse return false;
    const selected = msg(Range, editor, "selectedRange", .{});
    const string = msg(Object, editor, "string", .{});
    const line = msg(Range, string, "lineRangeForRange:", .{Range{ .location = selected.location, .length = 0 }});
    const key = markerKey();
    const limit = @min(layout.length, line.location + line.length);
    var pos = line.location;
    while (pos < limit) {
        var range: Range = undefined;
        if (layout.attribute(key, pos, &range)) |value| {
            const state = Marker.fromAttribute(value);
            if (!state.isTask()) return false;
            layout.toggle(range, state == .checked);
            return true;
        }
        pos = range.location + range.length;
    }
    return false;
}

const Inline = enum { bold_italic, bold, italic, inline_code, strike, link };

const InlineSpan = struct {
    kind: Inline,
    content: []const u8,
    start: usize,
    finish: usize,
    end: usize,
};

fn inlineSpan(line: []const u8, at: usize) ?InlineSpan {
    const patterns = [_]struct { open: []const u8, kind: Inline }{
        .{ .open = "***", .kind = .bold_italic },
        .{ .open = "___", .kind = .bold_italic },
        .{ .open = "**", .kind = .bold },
        .{ .open = "__", .kind = .bold },
        .{ .open = "*", .kind = .italic },
        .{ .open = "_", .kind = .italic },
        .{ .open = "`", .kind = .inline_code },
        .{ .open = "~~", .kind = .strike },
        .{ .open = "[", .kind = .link },
    };
    for (patterns) |pattern| {
        if (!std.mem.startsWith(u8, line[at..], pattern.open)) continue;
        if (pattern.open[0] == '_' and at > 0 and std.ascii.isAlphanumeric(line[at - 1])) continue;
        const start = at + pattern.open.len;
        const close = if (pattern.kind == .link) "](" else pattern.open;
        const finish = (std.mem.indexOf(u8, line[start..], close) orelse continue) + start;
        const content = line[start..finish];
        if (content.len == 0 or std.ascii.isWhitespace(content[0]) or std.ascii.isWhitespace(content[content.len - 1])) continue;
        var end = finish + close.len;
        if (pattern.kind == .link) {
            const right = std.mem.indexOfScalar(u8, line[end..], ')') orelse continue;
            const target = line[end .. end + right];
            if (!std.mem.startsWith(u8, target, "https://") and !std.mem.startsWith(u8, target, "http://")) continue;
            end += right + 1;
        }
        return .{ .kind = pattern.kind, .content = content, .start = start, .finish = finish, .end = end };
    }
    return null;
}

fn inlineFormat(storage: Object, line: []const u8, offset: usize, active: bool, size: f64) void {
    var i: usize = 0;
    while (i < line.len) {
        if (line[i] == '\\') {
            i += @min(2, line.len - i);
            continue;
        }
        const span = inlineSpan(line, i) orelse {
            i += 1;
            continue;
        };
        const start = offset + len16(line[0..span.start]);
        switch (span.kind) {
            .bold => attr(storage, NSFontAttributeName, font(size, 0.4), start, span.content),
            .italic, .bold_italic => {
                const manager = msg(Object, objc.class("NSFontManager"), "sharedFontManager", .{});
                const weight: f64 = if (span.kind == .bold_italic) 0.4 else 0;
                const italic = msg(Object, manager, "convertFont:toHaveTrait:", .{ font(size, weight), @as(usize, 1) });
                attr(storage, NSFontAttributeName, italic, start, span.content);
            },
            .inline_code => {
                attr(storage, NSFontAttributeName, mono(size - 1), start, span.content);
                attr(storage, NSBackgroundColorAttributeName, color("quaternaryLabelColor"), start, span.content);
            },
            .strike => strike(storage, start, span.content),
            .link => {
                const target = line[span.finish + 2 .. span.end - 1];
                if (msg(?Object, objc.class("NSURL"), "URLWithString:", .{objc.nsString(target)})) |url| {
                    attr(storage, NSLinkAttributeName, url, start, span.content);
                } else {
                    i += 1;
                    continue;
                }
            },
        }
        marker(storage, offset + len16(line[0..i]), line[i..span.start], active);
        marker(storage, start + len16(span.content), line[span.finish..span.end], active);
        i = span.end;
    }
}

fn heading(line: []const u8) usize {
    const count = std.mem.indexOfNone(u8, line, "#") orelse return 0;
    return if (count >= 1 and count <= 6 and line[count] == ' ') count else 0;
}

fn appendTitle(buf: []u8, used: *usize, text: []const u8) bool {
    const available = @min(buf.len - used.*, text.len);
    var length = available;
    while (length > 0 and length < text.len and text[length] & 0xc0 == 0x80) length -= 1;
    @memcpy(buf[used.*..][0..length], text[0..length]);
    used.* += length;
    return available == text.len;
}

pub fn title(buf: []u8, source: []const u8) []const u8 {
    var lines = std.mem.splitScalar(u8, source, '\n');
    var fenced = false;
    while (lines.next()) |raw| {
        var line = std.mem.trimStart(u8, raw, " \t\r");
        if (fence(line)) {
            fenced = !fenced;
            continue;
        }
        if (!fenced) {
            while (std.mem.startsWith(u8, line, "> ") or std.mem.startsWith(u8, line, ">\t")) {
                line = std.mem.trimStart(u8, line[1..], " \t");
            }
            if (divider(line) or std.mem.eql(u8, line, ">")) continue;
            var list_buf: [16]u8 = undefined;
            const level = heading(line);
            if (level > 0) {
                line = std.mem.trim(u8, line[level + 1 ..], " \t\r");
                const closing = std.mem.trimEnd(u8, line, "#");
                if (closing.len < line.len and closing.len > 0 and std.ascii.isWhitespace(closing[closing.len - 1])) {
                    line = closing;
                }
            } else if (listItem(line, &list_buf)) |item| line = line[item.prefix_len..];
        }
        line = std.mem.trim(u8, line, " \t\r");
        if (line.len == 0) continue;
        if (!fenced and line.len <= 6 and std.mem.indexOfNone(u8, line, "#") == null) continue;
        var used: usize = 0;
        if (fenced) {
            _ = appendTitle(buf, &used, line);
            return buf[0..used];
        }
        var index: usize = 0;
        while (index < line.len and used < buf.len) {
            if (line[index] == '\\' and index + 1 < line.len and std.ascii.isPunctuation(line[index + 1])) {
                index += 1;
            } else if (inlineSpan(line, index)) |span| {
                if (!appendTitle(buf, &used, span.content)) break;
                index = span.end;
                continue;
            }
            const length = std.unicode.utf8ByteSequenceLength(line[index]) catch 1;
            const end = @min(line.len, index + length);
            if (!appendTitle(buf, &used, line[index..end])) break;
            index = end;
        }
        if (used > 0) return buf[0..used];
    }
    return "Untitled Note";
}

pub fn style(editor: Object, active: bool) void {
    if (msg(bool, editor, "hasMarkedText", .{})) return;
    defer if (msg(?Object, editor, "window", .{})) |window| {
        msg(void, window, "invalidateCursorRectsForView:", .{editor});
    };
    const storage = msg(Object, editor, "textStorage", .{});
    const text = objc.fromNSString(msg(Object, editor, "string", .{}));
    if (text.len == 0) return;
    const selected = msg(Range, editor, "selectedRange", .{});
    const all: Range = .{ .location = 0, .length = len16(text) };
    const font_key = NSFontAttributeName;
    const text_key = NSForegroundColorAttributeName;
    const attrs = msg(Object, objc.class("NSMutableDictionary"), "dictionary", .{});
    msg(void, attrs, "setObject:forKey:", .{ font(14, 0), font_key });
    msg(void, attrs, "setObject:forKey:", .{ color("labelColor"), text_key });
    msg(void, storage, "beginEditing", .{});
    defer msg(void, storage, "endEditing", .{});
    msg(void, storage, "setAttributes:range:", .{ attrs, all });

    var lines = std.mem.splitScalar(u8, text, '\n');
    var offset: usize = 0;
    var fenced = false;
    while (lines.next()) |line| {
        const start = offset;
        const length = len16(line);
        offset += length + 1;
        const on_line = active and selected.location <= start + length and selected.location +| selected.length >= start;
        const trimmed = std.mem.trimStart(u8, line, " \t");
        const indent = line.len - trimmed.len;
        if (fence(trimmed)) {
            fenced = !fenced;
            attr(storage, font_key, mono(12), start, line);
            attr(storage, text_key, color("secondaryLabelColor"), start, line);
            continue;
        }
        if (fenced) {
            attr(storage, font_key, mono(13), start, line);
            continue;
        }

        var size: f64 = 14;
        var prefix: usize = 0;
        const level = heading(trimmed);
        if (divider(trimmed)) {
            listMarkerStyle(storage, start + indent, trimmed[0..3], .divider);
            continue;
        } else if (taskPrefix(trimmed)) |task| {
            listMarkerStyle(storage, start + indent, trimmed[0..task.length], if (task.checked) .checked else .unchecked);
            if (task.checked) attr(storage, text_key, color("secondaryLabelColor"), start + indent + task.length, trimmed[task.length..]);
            inlineFormat(storage, trimmed[task.length..], start + indent + task.length, on_line, size);
            continue;
        } else if (bulletPrefix(trimmed)) {
            listMarkerStyle(storage, start + indent, trimmed[0..1], .bullet);
            inlineFormat(storage, trimmed[1..], start + indent + 1, on_line, size);
            continue;
        } else if (level > 0) {
            size = if (level == 1) 22 else if (level == 2) 18 else 15;
            prefix = level + 1;
            attr(storage, font_key, font(size, 0.35), start, line);
        } else if (std.mem.startsWith(u8, trimmed, "> ")) {
            attr(storage, text_key, color("secondaryLabelColor"), start, line);
        }
        marker(storage, start + indent, trimmed[0..prefix], on_line);
        inlineFormat(storage, trimmed[prefix..], start + indent + prefix, on_line, size);
    }
}

test "checkbox shortcuts include compact and standard Markdown markers" {
    for ([_][]const u8{ "[]", "[ ]", "-[]", "-[ ]", "- []", "- [ ]" }) |input| {
        const task = taskPrefix(input).?;
        try std.testing.expectEqual(input.len, task.length);
        try std.testing.expect(!task.checked);
    }
    try std.testing.expect(taskPrefix("- [x] Done").?.checked);
    try std.testing.expect(taskPrefix("[X] Done").?.checked);
    for ([_][]const u8{ "", "- [", "[ ](https://example.com)", "text []", "\\[]" }) |input| {
        try std.testing.expect(taskPrefix(input) == null);
    }
}

test "Return continues checklist, bulleted and numbered items" {
    var buffer: [16]u8 = undefined;
    for ([_][]const u8{ "[] First", "[ ] Second", "-[] Third", "-[ ] Fourth", "- [x] Done" }) |input| {
        const item = listItem(input, &buffer).?;
        try std.testing.expectEqualStrings("- [ ] ", item.next);
        try std.testing.expect(!item.empty);
    }
    try std.testing.expectEqualStrings("- ", listItem("- Text", &buffer).?.next);
    try std.testing.expectEqualStrings("* ", listItem("* Text", &buffer).?.next);
    const nested = listItem("  + Nested", &buffer).?;
    try std.testing.expectEqualStrings("  ", nested.indent);
    try std.testing.expectEqualStrings("+ ", nested.next);
    try std.testing.expectEqualStrings("10. ", listItem("9. Ninth", &buffer).?.next);
    try std.testing.expectEqualStrings("3) ", listItem("2) Second", &buffer).?.next);
    try std.testing.expectEqual(4, listItem("1.  ", &buffer).?.prefix_len);
    try std.testing.expect(listItem("- [ ]  ", &buffer).?.empty);
    try std.testing.expect(listItem("**Bold**", &buffer) == null);
    try std.testing.expect(listItem("2.not a list", &buffer) == null);
    try std.testing.expect(insideFence("```sh\n- code\n"));
    try std.testing.expect(!insideFence("```sh\n- code\n```\n"));
}

test "a standalone row of three dashes is a divider" {
    try std.testing.expect(divider("---"));
    try std.testing.expect(divider("---  "));
    try std.testing.expect(!divider("--- text"));
    try std.testing.expect(!divider("--"));
    try std.testing.expect(!divider("\\---"));
}

test "note titles use visible Markdown text and preserve literal punctuation" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("hello", title(&buf, "`hello`"));
    try std.testing.expectEqualStrings("Draft 🌿", title(&buf, "# Draft 🌿"));
    try std.testing.expectEqualStrings("Read docs and code", title(&buf, "---\n\n> - [x] ***Read*** [docs](https://example.com) and `code`"));
    try std.testing.expectEqualStrings("italic and gone", title(&buf, "_italic_ and ~~gone~~"));
    try std.testing.expectEqualStrings("#tag, C++, a*b, file_name_here", title(&buf, "#tag, C++, a*b, file_name_here"));
    try std.testing.expectEqualStrings("*literal*", title(&buf, "\\*literal\\*"));
    try std.testing.expectEqualStrings("a * b", title(&buf, "```zig\na * b\n```"));
    try std.testing.expectEqualStrings("Untitled Note", title(&buf, "---\n[]\n* "));
    try std.testing.expectEqualStrings("Hi ", title(buf[0..5], "`Hi 🌿`"));
}

test "headings require a Markdown separator and use UTF-16 units for AppKit" {
    try std.testing.expectEqual(1, heading("# Release 🌿"));
    try std.testing.expectEqual(0, heading("#hashtag"));
    try std.testing.expectEqual(0, heading("####### Too many"));
    try std.testing.expectEqual(4, len16("A 🌿"));
}
