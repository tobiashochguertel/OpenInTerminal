// Posts synthetic mouse/keyboard events for Tests/e2e-finder.sh.
//
// Mouse clicks go through the global HID tap — CGEventPostToPid was tested
// and does NOT work for Finder: events posted to a pid lack window-server
// hit-testing, and Finder drops them unless the window is already key.
// A real click therefore needs the target window active and on top; the
// script activates Finder only for a ~2s window and restores the previous
// frontmost app plus the cursor position (--pos/--warp) afterwards.
// --escape uses postToPid, which IS reliable for keyboard events.
//
// Usage:
//   rightclick <x> <y> [pid]     right-click at screen coords (global HID tap)
//   rightclick --left <x> <y>    left-click at screen coords (global HID tap)
//   rightclick --escape [pid]    post Escape to a process (pid: default Finder)
//   rightclick --pos             print the current cursor position as "x y"
//   rightclick --warp <x> <y>    move the cursor without clicking (pos restore)
//
// Requires accessibility permission for the invoking process.
import CoreGraphics
import Foundation
import AppKit

func finderPID() -> pid_t? {
    NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder")
        .first?.processIdentifier
}

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write("\(msg)\n".data(using: .utf8)!)
    exit(1)
}

var args = CommandLine.arguments
args.removeFirst()

if args.first == "--pos" {
    let ev = CGEvent(source: nil)!
    print("\(Int(ev.location.x)) \(Int(ev.location.y))")
    exit(0)
}
if args.first == "--warp" {
    guard args.count == 3, let x = Double(args[1]), let y = Double(args[2]) else {
        fail("usage: rightclick --warp <x> <y>")
    }
    CGWarpMouseCursorPosition(CGPoint(x: x, y: y))
    exit(0)
}

let expected = args.first == "--escape" ? 1 : (args.first == "--left" ? 3 : 2)
var pid: pid_t
if args.count > expected, let last = args.last, let p = pid_t(last) {
    pid = p
    args.removeLast()
} else {
    guard let p = finderPID() else { fail("Finder not running") }
    pid = p
}

let src = CGEventSource(stateID: .combinedSessionState)

if args.first == "--escape" {
    guard let down = CGEvent(keyboardEventSource: src, virtualKey: 53, keyDown: true),
          let up = CGEvent(keyboardEventSource: src, virtualKey: 53, keyDown: false) else {
        fail("failed to create key events")
    }
    down.postToPid(pid)
    up.postToPid(pid)
    exit(0)
}

let leftMode = args.first == "--left"
let coordArgs = leftMode ? Array(args.dropFirst()) : args
guard coordArgs.count == 2,
      let x = Double(coordArgs[0]),
      let y = Double(coordArgs[1]) else {
    fail("usage: rightclick [--left] <x> <y> [pid] | rightclick --escape [pid]")
}

let point = CGPoint(x: x, y: y)
let downType: CGEventType = leftMode ? .leftMouseDown : .rightMouseDown
let upType: CGEventType = leftMode ? .leftMouseUp : .rightMouseUp
let button: CGMouseButton = leftMode ? .left : .right
guard let down = CGEvent(mouseEventSource: src, mouseType: downType,
                         mouseCursorPosition: point, mouseButton: button),
      let up = CGEvent(mouseEventSource: src, mouseType: upType,
                       mouseCursorPosition: point, mouseButton: button) else {
    fail("failed to create mouse events")
}
down.post(tap: .cghidEventTap)
up.post(tap: .cghidEventTap)
