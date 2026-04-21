//
//  PopupWindow.swift
//  Lekh Flow
//
//  Hosts the dictation popup in a borderless, floating, non-activating
//  NSPanel so it can sit on top of every other app — including over
//  full-screen Spaces — without stealing focus from whatever the user
//  was typing into. That's load-bearing: if the panel ever became key,
//  the user's text field would lose focus and the post-recording
//  ⌘V paste would land in the wrong place.
//

import AppKit
import SwiftUI

@MainActor
final class PopupWindowController {
    private let panel: NonActivatingPanel
    private let hosting: NSHostingView<PopupView>
    private let viewModel: PopupViewModel

    init(controller: DictationController) {
        let vm = PopupViewModel(controller: controller)
        self.viewModel = vm

        let view = PopupView(model: vm)
        let hosting = NSHostingView(rootView: view)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        // We let the SwiftUI view dictate its size; the panel resizes
        // to whatever the hosting view reports.
        hosting.frame = NSRect(x: 0, y: 0, width: 560, height: 160)
        self.hosting = hosting

        let panel = NonActivatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 160),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // We render the popup's shadow entirely in SwiftUI. Leaving the
        // NSPanel shadow on creates a second rounded halo/border around
        // the capsule, which is the extra chrome visible in screenshots.
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .ignoresCycle,
            .fullScreenAuxiliary,
        ]
        panel.isMovableByWindowBackground = true
        panel.contentView = hosting
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        self.panel = panel
    }

    func present() {
        layoutAtAnchor()
        panel.alphaValue = 0
        panel.orderFrontRegardless()

        // Spring-y fade + tiny slide-down. Cocoa's default animator
        // proxy on alphaValue is the easiest way to get a quick
        // feels-good fade without dropping into Core Animation.
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.allowsImplicitAnimation = true
            panel.animator().alphaValue = 1
        }
    }

    func dismiss() {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.16
            ctx.allowsImplicitAnimation = true
            self.panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            // The completion handler is invoked on the main thread but
            // typed @Sendable, which trips the actor checker. Hop
            // explicitly so we can mutate MainActor-isolated state.
            MainActor.assumeIsolated {
                guard let self else { return }
                self.panel.orderOut(nil)
                self.viewModel.errorMessage = nil
                self.viewModel.finalText = nil
            }
        })
    }

    func showError(_ message: String) {
        viewModel.errorMessage = message
    }

    func showFinal(_ text: String) {
        viewModel.finalText = text
    }

    /// Anchor the popup near the bottom-centre of the active screen,
    /// the way Wispr-Flow / Raycast do. Stays ~96pt above the dock so
    /// it never overlaps a full-width tray.
    private func layoutAtAnchor() {
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let frame = screen?.visibleFrame else { return }

        // Let the hosting view size itself first.
        let fitting = hosting.fittingSize
        let width = max(fitting.width, 520)
        let height = max(fitting.height, 120)

        let x = frame.midX - width / 2
        let y = frame.minY + 96
        panel.setContentSize(NSSize(width: width, height: height))
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

/// Custom NSPanel that refuses to become key/main so the focused text
/// field in whichever app the user was typing into stays focused
/// across the recording session.
final class NonActivatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
