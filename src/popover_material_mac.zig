const objc = @import("nanoui").objc;

/// The launcher and floating notes use the same macOS material.
pub fn create(frame: objc.CGRect) objc.Object {
    const effect = objc.msg(objc.Object, objc.alloc("NSVisualEffectView"), "initWithFrame:", .{frame});
    objc.msg(void, effect, "setMaterial:", .{@as(objc.NSInteger, 6)}); // popover
    objc.msg(void, effect, "setBlendingMode:", .{@as(objc.NSInteger, 0)}); // behind the window
    objc.msg(void, effect, "setState:", .{@as(objc.NSInteger, 1)}); // always active
    return effect;
}
