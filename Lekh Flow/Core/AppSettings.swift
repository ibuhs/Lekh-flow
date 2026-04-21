//
//  AppSettings.swift
//  Lekh Flow
//
//  Centralised UserDefaults keys + a small `@Observable` wrapper so
//  views can react to changes without sprinkling `@AppStorage` and
//  string keys all over the place.
//

import Foundation
import SwiftUI
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// The single global shortcut that opens the dictation popup. Stored
    /// under `KeyboardShortcuts_toggleDictation` in UserDefaults by the
    /// sindresorhus/KeyboardShortcuts package; we don't ship a default —
    /// the onboarding flow asks the user to record their own.
    static let toggleDictation = Self("toggleDictation")
}

enum HotkeyMode: String, CaseIterable, Identifiable {
    case toggle      // tap to start, tap again to stop
    case pushToTalk  // hold to record, release to stop

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .toggle:     return "Tap to start / stop"
        case .pushToTalk: return "Hold to talk"
        }
    }
}

/// What happens with the final transcript once recording stops.
enum CompletionAction: String, CaseIterable, Identifiable {
    case pasteIntoFocused
    case copyToClipboard

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .pasteIntoFocused: return "Paste into the focused app"
        case .copyToClipboard:  return "Copy to clipboard"
        }
    }
}

/// Streaming Parakeet chunk size. Maps directly to the three EOU
/// variants FluidAudio ships:
///   - 160ms  → lowest perceived latency, slightly higher CPU
///   - 320ms  → balanced default, "feels instant" with great WER
///   - 1280ms → highest throughput, noticeable lag but lowest CPU
enum LFChunkSize: String, CaseIterable, Identifiable {
    case ms160  = "160ms"
    case ms320  = "320ms"
    case ms1280 = "1280ms"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ms160:  return "Fastest (~160ms latency)"
        case .ms320:  return "Balanced (~320ms)"
        case .ms1280: return "Most efficient (~1.3s)"
        }
    }
}

@MainActor
@Observable
final class AppSettings {
    static let shared = AppSettings()

    enum Keys {
        static let hasCompletedOnboarding = "lf.hasCompletedOnboarding"
        static let menuBarEnabled         = "lf.menuBarEnabled"
        static let hotkeyMode             = "lf.hotkeyMode"
        static let completionAction       = "lf.completionAction"
        static let chunkSize              = "lf.chunkSize"
        static let launchAtLogin          = "lf.launchAtLogin"
        static let playSounds             = "lf.playSounds"
        static let preferredInputUID      = "lf.preferredInputUID"
        static let autoCapitalize         = "lf.autoCapitalize"
    }

    var hotkeyMode: HotkeyMode {
        didSet {
            UserDefaults.standard.set(hotkeyMode.rawValue, forKey: Keys.hotkeyMode)
        }
    }

    var completionAction: CompletionAction {
        didSet {
            UserDefaults.standard.set(completionAction.rawValue, forKey: Keys.completionAction)
        }
    }

    var chunkSize: LFChunkSize {
        didSet {
            UserDefaults.standard.set(chunkSize.rawValue, forKey: Keys.chunkSize)
        }
    }

    var playSounds: Bool {
        didSet { UserDefaults.standard.set(playSounds, forKey: Keys.playSounds) }
    }

    var autoCapitalize: Bool {
        didSet { UserDefaults.standard.set(autoCapitalize, forKey: Keys.autoCapitalize) }
    }

    var preferredInputUID: String? {
        didSet { UserDefaults.standard.set(preferredInputUID, forKey: Keys.preferredInputUID) }
    }

    private init() {
        let d = UserDefaults.standard
        let storedChunkSize = d.string(forKey: Keys.chunkSize)
        // Register defaults so first-launch reads return the right value.
        d.register(defaults: [
            Keys.menuBarEnabled: true,
            Keys.hotkeyMode: HotkeyMode.toggle.rawValue,
            Keys.completionAction: CompletionAction.pasteIntoFocused.rawValue,
            Keys.chunkSize: LFChunkSize.ms160.rawValue,
            Keys.playSounds: true,
            Keys.autoCapitalize: true,
        ])

        self.hotkeyMode        = HotkeyMode(rawValue: d.string(forKey: Keys.hotkeyMode) ?? "") ?? .toggle
        self.completionAction  = CompletionAction(rawValue: d.string(forKey: Keys.completionAction) ?? "") ?? .pasteIntoFocused
        self.chunkSize         = LFChunkSize(rawValue: storedChunkSize ?? LFChunkSize.ms160.rawValue) ?? .ms160
        self.playSounds        = d.bool(forKey: Keys.playSounds)
        self.autoCapitalize    = d.bool(forKey: Keys.autoCapitalize)
        self.preferredInputUID = d.string(forKey: Keys.preferredInputUID)
    }
}
