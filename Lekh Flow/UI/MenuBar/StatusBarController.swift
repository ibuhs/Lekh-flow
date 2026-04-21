//
//  StatusBarController.swift
//  Lekh Flow
//
//  Hand-rolled NSStatusItem + NSPopover that hosts our SwiftUI
//  MenuBarView. We deliberately avoid SwiftUI's `MenuBarExtra` API
//  because on macOS 26 (Tahoe) the underlying `AppKitMainMenuItem`
//  scene type wedges SwiftUI's AttributeGraph in an infinite update
//  loop (`AG::Graph::call_update` → `MainMenuItemHost.requestUpdate` →
//  back again), which pegs the main thread at 100% CPU before the user
//  ever interacts with anything. Going through AppKit directly
//  side-steps the whole main-menu graph.
//

import AppKit
import SwiftUI

@MainActor
final class StatusBarController: NSObject, NSPopoverDelegate {
    private var statusItem: NSStatusItem?
    private let popover: NSPopover

    override init() {
        let popover = NSPopover()
        popover.contentSize = NSSize(width: 280, height: 260)
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(rootView: MenuBarView())
        self.popover = popover
        super.init()
        popover.delegate = self
    }

    /// Insert the status item into the system menu bar. Idempotent.
    func install() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            if let url = Bundle.main.url(forResource: "menuicon", withExtension: "png"),
               let image = NSImage(contentsOf: url) {
                image.isTemplate = false
                image.size = NSSize(width: 20, height: 20)
                button.image = image
                button.imageScaling = .scaleProportionallyUpOrDown
            } else {
                button.image = NSImage(
                    systemSymbolName: "waveform.badge.mic",
                    accessibilityDescription: "Lekh Flow"
                )
                button.image?.isTemplate = true
            }
            button.target = self
            button.action = #selector(togglePopover(_:))
        }
        statusItem = item
    }

    /// Remove the status item — used when the user disables the menu
    /// bar icon in Settings.
    func uninstall() {
        guard let item = statusItem else { return }
        NSStatusBar.system.removeStatusItem(item)
        statusItem = nil
    }

    /// Programmatically close the popover before presenting another
    /// window like Settings or Onboarding. This avoids odd focus/
    /// activation behavior when launching windows from inside the
    /// transient tray UI.
    func dismissPopover() {
        popover.performClose(nil)
    }

    @objc private func togglePopover(_ sender: AnyObject?) {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            // Bring our process forward so SwiftUI buttons inside the
            // popover get hover/click states correctly.
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
