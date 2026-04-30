//
//  TranscriberRouter.swift
//  Lekh Flow
//
//  Tiny piece of glue that picks the right `LiveTranscriber` for the
//  user's currently-selected dictation language.
//
//    English → Parakeet (FluidAudio streaming)
//    Anything else → WhisperKit
//
//  The router is intentionally stateless and resolved on every call
//  so a language change in Settings takes effect on the very next
//  hotkey press without anyone having to invalidate caches.
//

import Foundation

@MainActor
enum TranscriberRouter {
    /// The transcriber that should service the next dictation
    /// session, based on `AppSettings.dictationLanguage`.
    static var active: LiveTranscriber {
        switch AppSettings.shared.dictationLanguage.preferredBackend {
        case .parakeet:
            return ParakeetTranscriber.shared
        case .whisperKit:
            return WhisperKitTranscriber.shared
        }
    }

    /// Both backend singletons, in case the UI needs to render state
    /// for the inactive one (e.g. settings download buttons).
    static var allBackends: [LiveTranscriber] {
        [ParakeetTranscriber.shared, WhisperKitTranscriber.shared]
    }

    /// Warm up whichever backend the active language wants. Called at
    /// launch and after onboarding so the first hotkey press is hot.
    static func warmActive() async throws {
        try await active.warm()
    }
}
