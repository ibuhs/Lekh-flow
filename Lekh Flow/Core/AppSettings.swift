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

/// Spoken language the user wants to dictate in. Lekh Flow uses
/// this to pick a backend automatically — Parakeet for English (its
/// strength: ultra-low-latency English streaming) and WhisperKit
/// for everything else.
///
/// Stored as a stable lowercase `id` (matching WhisperKit's
/// `Constants.languages` keys) so a freshly-installed Lekh Flow
/// upgrade can keep reading whatever was previously persisted.
struct DictationLanguage: Identifiable, Hashable {
    let id: String
    let displayName: String
    let whisperCode: String?

    /// Which backend should handle dictation in this language.
    /// English keeps the Parakeet low-latency path; everything
    /// else (including "auto") falls through to WhisperKit's
    /// multilingual model.
    var preferredBackend: TranscriberKind {
        id == "english" ? .parakeet : .whisperKit
    }

    /// Whisper language code accepted by `DecodingOptions.language`.
    /// `nil` means "let the model auto-detect" — only used by the
    /// special `auto` entry. The important detail: WhisperKit wants
    /// `hi`, not `hindi`; `fr`, not `french`; etc.
    var whisperLanguageCode: String? {
        whisperCode
    }

    static let english = DictationLanguage(id: "english", displayName: "English", whisperCode: "en")
    static let auto    = DictationLanguage(id: "auto", displayName: "Auto-detect", whisperCode: nil)

    /// Master catalog. English is pinned to the top because it's
    /// the default and the only language that uses the Parakeet
    /// backend; "Auto-detect" sits right below it; everything else
    /// is sorted alphabetically by display name. The 99 entries
    /// after the first two come straight from Whisper's tokenizer
    /// language map so any model the user picks will recognise the
    /// language hint we forward to it.
    static let all: [DictationLanguage] = {
        let multilingual: [DictationLanguage] = [
            ("afrikaans", "af"), ("albanian", "sq"), ("amharic", "am"), ("arabic", "ar"),
            ("armenian", "hy"), ("assamese", "as"), ("azerbaijani", "az"), ("bashkir", "ba"),
            ("basque", "eu"), ("belarusian", "be"), ("bengali", "bn"), ("bosnian", "bs"),
            ("breton", "br"), ("bulgarian", "bg"), ("burmese", "my"), ("cantonese", "yue"),
            ("catalan", "ca"), ("chinese", "zh"), ("croatian", "hr"), ("czech", "cs"),
            ("danish", "da"), ("dutch", "nl"), ("estonian", "et"), ("faroese", "fo"),
            ("finnish", "fi"), ("french", "fr"), ("galician", "gl"), ("georgian", "ka"),
            ("german", "de"), ("greek", "el"), ("gujarati", "gu"), ("haitian creole", "ht"),
            ("hausa", "ha"), ("hawaiian", "haw"), ("hebrew", "he"), ("hindi", "hi"),
            ("hungarian", "hu"), ("icelandic", "is"), ("indonesian", "id"), ("italian", "it"),
            ("japanese", "ja"), ("javanese", "jw"), ("kannada", "kn"), ("kazakh", "kk"),
            ("khmer", "km"), ("korean", "ko"), ("lao", "lo"), ("latin", "la"),
            ("latvian", "lv"), ("lingala", "ln"), ("lithuanian", "lt"), ("luxembourgish", "lb"),
            ("macedonian", "mk"), ("malagasy", "mg"), ("malay", "ms"), ("malayalam", "ml"),
            ("maltese", "mt"), ("maori", "mi"), ("marathi", "mr"), ("mongolian", "mn"),
            ("nepali", "ne"), ("norwegian", "no"), ("nynorsk", "nn"), ("occitan", "oc"),
            ("pashto", "ps"), ("persian", "fa"), ("polish", "pl"), ("portuguese", "pt"),
            ("punjabi", "pa"), ("romanian", "ro"), ("russian", "ru"), ("sanskrit", "sa"),
            ("serbian", "sr"), ("shona", "sn"), ("sindhi", "sd"), ("sinhala", "si"),
            ("slovak", "sk"), ("slovenian", "sl"), ("somali", "so"), ("spanish", "es"),
            ("sundanese", "su"), ("swahili", "sw"), ("swedish", "sv"), ("tagalog", "tl"),
            ("tajik", "tg"), ("tamil", "ta"), ("tatar", "tt"), ("telugu", "te"),
            ("thai", "th"), ("tibetan", "bo"), ("turkish", "tr"), ("turkmen", "tk"),
            ("ukrainian", "uk"), ("urdu", "ur"), ("uzbek", "uz"), ("vietnamese", "vi"),
            ("welsh", "cy"), ("yiddish", "yi"), ("yoruba", "yo"),
        ]
        .map { id, code in
            DictationLanguage(id: id, displayName: id.titlecasedForDisplay(), whisperCode: code)
        }
        .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }

        return [.english, .auto] + multilingual
    }()

    /// Lookup helper used when reading a persisted id back from
    /// `UserDefaults`. Falls back to English if the stored id is
    /// unknown (e.g. a future build dropped the language).
    static func resolve(_ id: String) -> DictationLanguage {
        all.first { $0.id == id } ?? .english
    }
}

private extension String {
    /// Capitalise each whitespace-separated word. Used to render
    /// Whisper's lowercase language ids ("haitian creole") as
    /// presentable display names ("Haitian Creole").
    func titlecasedForDisplay() -> String {
        split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
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
        static let dictationLanguage      = "lf.dictationLanguage"
        static let whisperKitModel        = "lf.whisperKitModel"
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

    /// Persisted id of the selected dictation language. Backed by
    /// `dictationLanguage` for type-safe access — UI binds to the
    /// struct directly via that wrapper.
    private var dictationLanguageID: String {
        didSet {
            UserDefaults.standard.set(dictationLanguageID, forKey: Keys.dictationLanguage)
        }
    }

    /// Selected dictation language. Drives backend routing — see
    /// `DictationLanguage.preferredBackend`. Bindable from SwiftUI
    /// pickers via `$settings.dictationLanguage`.
    var dictationLanguage: DictationLanguage {
        get { DictationLanguage.resolve(dictationLanguageID) }
        set { dictationLanguageID = newValue.id }
    }

    /// WhisperKit model variant to load when the active backend is
    /// WhisperKit. Stored as the WhisperKit model id (e.g.
    /// `openai_whisper-base`). Empty by default — onboarding (or
    /// the Settings → Model tab) prompts the user to pick before
    /// any download starts.
    var whisperKitModel: String {
        didSet {
            UserDefaults.standard.set(whisperKitModel, forKey: Keys.whisperKitModel)
        }
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
            Keys.dictationLanguage: DictationLanguage.english.id,
            // Intentionally empty — we want the user to pick a
            // Whisper model in onboarding (or in Settings) instead
            // of silently downloading hundreds of MB of `base` on
            // first language switch.
            Keys.whisperKitModel: "",
        ])

        self.hotkeyMode         = HotkeyMode(rawValue: d.string(forKey: Keys.hotkeyMode) ?? "") ?? .toggle
        self.completionAction   = CompletionAction(rawValue: d.string(forKey: Keys.completionAction) ?? "") ?? .pasteIntoFocused
        self.chunkSize          = LFChunkSize(rawValue: storedChunkSize ?? LFChunkSize.ms160.rawValue) ?? .ms160
        self.playSounds         = d.bool(forKey: Keys.playSounds)
        self.autoCapitalize     = d.bool(forKey: Keys.autoCapitalize)
        self.preferredInputUID  = d.string(forKey: Keys.preferredInputUID)
        self.dictationLanguageID = d.string(forKey: Keys.dictationLanguage) ?? DictationLanguage.english.id
        self.whisperKitModel    = d.string(forKey: Keys.whisperKitModel) ?? ""
    }
}
