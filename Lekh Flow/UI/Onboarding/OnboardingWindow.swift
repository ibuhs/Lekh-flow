//
//  OnboardingWindow.swift
//  Lekh Flow
//
//  A bog-standard NSWindow hosting the SwiftUI onboarding flow. We
//  build it as an NSWindow rather than a SwiftUI WindowGroup because
//  the app intentionally has zero WindowGroup scenes (it's a pure
//  menu bar app), and SwiftUI's `Window` scene refuses to centre or
//  raise itself reliably without a hosting AppKit window.
//

import AppKit
import SwiftUI

@MainActor
final class OnboardingWindowController: NSWindowController {
    private let dictation: DictationController
    private let onComplete: () -> Void

    init(dictation: DictationController, onComplete: @escaping () -> Void) {
        self.dictation = dictation
        self.onComplete = onComplete

        let view = OnboardingView(
            dictation: dictation,
            onFinish: { onComplete() }
        )
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Welcome to Lekh Flow"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask = [.titled, .fullSizeContentView, .closable]
        window.isMovableByWindowBackground = true
        window.setContentSize(NSSize(width: 720, height: 520))
        window.center()
        window.isReleasedWhenClosed = false
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        // Accessory apps can host foreground key windows just fine — we
        // just need to opt this NSWindow in to becoming key. We
        // intentionally do NOT call `NSApp.setActivationPolicy(.regular)`
        // here: on macOS 26 (Tahoe) toggling an LSUIElement app between
        // accessory/regular at runtime sends SwiftUI's main-menu graph
        // into an infinite update loop in `AG::Graph::call_update`,
        // wedging the main thread at 100% CPU.
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(nil)
        // `.activate(ignoringOtherApps:)` raises us above the foreground
        // app without requiring `.regular` activation policy. Accessory
        // apps can become foreground temporarily as long as they own a
        // key window.
        NSApp.activate(ignoringOtherApps: true)
    }
}
