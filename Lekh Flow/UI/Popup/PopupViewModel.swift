//
//  PopupViewModel.swift
//  Lekh Flow
//
//  Tiny adapter between the long-lived DictationController and the
//  short-lived popup view. SwiftUI views don't observe `@Observable`
//  classes deeply enough through `@Environment(...)` for our taste —
//  the view model lets us expose precisely the fields the popup
//  cares about.
//

import Foundation
import Observation

@MainActor
@Observable
final class PopupViewModel {
    let controller: DictationController

    /// Surfaced when permission is denied or the model fails to load.
    /// Replaces the live caption with an actionable error block.
    var errorMessage: String?

    /// Set after a successful "Keep popup open for review" stop. Locks
    /// the popup into a finalised-transcript state with copy / paste
    /// buttons.
    var finalText: String?

    init(controller: DictationController) {
        self.controller = controller
    }

    /// Surface the full live transcript so the popup visibly reflects
    /// what the model has recognised so far, even if the underlying
    /// streaming engine is conservative about emitting partials before
    /// an utterance boundary.
    var transcript: String {
        controller.transcriber.liveText
    }

    var isModelDownloading: Bool {
        controller.transcriber.isDownloading
    }

    var modelDownloadProgress: Double {
        controller.transcriber.downloadProgress
    }

    var isRunning: Bool {
        controller.transcriber.isRunning
    }

    var micLevel: Float {
        controller.microphone.level
    }

    var hotkeyMode: HotkeyMode {
        controller.settings.hotkeyMode
    }

    func cancel() {
        controller.cancel()
    }

    func stop() {
        Task { await controller.stop(commit: true) }
    }

    func copyFinal() {
        if let text = finalText {
            TextInjector.copy(text)
        }
    }

    func pasteFinal() {
        if let text = finalText {
            TextInjector.paste(text)
        }
    }
}
