//
//  SettingsWindow.swift
//  Lekh Flow
//
//  Explicit AppKit-hosted Settings window for the menu bar app. We keep
//  this separate from SwiftUI's `Settings` scene because launching a
//  scene through the responder chain from inside a transient status-bar
//  popover has proven unreliable on macOS 26.
//

import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController {
    init() {
        let hosting = NSHostingController(rootView:
            SettingsScene()
                .frame(width: 560, height: 460)
        )
        let window = NSWindow(contentViewController: hosting)
        window.title = "Settings"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        window.isMovableByWindowBackground = true
        window.setContentSize(NSSize(width: 560, height: 460))
        window.center()
        window.isReleasedWhenClosed = false
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
