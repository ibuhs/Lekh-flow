//
//  ShortcutSettingsTab.swift
//  Lekh Flow
//

import SwiftUI
import KeyboardShortcuts

struct ShortcutSettingsTab: View {
    private var controller: DictationController { .shared }

    var body: some View {
        @Bindable var settings = controller.settings

        Form {
            Section("Global Shortcut") {
                HStack {
                    Text("Toggle dictation")
                    Spacer()
                    KeyboardShortcuts.Recorder(for: .toggleDictation)
                }
                Text("Press this combination from anywhere to invoke the popup. Use a keystroke that doesn't conflict with your favourite apps — Right ⌥, F5, or ⌃Space all work well.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section("Trigger Style") {
                Picker("Activation mode", selection: $settings.hotkeyMode) {
                    ForEach(HotkeyMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.inline)
                Text(settings.hotkeyMode == .toggle
                     ? "Press once to start, press again to finish."
                     : "Hold the key down while you talk; release to finish.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
