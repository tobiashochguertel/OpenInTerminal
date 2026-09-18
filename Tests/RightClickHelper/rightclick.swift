// Posts a right-click at (x, y) in screen coordinates.
// Used by Tests/e2e-finder.sh to trigger a real Finder context menu.
// Requires accessibility permission for the invoking process.
import CoreGraphics
import Foundation

guard CommandLine.arguments.count == 3,
      let x = Double(CommandLine.arguments[1]),
      let y = Double(CommandLine.arguments[2]) else {
    FileHandle.standardError.write("usage: rightclick <x> <y>\n".data(using: .utf8)!)
    exit(1)
}
let point = CGPoint(x: x, y: y)
let src = CGEventSource(stateID: .combinedSessionState)
guard let down = CGEvent(mouseEventSource: src, mouseType: .rightMouseDown,
                         mouseCursorPosition: point, mouseButton: .right),
      let up = CGEvent(mouseEventSource: src, mouseType: .rightMouseUp,
                       mouseCursorPosition: point, mouseButton: .right) else {
    FileHandle.standardError.write("failed to create mouse events\n".data(using: .utf8)!)
    exit(1)
}
down.post(tap: .cghidEventTap)
up.post(tap: .cghidEventTap)
