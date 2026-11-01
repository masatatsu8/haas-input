import AppKit

enum RecorderScreenResolver {
    static func resolve() -> NSScreen? {
        if let main = NSScreen.main { return main }
        let pointer = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(pointer) }) ?? NSScreen.screens.first
    }
}
