//
//  OITLog.swift
//  OpenInTerminalCore
//
//  Unified logging for OpenInTerminal. All components log through os.Logger
//  so output lands in the system log and can be filtered precisely:
//
//    log show --last 10m --predicate 'subsystem == "wang.jianing.app.OpenInTerminal"'
//    log show --last 10m --predicate 'subsystem == "wang.jianing.app.OpenInTerminal" AND category == "menu"'
//
//  Level usage:
//    .debug   fine-grained traces (values inspected while building menus)
//    .info    normal lifecycle (menu() calls, item counts)
//    .notice  noteworthy state (defaults loaded, first-setup)
//    .error   recoverable failures (decode errors, missing apps)
//    .fault   invariant violations
//

import Foundation
import os.log

public enum OITLog {

    /// Shared subsystem for all OpenInTerminal components.
    public static let subsystem = "wang.jianing.app.OpenInTerminal"

    /// Menu construction inside the Finder extension.
    public static let menu = Logger(subsystem: subsystem, category: "menu")

    /// Preference reads/writes via DefaultsManager.
    public static let defaults = Logger(subsystem: subsystem, category: "defaults")

    /// Extension lifecycle (launch, FinderSync controller setup).
    public static let lifecycle = Logger(subsystem: subsystem, category: "lifecycle")

    /// Actions dispatched from menu items (open terminal, copy path, ...).
    public static let action = Logger(subsystem: subsystem, category: "action")
}
