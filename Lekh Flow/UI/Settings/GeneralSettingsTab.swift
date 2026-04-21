//
//  GeneralSettingsTab.swift
//  Lekh Flow
//

import SwiftUI

struct GeneralSettingsTab: View {
    private var controller: DictationController { .shared }
    @AppStorage(AppSettings.Keys.menuBarEnabled) private var menuBarEnabled = true

    var body: some View {
        @Bindable var settings = controller.settings

        Form {
            Section("Behaviour") {
                Picker("When dictation ends", selection: $settings.completionAction) {
                    ForEach(CompletionAction.allCases) { action in
                        Text(action.displayName).tag(action)
                    }
                }
                Toggle("Auto-capitalise the first letter", isOn: $settings.autoCapitalize)
                Toggle("Play start / stop sounds", isOn: $settings.playSounds)
            }
            Section("Menu Bar") {
                Toggle("Show Lekh Flow in the menu bar", isOn: $menuBarEnabled)
                    .onChange(of: menuBarEnabled) { _, newValue in
                        if let delegate = LekhAppDelegate.shared {
                            delegate.setMenuBarVisible(newValue)
                        }
                    }
            }
            Section("Permissions") {
                PermissionRow(
                    title: "Microphone",
                    granted: controller.permissions.microphoneAuthorized,
                    action: { Task { await controller.permissions.requestMicrophone() } },
                    openSettings: { controller.permissions.openMicrophoneSettings() }
                )
                PermissionRow(
                    title: "Accessibility (paste into apps)",
                    granted: controller.permissions.accessibilityAuthorized,
                    action: { controller.permissions.requestAccessibility() },
                    openSettings: { controller.permissions.openAccessibilitySettings() }
                )
            }
        }
        .formStyle(.grouped)
        .onAppear { controller.permissions.refresh() }
    }
}

struct PermissionRow: View {
    let title: String
    let granted: Bool
    let action: () -> Void
    let openSettings: () -> Void

    var body: some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(granted ? .green : .orange)
            Text(title)
            Spacer()
            if granted {
                Text("Granted")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Button("Grant", action: action)
                Button("Open Settings", action: openSettings)
            }
        }
    }
}
