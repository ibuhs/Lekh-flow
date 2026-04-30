//
//  MenuBarView.swift
//  Lekh Flow
//
//  Compact dropdown shown when the user clicks the menu bar icon.
//  Surfaces the current dictation status, a one-tap "Start" button,
//  and the usual Settings / About / Quit actions. Designed to feel
//  like a Wispr-Flow/Raycast tray drawer rather than a stock NSMenu.
//

import SwiftUI
import AppKit
import KeyboardShortcuts

struct MenuBarView: View {
    private var controller: DictationController { .shared }
    private var brandIcon: NSImage {
        if let url = Bundle.main.url(forResource: "icon", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        return NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().padding(.vertical, 6)
            actions
            Divider().padding(.vertical, 6)
            footer
        }
        .padding(12)
        .frame(width: 280)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(nsImage: brandIcon)
                .resizable()
                .interpolation(.high)
                .frame(width: 32, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text("Lekh Flow")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                Text(statusText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var statusText: String {
        if controller.isActive {
            return "Listening…"
        }
        let backend = controller.currentTranscriber
        if backend.isDownloading {
            return "Downloading \(backend.kind.displayName) \(Int(backend.downloadProgress * 100))%"
        }
        if let shortcut = KeyboardShortcuts.getShortcut(for: .toggleDictation) {
            return "Press \(shortcut) to dictate"
        }
        return "No shortcut set"
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 4) {
            menuButton(
                title: controller.isActive ? "Stop dictation" : "Start dictation",
                systemImage: controller.isActive ? "stop.circle.fill" : "mic.circle.fill",
                tint: controller.isActive ? .red : .accentColor
            ) {
                if controller.isActive {
                    Task { await controller.stop(commit: true) }
                } else {
                    Task { await controller.start() }
                }
            }
            menuButton(title: "Settings…", systemImage: "gearshape") {
                if let delegate = LekhAppDelegate.shared {
                    delegate.openSettings()
                }
            }
            menuButton(title: "Show Onboarding", systemImage: "sparkles") {
                if let delegate = LekhAppDelegate.shared {
                    delegate.showOnboarding()
                }
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            menuButton(title: "Lekh AI Pro", systemImage: "arrow.up.forward.app") {
                openURL("https://lekhai.app/pro")
            }
            menuButton(title: "Veroi AI", systemImage: "sparkles") {
                openURL("https://veroi.ai")
            }
            menuButton(title: "Kaila Labs", systemImage: "globe") {
                openURL("https://kailalabs.com")
            }
            Divider().padding(.vertical, 6)
            menuButton(title: "About Lekh Flow", systemImage: "info.circle") {
                LekhAppDelegate.shared?.openAbout()
            }
            menuButton(title: "Quit Lekh Flow", systemImage: "power") {
                NSApp.terminate(nil)
            }
        }
    }

    private func menuButton(
        title: String,
        systemImage: String,
        tint: Color = .primary,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                Spacer()
            }
            .contentShape(Rectangle())
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
        }
        .buttonStyle(.plain)
    }

    private func openURL(_ string: String) {
        guard let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }
}
