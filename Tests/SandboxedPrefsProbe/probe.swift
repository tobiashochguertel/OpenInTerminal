//
//  Sandboxed Prefs Probe
//
//  Compiled into a minimal .app, signed with the same Developer ID +
//  entitlements (app-sandbox + application-groups) as the Finder extension.
//  Running it proves whether a sandboxed process on this machine can read
//  the app-group preference suite the extension depends on.
//
//  Built and run by Tests/e2e-check.sh.
//

import Foundation

let group = "4ANN77GFL4.wang.jianing.app.OpenInTerminal"
guard let defaults = UserDefaults(suiteName: group) else {
    print("SUITE-NIL: UserDefaults(suiteName:) returned nil")
    exit(1)
}
let keys = ["DefaultTerminal", "DefaultEditor", "ContextMenuPinDefaultTerminal",
            "ContextMenuUseSubmenu", "CustomMenuApplyToContext", "CustomMenuOptions",
            "HideContextMenuItems", "FirstSetup"]
var missing = 0
for key in keys {
    if let v = defaults.object(forKey: key) {
        if let d = v as? Data, let s = String(data: d, encoding: .utf8) {
            print("\(key) = \(s)")
        } else {
            print("\(key) = \(v)")
        }
    } else {
        print("\(key) = <nil>")
        missing += 1
    }
}
print("SUITE-KEYS-TOTAL = \(defaults.dictionaryRepresentation().count)")
exit(missing == keys.count ? 2 : 0)
