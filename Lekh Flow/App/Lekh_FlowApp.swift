//
//  Lekh_FlowApp.swift
//  Lekh Flow
//
//  Menu bar app entry. There is intentionally no main WindowGroup —
//  the entire UX is the floating popup that pops in response to the
//  global hotkey. The only "real" windows are the SwiftUI Settings
//  scene and the first-launch Onboarding window.
//

import SwiftUI
import AppKit
import KeyboardShortcuts

@main
struct Lekh_FlowApp: App {
    @NSApplicationDelegateAdaptor(LekhAppDelegate.self) private var appDelegate

    var body: some Scene {
        // The ONLY SwiftUI scene we declare is `Settings`. We used to
        // also declare a `MenuBarExtra`, but on macOS 26 (Tahoe)
        // `MenuBarExtra` is backed by an `AppKitMainMenuItem` scene
        // type whose AttributeGraph never converges — it wedges the
        // main thread at 100% CPU before the user ever interacts.
        // The menu bar icon is now a hand-rolled `NSStatusItem`
        // managed by `LekhAppDelegate.statusBar`.
        //
        // `Settings` is itself lazy: the window is only built when
        // the user invokes ⌘, so it doesn't trigger the same loop.
        Settings {
            SettingsScene()
                .frame(width: 560, height: 460)
        }
    }
}

/// Orchestrates the long-lived services that have to outlive any
/// individual SwiftUI scene: the global hotkey, the popup window,
/// the dictation pipeline. Everything is set up in
/// `applicationDidFinishLaunching` so it survives the user closing
/// Settings, dismissing the popup, etc.
@MainActor
final class LekhAppDelegate: NSObject, NSApplicationDelegate {
    static var shared: LekhAppDelegate?

    private var dictation: DictationController { .shared }
    private var onboardingWindow: OnboardingWindowController?
    private var settingsWindow: SettingsWindowController?
    private var aboutWindow: AboutWindowController?
    private let statusBar = StatusBarController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self
        NSLog("🟢 Lekh Flow launching")

        // Install the menu bar status item. We respect the user's
        // preference here so a freshly-launched app honours the
        // toggle from the previous session.
        if UserDefaults.standard.object(forKey: AppSettings.Keys.menuBarEnabled) == nil
            || UserDefaults.standard.bool(forKey: AppSettings.Keys.menuBarEnabled) {
            statusBar.install()
        }
        NSLog("🟢 status bar installed")

        // Pull the global Accessibility process trust state into the
        // permission manager early so the menu bar reflects it the
        // moment the user opens the popover.
        PermissionsManager.shared.refresh()
        NSLog("🟢 permissions refreshed")

        dictation.bootstrap()
        NSLog("🟢 dictation bootstrapped")

        if !UserDefaults.standard.bool(forKey: AppSettings.Keys.hasCompletedOnboarding) {
            NSLog("🟢 showing onboarding")
            showOnboarding()
        } else {
            NSLog("🟢 onboarding already complete — warming model in background")
            // Background-warm the streaming Parakeet model so the very
            // first hotkey press has a hot model rather than a 150MB
            // download blocking the UI.
            Task.detached(priority: .utility) {
                try? await ParakeetTranscriber.shared.warm()
            }
        }
        NSLog("🟢 launch complete")
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Pure accessory app — nothing to reopen since there's no dock
        // icon. Returning false suppresses any default behaviour AppKit
        // might attempt.
        return false
    }

    /// Toggle the status item without restarting the app. Driven by
    /// the "Show in the menu bar" toggle in Settings → General.
    func setMenuBarVisible(_ visible: Bool) {
        if visible {
            statusBar.install()
        } else {
            statusBar.uninstall()
        }
    }

    func openSettings() {
        statusBar.dismissPopover()
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController()
        }
        // Let the transient tray popover finish closing before we raise
        // the standalone settings window.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            self.settingsWindow?.showWindow(nil)
        }
    }

    func openAbout() {
        statusBar.dismissPopover()
        if aboutWindow == nil {
            aboutWindow = AboutWindowController()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            self.aboutWindow?.showWindow(nil)
        }
    }

    func showOnboarding() {
        statusBar.dismissPopover()
        if onboardingWindow == nil {
            onboardingWindow = OnboardingWindowController(dictation: dictation) { [weak self] in
                self?.onboardingWindow?.close()
                self?.onboardingWindow = nil
                UserDefaults.standard.set(true, forKey: AppSettings.Keys.hasCompletedOnboarding)
                Task.detached(priority: .utility) {
                    try? await ParakeetTranscriber.shared.warm()
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            self.onboardingWindow?.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
