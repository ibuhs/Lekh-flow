//
//  AboutWindow.swift
//  Lekh Flow
//
//  Branded About window used from the tray popover. We avoid the stock
//  macOS about panel so the app icon, copy, and footer match the custom
//  Settings → About tab exactly.
//

import AppKit
import SwiftUI

@MainActor
final class AboutWindowController: NSWindowController {
    init() {
        let hosting = NSHostingController(rootView:
            AboutSettingsTab(compact: true)
                .frame(width: 320, height: 210)
        )
        let window = NSWindow(contentViewController: hosting)
        window.title = "About Lekh Flow"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.isMovableByWindowBackground = true
        window.setContentSize(NSSize(width: 320, height: 210))
        window.center()
        window.isReleasedWhenClosed = false
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
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
