//! Native floating notes. AppKit owns the controls and Zig owns their state.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const model = @import("notes_store.zig");
const markdown = @import("notes_markdown.zig");
const popover_material = @import("popover_material_mac.zig");
const Object = objc.Object;
const msg = objc.msg;
const Size = objc.CGSize;
const Rect = objc.CGRect;
const min_width = 280;
const min_height = 200;
const title_height = 34;
const command_mask = 1 << 20;
const floating_spaces: usize = (1 << 0) | (1 << 4) | (1 << 8) | (1 << 18); // All Spaces, stationary, full-screen auxiliary, all apps.

pub const new_path = "sticky-notes:new";
pub const library_path = "sticky-notes:library";

const Panel = struct {
    notes: *Notes,
    id: ?[]const u8,
    window: Object,
    delegate: Object,
    heading: ?Object = null,
    editor: ?Object = null,
    pointer_over_task: bool = false,
    search: ?Object = null,
    table: ?Object = null,
    status: ?Object = null,
    matches: std.ArrayList(usize) = .empty,

    fn setTitle(panel: *Panel, label: Object) void {
        msg(void, panel.window, "setTitle:", .{label});
        if (panel.heading) |heading| msg(void, heading, "setStringValue:", .{label});
    }

    fn show(panel: *Panel, focus: bool) void {
        msg(void, panel.window, "orderFrontRegardless", .{});
        if (focus) msg(void, panel.window, "makeKeyWindow", .{});
    }

    fn destroy(panel: *Panel) void {
        const gpa = panel.notes.store.gpa;
        msg(void, panel.window, "setDelegate:", .{@as(?Object, null)});
        msg(void, panel.window, "orderOut:", .{@as(?Object, null)});
        if (panel.editor) |editor| objc.setZig(editor, null);
        objc.setZig(panel.window, null);
        objc.release(panel.window);
        objc.release(panel.delegate);
        panel.matches.deinit(gpa);
        gpa.destroy(panel);
    }
};

fn noteTitle(note: model.Note) Object {
    var buffer: [256]u8 = undefined;
    return objc.nsString(markdown.title(&buffer, note.text()));
}

pub const Notes = struct {
    store: model.Store,
    panels: std.ArrayList(*Panel) = .empty,
    library: ?*Panel = null,
    load_failed: bool = false,
    dirty: bool = false,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) !Notes {
        const directory = if (env.get("NANOLIGHT_NOTES_DATA_DIR")) |path|
            try gpa.dupe(u8, path)
        else
            try nanoui.path(gpa, .data, "Nanolight Notes");
        defer gpa.free(directory);
        const path = try std.fs.path.join(gpa, &.{ directory, "notes.json" });
        var notes: Notes = .{ .store = .{ .gpa = gpa, .io = io, .path = path } };
        notes.store.load() catch |err| {
            std.log.err("Could not read sticky notes: {s}", .{@errorName(err)});
            notes.load_failed = true;
        };
        return notes;
    }

    pub fn restore(notes: *Notes) void {
        if (notes.load_failed) return;
        const pool = objc.Pool.push();
        defer pool.pop();
        for (notes.store.notes.items) |note| {
            if (note.visible) notes.showNote(note.id, false);
        }
    }

    pub fn deinit(notes: *Notes) void {
        if (notes.library) |library| library.destroy();
        for (notes.panels.items) |panel| panel.destroy();
        notes.panels.deinit(notes.store.gpa);
        notes.store.deinit();
    }

    fn ready(notes: *Notes) bool {
        if (!notes.load_failed) return true;
        alert("Unable to open sticky notes", "The saved notes file is unchanged. Check its permissions or restore it from a backup.");
        return false;
    }

    fn save(notes: *Notes) bool {
        notes.store.save() catch |err| {
            std.log.err("Could not save sticky notes: {s}", .{@errorName(err)});
            notes.saveStatus(false);
            return false;
        };
        notes.dirty = false;
        notes.saveStatus(true);
        return true;
    }

    fn saveStatus(notes: *Notes, saved: bool) void {
        for (notes.panels.items) |panel| {
            if (panel.status) |status| msg(void, status, "setStringValue:", .{objc.nsString(if (saved) "" else "Unsaved")});
        }
    }

    fn finishEdit(notes: *Notes, index: usize, choice: model.EditChoice, close: bool) bool {
        notes.store.finishEdit(index, choice, close) catch |err| {
            std.log.err("Could not save sticky notes: {s}", .{@errorName(err)});
            notes.saveStatus(false);
            alert("Unable to save notes", "Your edits are still open. Check the storage location and try again.");
            return false;
        };
        notes.dirty = false;
        notes.saveStatus(true);
        return true;
    }

    pub fn new(notes: *Notes) void {
        const pool = objc.Pool.push();
        defer pool.pop();
        if (!notes.ready()) return;
        const gpa = notes.store.gpa;
        const uuid = msg(Object, objc.class("NSUUID"), "UUID", .{});
        const id = gpa.dupe(u8, objc.fromNSString(msg(Object, uuid, "UUIDString", .{}))) catch return;
        const text = gpa.dupe(u8, "") catch {
            gpa.free(id);
            return;
        };
        const screen = msg(Object, objc.class("NSScreen"), "mainScreen", .{});
        const frame = msg(Rect, screen, "visibleFrame", .{});
        const offset: f64 = @floatFromInt((notes.panels.items.len % 6) * 22);
        notes.store.notes.append(gpa, .{
            .id = id,
            .markdown = text,
            .x = frame.origin.x + (frame.size.width - 390) / 2 + offset,
            .y = frame.origin.y + (frame.size.height - 320) / 2 - offset,
        }) catch {
            gpa.free(id);
            gpa.free(text);
            return;
        };
        notes.dirty = true;
        notes.showNote(id, true);
        _ = notes.save();
    }

    pub fn browse(notes: *Notes) void {
        const pool = objc.Pool.push();
        defer pool.pop();
        if (!notes.ready()) return;
        const panel = notes.library orelse buildPanel(notes, null) catch return;
        notes.library = panel;
        reload(panel);
        panel.show(true);
    }

    fn showNote(notes: *Notes, id: []const u8, focus: bool) void {
        const index = notes.store.find(id) orelse return;
        const note = &notes.store.notes.items[index];
        for (notes.panels.items) |panel| {
            if (std.mem.eql(u8, panel.id.?, id)) {
                notes.showNotePanel(panel, note, focus);
                return;
            }
        }
        const panel = buildPanel(notes, note.*) catch return;
        notes.panels.append(notes.store.gpa, panel) catch {
            panel.destroy();
            return;
        };
        notes.showNotePanel(panel, note, focus);
    }

    fn showNotePanel(notes: *Notes, panel: *Panel, note: *model.Note, focus: bool) void {
        panel.show(focus);
        if (!note.visible) {
            note.visible = true;
            notes.dirty = true;
            _ = notes.save();
        }
        if (notes.library) |library| reload(library);
    }

    fn delete(notes: *Notes, id: []const u8) void {
        const index = notes.store.find(id) orelse return;
        if (!confirmDelete(noteTitle(notes.store.notes.items[index]))) return;
        const note = notes.store.notes.orderedRemove(index);
        if (!notes.save()) {
            notes.store.notes.insertAssumeCapacity(index, note);
            alert("Unable to delete note", "The note is still in your library.");
            return;
        }
        for (notes.panels.items, 0..) |panel, i| {
            if (std.mem.eql(u8, panel.id.?, id)) {
                panel.destroy();
                _ = notes.panels.orderedRemove(i);
                break;
            }
        }
        notes.store.free(note);
        if (notes.library) |library| reload(library);
    }
};

fn canBecomeKey(_: Object, _: objc.SEL) callconv(.c) bool {
    return true;
}

fn panelKeyEquivalent(window: Object, _: objc.SEL, event: Object) callconv(.c) bool {
    if (objc.getZig(Panel, window)) |panel| if (panel.id != null and
        (msg(usize, event, "modifierFlags", .{}) & (0xf << 17)) == command_mask)
    {
        const key = objc.fromNSString(msg(?Object, event, "charactersIgnoringModifiers", .{}));
        if (key.len == 1) switch (key[0]) {
            'n' => {
                panel.notes.new();
                return true;
            },
            'p' => {
                panel.notes.browse();
                return true;
            },
            's' => {
                savePanel(panel);
                return true;
            },
            'w' => {
                msg(void, window, "performClose:", .{@as(?Object, null)});
                return true;
            },
            '\r' => if (panel.editor) |editor| {
                if (msg(?Object, window, "firstResponder", .{}) == editor and markdown.toggleTaskAtSelection(editor)) return true;
            },
            else => {},
        };
    };
    return objc.msgSuper(bool, window, objc.class("NSPanel"), "performKeyEquivalent:", .{event});
}

fn panelClass() objc.Class {
    return objc.defineClass(.{
        .name = "NanolightStickyPanel",
        .superclass = "NSPanel",
        .methods = &.{
            .{ .name = "canBecomeKeyWindow", .imp = &canBecomeKey, .types = "B@:" },
            .{ .name = "performKeyEquivalent:", .imp = &panelKeyEquivalent, .types = "B@:@" },
        },
    });
}

fn pastePlainText(editor: Object, _: objc.SEL, sender: ?Object) callconv(.c) void {
    msg(void, editor, "pasteAsPlainText:", .{sender});
}

fn drawEditor(editor: Object, _: objc.SEL, dirty: Rect) callconv(.c) void {
    objc.msgSuper(void, editor, objc.class("NSTextView"), "drawRect:", .{dirty});
    markdown.drawListMarkers(editor, dirty);
}

fn editorMouseDown(editor: Object, _: objc.SEL, event: Object) callconv(.c) void {
    if (!markdown.clickTask(editor, event)) {
        objc.msgSuper(void, editor, objc.class("NSTextView"), "mouseDown:", .{event});
    }
}

fn editorCursorRects(editor: Object, _: objc.SEL) callconv(.c) void {
    objc.msgSuper(void, editor, objc.class("NSTextView"), "resetCursorRects", .{});
    markdown.registerTaskCursors(editor);
}

fn editorTrackPointer(editor: Object, selector: objc.SEL, event: Object) callconv(.c) void {
    const method: [:0]const u8 = if (selector == objc.sel("mouseEntered:"))
        "mouseEntered:"
    else if (selector == objc.sel("mouseExited:"))
        "mouseExited:"
    else if (selector == objc.sel("cursorUpdate:"))
        "cursorUpdate:"
    else
        "mouseMoved:";
    const panel = objc.getZig(Panel, editor) orelse return;
    const over_task = selector != objc.sel("mouseExited:") and markdown.hoveringTask(editor, event);
    const cursors = objc.class("NSCursor");
    const hand = msg(Object, cursors, "pointingHandCursor", .{});
    if (over_task) {
        msg(void, hand, "set", .{});
    } else {
        if (panel.pointer_over_task and msg(Object, cursors, "currentCursor", .{}) == hand) {
            const cursor = if (selector == objc.sel("mouseExited:")) msg(Object, cursors, "arrowCursor", .{}) else msg(Object, cursors, "IBeamCursor", .{});
            msg(void, cursor, "set", .{});
        }
        objc.msgSuper(void, editor, objc.class("NSTextView"), method, .{event});
    }
    panel.pointer_over_task = over_task;
}

fn editorNewline(editor: Object, _: objc.SEL, sender: ?Object) callconv(.c) void {
    if (!markdown.continueList(editor)) {
        objc.msgSuper(void, editor, objc.class("NSTextView"), "insertNewline:", .{sender});
    }
}

fn editorClass() objc.Class {
    return objc.defineClass(.{
        .name = "NanolightStickyEditor",
        .superclass = "NSTextView",
        .methods = &.{
            .{ .name = "paste:", .imp = &pastePlainText, .types = "v@:@" },
            .{ .name = "drawRect:", .imp = &drawEditor, .types = "v@:{CGRect={CGPoint=dd}{CGSize=dd}}" },
            .{ .name = "mouseDown:", .imp = &editorMouseDown, .types = "v@:@" },
            .{ .name = "resetCursorRects", .imp = &editorCursorRects, .types = "v@:" },
            .{ .name = "mouseEntered:", .imp = &editorTrackPointer, .types = "v@:@" },
            .{ .name = "mouseExited:", .imp = &editorTrackPointer, .types = "v@:@" },
            .{ .name = "mouseMoved:", .imp = &editorTrackPointer, .types = "v@:@" },
            .{ .name = "cursorUpdate:", .imp = &editorTrackPointer, .types = "v@:@" },
            .{ .name = "insertNewline:", .imp = &editorNewline, .types = "v@:@" },
        },
    });
}

fn delegateClass() objc.Class {
    return objc.defineClass(.{
        .name = "NanolightStickyDelegate",
        .protocols = &.{ "NSWindowDelegate", "NSTextViewDelegate", "NSTableViewDataSource", "NSSearchFieldDelegate" },
        .methods = &.{
            .{ .name = "windowShouldClose:", .imp = &shouldClose, .types = "B@:@" },
            .{ .name = "windowDidMove:", .imp = &frameChanged, .types = "v@:@" },
            .{ .name = "windowDidEndLiveResize:", .imp = &frameChanged, .types = "v@:@" },
            .{ .name = "windowDidBecomeKey:", .imp = &focusChanged, .types = "v@:@" },
            .{ .name = "windowDidResignKey:", .imp = &focusChanged, .types = "v@:@" },
            .{ .name = "textDidChange:", .imp = &textChanged, .types = "v@:@" },
            .{ .name = "textViewDidChangeSelection:", .imp = &focusChanged, .types = "v@:@" },
            .{ .name = "controlTextDidChange:", .imp = &searchChanged, .types = "v@:@" },
            .{ .name = "numberOfRowsInTableView:", .imp = &rowCount, .types = "q@:@" },
            .{ .name = "tableView:objectValueForTableColumn:row:", .imp = &rowValue, .types = "@@:@@q" },
            .{ .name = "openNote:", .imp = &openSelected, .types = "v@:@" },
            .{ .name = "newNote:", .imp = &newNote, .types = "v@:@" },
            .{ .name = "browseNotes:", .imp = &browseNotes, .types = "v@:@" },
            .{ .name = "deleteNote:", .imp = &deleteNote, .types = "v@:@" },
            .{ .name = "saveNote:", .imp = &saveNote, .types = "v@:@" },
            .{ .name = "noteActions:", .imp = &showActions, .types = "v@:@" },
        },
    });
}

fn rect(x: f64, y: f64, width: f64, height: f64) Rect {
    return .{ .origin = .{ .x = x, .y = y }, .size = .{ .width = width, .height = height } };
}

fn buildPanel(notes: *Notes, note: ?model.Note) !*Panel {
    const panel = try notes.store.gpa.create(Panel);
    const frame = if (note) |n| rect(n.x, n.y, n.width, n.height) else rect(0, 0, 420, 372);
    const style: usize = 1 | 2 | 8 | 128 | (1 << 15);
    const window = msg(Object, msg(Object, panelClass(), "alloc", .{}), "initWithContentRect:styleMask:backing:defer:", .{ frame, style, @as(usize, 2), false });
    const delegate = msg(Object, delegateClass(), "new", .{});
    panel.* = .{ .notes = notes, .window = window, .delegate = delegate, .id = if (note) |n| n.id else null };
    objc.setZig(delegate, panel);
    objc.setZig(window, panel);
    msg(void, window, "setReleasedWhenClosed:", .{false});
    msg(void, window, "setOpaque:", .{false});
    msg(void, window, "setBackgroundColor:", .{msg(Object, objc.class("NSColor"), "clearColor", .{})});
    msg(void, window, "setTitlebarAppearsTransparent:", .{true});
    msg(void, window, "setMinSize:", .{Size{ .width = min_width, .height = min_height }});
    msg(void, window, "setFloatingPanel:", .{true});
    msg(void, window, "setHidesOnDeactivate:", .{false});
    msg(void, window, "setLevel:", .{@as(isize, 3)});
    msg(void, window, "setCollectionBehavior:", .{floating_spaces});
    if (note == null) {
        msg(void, window, "center", .{});
    } else {
        msg(void, window, "setFrame:display:", .{ frame, false });
        if (msg(?Object, window, "screen", .{}) == null) msg(void, window, "center", .{});
    }

    const content = msg(Object, window, "contentView", .{});
    const bounds = msg(Rect, content, "bounds", .{});
    const material = popover_material.create(bounds);
    msg(void, material, "setAutoresizingMask:", .{@as(usize, 2 | 16)});
    msg(void, content, "addSubview:", .{material});
    objc.release(material);
    if (note) |n| {
        buildTitleBar(panel, content, bounds.size);
        buildEditor(panel, content, bounds.size, n);
    } else {
        const layout = msg(Rect, window, "contentLayoutRect", .{});
        const controls_frame = msg(Rect, content, "convertRect:fromView:", .{ layout, @as(?Object, null) });
        const controls = msg(Object, objc.alloc("NSView"), "initWithFrame:", .{controls_frame});
        msg(void, controls, "setAutoresizingMask:", .{@as(usize, 2 | 16)});
        msg(void, content, "addSubview:", .{controls});
        buildLibrary(panel, controls, controls_frame.size);
        objc.release(controls);
    }
    panel.setTitle(if (note) |n| noteTitle(n) else objc.nsString("Sticky Notes"));
    msg(void, window, "setDelegate:", .{delegate});
    return panel;
}

fn button(panel: *Panel, container: Object, title: []const u8, help: []const u8, sel: [:0]const u8, frame: Rect, mask: usize) Object {
    const control = msg(Object, objc.class("NSButton"), "buttonWithTitle:target:action:", .{
        objc.nsString(title), panel.delegate, objc.sel(sel),
    });
    msg(void, control, "setFrame:", .{frame});
    msg(void, control, "setAutoresizingMask:", .{mask});
    msg(void, control, "setToolTip:", .{objc.nsString(help)});
    msg(void, control, "setAccessibilityLabel:", .{objc.nsString(help)});
    msg(void, container, "addSubview:", .{control});
    return control;
}

fn scrollView(container: Object, frame: Rect) Object {
    const scroll = msg(Object, objc.alloc("NSScrollView"), "initWithFrame:", .{frame});
    msg(void, scroll, "setDrawsBackground:", .{false});
    msg(void, scroll, "setAutoresizingMask:", .{@as(usize, 2 | 16)});
    msg(void, scroll, "setHasVerticalScroller:", .{true});
    msg(void, scroll, "setAutohidesScrollers:", .{true});
    msg(void, container, "addSubview:", .{scroll});
    objc.release(scroll);
    return scroll;
}

fn titleHit(view: Object, _: objc.SEL, point: objc.CGPoint) callconv(.c) ?Object {
    // Let clicks through the title label drag the window as well.
    return if (objc.msgSuper(?Object, view, objc.class("NSView"), "hitTest:", .{point}) != null) view else null;
}

fn titleDrag(view: Object, _: objc.SEL, event: Object) callconv(.c) void {
    const window = msg(Object, view, "window", .{});
    msg(void, window, "performWindowDragWithEvent:", .{event});
}

fn buildTitleBar(panel: *Panel, content: Object, size: Size) void {
    msg(void, panel.window, "setTitleVisibility:", .{@as(isize, 1)});
    for ([_]usize{ 1, 2 }) |kind| {
        if (msg(?Object, panel.window, "standardWindowButton:", .{kind})) |control| {
            msg(void, control, "setHidden:", .{true});
        }
    }

    const class = objc.defineClass(.{
        .name = "NanolightStickyTitleBar",
        .superclass = "NSView",
        .methods = &.{
            .{ .name = "hitTest:", .imp = &titleHit, .types = "@@:{CGPoint=dd}" },
            .{ .name = "mouseDown:", .imp = &titleDrag, .types = "v@:@" },
        },
    });
    const bar = msg(Object, msg(Object, class, "alloc", .{}), "initWithFrame:", .{rect(0, size.height - title_height, size.width, title_height)});
    msg(void, bar, "setAutoresizingMask:", .{@as(usize, 2 | 8)});
    msg(void, content, "addSubview:", .{bar});
    objc.release(bar);

    const heading = msg(Object, objc.class("NSTextField"), "labelWithString:", .{objc.nsString("")});
    const center_alignment: isize = if (@import("builtin").cpu.arch == .aarch64) 1 else 2;
    msg(void, heading, "setAlignment:", .{center_alignment});
    msg(void, heading, "setLineBreakMode:", .{@as(usize, 4)});
    msg(void, heading, "setFont:", .{msg(Object, objc.class("NSFont"), "systemFontOfSize:weight:", .{ @as(f64, 13), @as(f64, 0.23) })});
    msg(void, heading, "setFrame:", .{rect(42, 8, size.width - 84, 17)});
    msg(void, heading, "setAutoresizingMask:", .{@as(usize, 2)});
    msg(void, bar, "addSubview:", .{heading});
    panel.heading = heading;
}

fn buildEditor(panel: *Panel, content: Object, size: Size, note: model.Note) void {
    const height = size.height - 35 - title_height;
    const scroll = scrollView(content, rect(0, 35, size.width, height));
    const editor = msg(Object, msg(Object, editorClass(), "alloc", .{}), "initWithFrame:", .{rect(0, 0, size.width, height)});
    panel.editor = editor;
    objc.setZig(editor, panel);
    msg(void, editor, "setDrawsBackground:", .{false});
    // Keep Markdown as the source or undo and paste would also change the formatting.
    msg(void, editor, "setImportsGraphics:", .{false});
    msg(void, editor, "setAutomaticQuoteSubstitutionEnabled:", .{false});
    msg(void, editor, "setAutomaticDashSubstitutionEnabled:", .{false});
    msg(void, editor, "setAllowsUndo:", .{true});
    msg(void, editor, "setVerticallyResizable:", .{true});
    msg(void, editor, "setHorizontallyResizable:", .{false});
    msg(void, editor, "setAutoresizingMask:", .{@as(usize, 2)});
    msg(void, editor, "setTextContainerInset:", .{Size{ .width = 14, .height = 13 }});
    msg(void, editor, "setAccessibilityLabel:", .{objc.nsString("Note text")});
    const text_container = msg(Object, editor, "textContainer", .{});
    msg(void, text_container, "setWidthTracksTextView:", .{true});
    msg(void, editor, "setFont:", .{msg(Object, objc.class("NSFont"), "systemFontOfSize:", .{@as(f64, 14)})});
    msg(void, editor, "setString:", .{objc.nsString(note.text())});
    markdown.style(editor, false);
    msg(void, editor, "setDelegate:", .{panel.delegate});
    msg(void, scroll, "setDocumentView:", .{editor});
    msg(void, panel.window, "setInitialFirstResponder:", .{editor});
    msg(void, panel.window, "setAcceptsMouseMovedEvents:", .{true});
    // NSTextView's I-beam can win over cursor rectangles, so track motion too.
    const tracking = msg(Object, objc.alloc("NSTrackingArea"), "initWithRect:options:owner:userInfo:", .{
        Rect{}, @as(usize, 0x01 | 0x02 | 0x80 | 0x200), editor, @as(?Object, null),
    });
    msg(void, editor, "addTrackingArea:", .{tracking});
    objc.release(tracking);
    objc.release(editor);

    const more = button(panel, content, "", "More actions (⌘K)", "noteActions:", rect(size.width - 35, 6, 29, 24), 1);
    const ellipsis = msg(Object, objc.class("NSImage"), "imageWithSystemSymbolName:accessibilityDescription:", .{
        objc.nsString("ellipsis"), @as(?Object, null),
    });
    msg(void, more, "setImage:", .{ellipsis});
    msg(void, more, "setShowsBorderOnlyWhileMouseInside:", .{true});
    shortcut(more, "k");
    const status = msg(Object, objc.class("NSTextField"), "labelWithString:", .{objc.nsString("")});
    msg(void, status, "setFrame:", .{rect(14, 9, 110, 19)});
    msg(void, status, "setTextColor:", .{msg(Object, objc.class("NSColor"), "systemRedColor", .{})});
    msg(void, content, "addSubview:", .{status});
    panel.status = status;
}

fn shortcut(control: Object, key: []const u8) void {
    msg(void, control, "setKeyEquivalent:", .{objc.nsString(key)});
    msg(void, control, "setKeyEquivalentModifierMask:", .{@as(usize, command_mask)});
}

fn buildLibrary(panel: *Panel, content: Object, size: Size) void {
    const search = msg(Object, objc.alloc("NSSearchField"), "initWithFrame:", .{rect(10, size.height - 34, size.width - 55, 26)});
    msg(void, search, "setPlaceholderString:", .{objc.nsString("Search notes")});
    msg(void, search, "setDelegate:", .{panel.delegate});
    msg(void, search, "setAutoresizingMask:", .{@as(usize, 2 | 8)});
    msg(void, content, "addSubview:", .{search});
    msg(void, panel.window, "setInitialFirstResponder:", .{search});
    panel.search = search;
    objc.release(search);
    shortcut(button(panel, content, "+", "New note (⌘N)", "newNote:", rect(size.width - 38, size.height - 33, 29, 24), 1 | 8), "n");

    const scroll = scrollView(content, rect(0, 35, size.width, size.height - 73));
    const table = msg(Object, objc.alloc("NSTableView"), "initWithFrame:", .{rect(0, 0, size.width, size.height - 73)});
    msg(void, table, "setBackgroundColor:", .{msg(Object, objc.class("NSColor"), "clearColor", .{})});
    const column = msg(Object, objc.alloc("NSTableColumn"), "initWithIdentifier:", .{objc.nsString("Note")});
    msg(void, column, "setWidth:", .{size.width - 10});
    msg(void, msg(Object, column, "dataCell", .{}), "setEditable:", .{false});
    msg(void, column, "setResizingMask:", .{@as(usize, 1)});
    msg(void, table, "addTableColumn:", .{column});
    objc.release(column);
    msg(void, table, "setHeaderView:", .{@as(?Object, null)});
    msg(void, table, "setRowHeight:", .{@as(f64, 30)});
    msg(void, table, "setDataSource:", .{panel.delegate});
    msg(void, table, "setTarget:", .{panel.delegate});
    msg(void, table, "setDoubleAction:", .{objc.sel("openNote:")});
    msg(void, scroll, "setDocumentView:", .{table});
    panel.table = table;
    objc.release(table);

    _ = button(panel, content, "Open", "Open selected note", "openNote:", rect(9, 6, 65, 24), 0);
    _ = button(panel, content, "Delete…", "Delete selected note", "deleteNote:", rect(size.width - 86, 6, 77, 24), 1);
}

fn reload(panel: *Panel) void {
    const table = panel.table orelse return;
    const selected = selectedID(panel);
    const query = msg(Object, panel.search.?, "stringValue", .{});
    const query_empty = msg(usize, query, "length", .{}) == 0;
    panel.matches.clearRetainingCapacity();
    var selected_row: ?isize = null;
    const notes = panel.notes.store.notes.items;
    var i = notes.len;
    while (i > 0) {
        i -= 1;
        const note = notes[i];
        if (!query_empty and !msg(bool, objc.nsString(note.text()), "localizedCaseInsensitiveContainsString:", .{query})) continue;
        if (selected) |id| {
            if (std.mem.eql(u8, note.id, id)) selected_row = @intCast(panel.matches.items.len);
        }
        panel.matches.append(panel.notes.store.gpa, i) catch break;
    }
    msg(void, table, "reloadData", .{});
    if (selected_row) |row| {
        const selection = msg(Object, objc.class("NSIndexSet"), "indexSetWithIndex:", .{@as(usize, @intCast(row))});
        msg(void, table, "selectRowIndexes:byExtendingSelection:", .{ selection, false });
    }
}

fn selectedID(panel: *Panel) ?[]const u8 {
    const row = msg(isize, panel.table.?, "selectedRow", .{});
    if (row < 0 or row >= panel.matches.items.len) return null;
    const index = panel.matches.items[@intCast(row)];
    if (index >= panel.notes.store.notes.items.len) return null;
    return panel.notes.store.notes.items[index].id;
}

fn rowCount(obj: Object, _: objc.SEL, _: Object) callconv(.c) isize {
    return @intCast(objc.getZig(Panel, obj).?.matches.items.len);
}

fn rowValue(obj: Object, _: objc.SEL, _: Object, _: ?Object, row: isize) callconv(.c) ?Object {
    const panel = objc.getZig(Panel, obj).?;
    if (row < 0 or row >= panel.matches.items.len) return null;
    const index = panel.matches.items[@intCast(row)];
    if (index >= panel.notes.store.notes.items.len) return null;
    return noteTitle(panel.notes.store.notes.items[index]);
}

fn searchChanged(obj: Object, _: objc.SEL, _: Object) callconv(.c) void {
    reload(objc.getZig(Panel, obj).?);
}

fn openSelected(obj: Object, _: objc.SEL, _: Object) callconv(.c) void {
    const panel = objc.getZig(Panel, obj).?;
    const id = selectedID(panel) orelse return;
    msg(void, panel.window, "orderOut:", .{@as(?Object, null)});
    panel.notes.showNote(id, true);
}

fn newNote(obj: Object, _: objc.SEL, _: Object) callconv(.c) void {
    const panel = objc.getZig(Panel, obj).?;
    if (panel.id == null) msg(void, panel.window, "orderOut:", .{@as(?Object, null)});
    panel.notes.new();
}

fn browseNotes(obj: Object, _: objc.SEL, _: Object) callconv(.c) void {
    objc.getZig(Panel, obj).?.notes.browse();
}

fn deleteNote(obj: Object, _: objc.SEL, _: Object) callconv(.c) void {
    const panel = objc.getZig(Panel, obj).?;
    const id = panel.id orelse selectedID(panel) orelse return;
    panel.notes.delete(id);
}

fn saveNote(obj: Object, _: objc.SEL, _: Object) callconv(.c) void {
    savePanel(objc.getZig(Panel, obj).?);
}

fn savePanel(panel: *Panel) void {
    const index = panel.notes.store.find(panel.id orelse return) orelse return;
    _ = panel.notes.finishEdit(index, .save, false);
}

fn showActions(obj: Object, _: objc.SEL, sender: Object) callconv(.c) void {
    const menu = msg(Object, objc.alloc("NSMenu"), "initWithTitle:", .{objc.nsString("Note Actions")});
    defer objc.release(menu);
    for ([_]struct { title: []const u8, sel: [:0]const u8, key: []const u8 = "" }{
        .{ .title = "Browse Notes", .sel = "browseNotes:", .key = "p" },
        .{ .title = "New Note", .sel = "newNote:", .key = "n" },
        .{ .title = "Save Note", .sel = "saveNote:", .key = "s" },
        .{ .title = "Delete Note…", .sel = "deleteNote:" },
    }) |action| {
        const item = msg(Object, menu, "addItemWithTitle:action:keyEquivalent:", .{
            objc.nsString(action.title), objc.sel(action.sel), objc.nsString(action.key),
        });
        msg(void, item, "setTarget:", .{obj});
    }
    _ = msg(bool, menu, "popUpMenuPositioningItem:atLocation:inView:", .{
        @as(?Object, null), objc.CGPoint{ .x = 0, .y = 24 }, sender,
    });
}

fn focusChanged(obj: Object, _: objc.SEL, _: Object) callconv(.c) void {
    const panel = objc.getZig(Panel, obj).?;
    if (panel.editor) |editor| markdown.style(editor, msg(bool, panel.window, "isKeyWindow", .{}));
}

fn textChanged(obj: Object, _: objc.SEL, _: Object) callconv(.c) void {
    const panel = objc.getZig(Panel, obj).?;
    const editor = panel.editor orelse return;
    if (msg(bool, editor, "hasMarkedText", .{})) return;
    const notes = panel.notes;
    const index = notes.store.find(panel.id orelse return) orelse return;
    const value = objc.fromNSString(msg(Object, editor, "string", .{}));
    const note = &notes.store.notes.items[index];
    if (std.mem.eql(u8, note.text(), value)) return;
    const draft = if (std.mem.eql(u8, note.markdown, value)) null else notes.store.gpa.dupe(u8, value) catch {
        notes.saveStatus(false);
        return;
    };
    if (note.draft) |old| notes.store.gpa.free(old);
    note.draft = draft;
    notes.dirty = true;
    panel.setTitle(noteTitle(note.*));
    markdown.style(editor, true);
    _ = notes.save();
    if (notes.library) |library| reload(library);
}

fn frameChanged(obj: Object, _: objc.SEL, _: Object) callconv(.c) void {
    const panel = objc.getZig(Panel, obj).?;
    const notes = panel.notes;
    const index = notes.store.find(panel.id orelse return) orelse return;
    const note = &notes.store.notes.items[index];
    const frame = msg(Rect, panel.window, "frame", .{});
    note.x = frame.origin.x;
    note.y = frame.origin.y;
    note.width = frame.size.width;
    note.height = frame.size.height;
    _ = notes.save();
}

fn shouldClose(obj: Object, _: objc.SEL, _: Object) callconv(.c) bool {
    const panel = objc.getZig(Panel, obj).?;
    const notes = panel.notes;
    if (panel.id) |id| {
        const initial = notes.store.find(id) orelse return false;
        const choice = if (notes.store.notes.items[initial].draft != null)
            confirmClose() orelse return false
        else
            .save;
        const index = notes.store.find(id) orelse return false;
        if (!notes.finishEdit(index, choice, true)) return false;
        if (choice == .discard) {
            const note = notes.store.notes.items[index];
            const editor = panel.editor.?;
            msg(void, editor, "setDelegate:", .{@as(?Object, null)});
            msg(void, editor, "setString:", .{objc.nsString(note.text())});
            if (msg(?Object, editor, "undoManager", .{})) |undo| msg(void, undo, "removeAllActions", .{});
            markdown.style(editor, false);
            msg(void, editor, "setDelegate:", .{panel.delegate});
            panel.setTitle(noteTitle(note));
        }
        if (notes.library) |library| reload(library);
    }
    msg(void, panel.window, "orderOut:", .{@as(?Object, null)});
    return false;
}

fn confirmClose() ?model.EditChoice {
    const dialog = objc.new("NSAlert");
    defer objc.release(dialog);
    msg(void, dialog, "setMessageText:", .{objc.nsString("Save changes to this note?")});
    msg(void, dialog, "setInformativeText:", .{objc.nsString("Discard restores the last saved version.")});
    _ = msg(Object, dialog, "addButtonWithTitle:", .{objc.nsString("Save")});
    _ = msg(Object, dialog, "addButtonWithTitle:", .{objc.nsString("Cancel")});
    const discard = msg(Object, dialog, "addButtonWithTitle:", .{objc.nsString("Discard")});
    msg(void, discard, "setHasDestructiveAction:", .{true});
    return switch (msg(isize, dialog, "runModal", .{})) {
        1000 => .save,
        1002 => .discard,
        else => null,
    };
}

fn alert(title: []const u8, message: []const u8) void {
    const dialog = objc.new("NSAlert");
    defer objc.release(dialog);
    msg(void, dialog, "setMessageText:", .{objc.nsString(title)});
    msg(void, dialog, "setInformativeText:", .{objc.nsString(message)});
    _ = msg(isize, dialog, "runModal", .{});
}

fn confirmDelete(title: Object) bool {
    const dialog = objc.new("NSAlert");
    defer objc.release(dialog);
    msg(void, dialog, "setMessageText:", .{objc.nsString("Delete this note?")});
    msg(void, dialog, "setInformativeText:", .{title});
    _ = msg(Object, dialog, "addButtonWithTitle:", .{objc.nsString("Cancel")});
    const delete_button = msg(Object, dialog, "addButtonWithTitle:", .{objc.nsString("Delete")});
    msg(void, delete_button, "setHasDestructiveAction:", .{true});
    return msg(isize, dialog, "runModal", .{}) == 1001;
}
