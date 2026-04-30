//
//  LiveTranscriber.swift
//  Lekh Flow
//
//  Backend-neutral surface every dictation engine has to satisfy.
//  Both the Parakeet (FluidAudio) and WhisperKit transcribers vend
//  exactly this shape so `DictationController` and the popup never
//  have to care which one is doing the actual decoding.
//
//  Each backend owns its own audio capture pipeline:
//    - Parakeet drives a `MicrophoneCapture` and forwards 16 kHz
//      mono Float32 buffers into the streaming EOU manager.
//    - WhisperKit drives WhisperKit's own `AudioProcessor` and
//      polls the cumulative buffer.
//
//  This is why the protocol does not expose `append(_:)` — there is
//  no single shared audio pipe. Both backends do, however, expose a
//  smoothed 0…1 instantaneous level so the popup waveform stays
//  backend-agnostic.
//

import Foundation

/// Identifies which concrete backend is implementing the protocol.
/// Used by the popup / settings to render backend-specific copy
/// (e.g. "Downloading Parakeet…" vs "Downloading Whisper…") without
/// breaking the abstraction.
enum TranscriberKind: String {
    case parakeet
    case whisperKit

    var displayName: String {
        switch self {
        case .parakeet:    return "Parakeet"
        case .whisperKit:  return "WhisperKit"
        }
    }
}

/// The lifecycle / state surface every dictation engine satisfies.
@MainActor
protocol LiveTranscriber: AnyObject {
    // Identity
    var kind: TranscriberKind { get }

    // Live state — bound by the popup view model
    var liveText: String { get }
    var isReady: Bool { get }
    var isDownloading: Bool { get }
    var downloadProgress: Double { get }
    var isRunning: Bool { get }
    var lastError: String? { get }

    /// Smoothed 0…1 microphone level for the popup waveform.
    var currentLevel: Float { get }

    /// Optional EOU/utterance hook. Lekh Flow's auto-commit loop
    /// currently nils this out and drives commits off `liveText`
    /// stability instead, but backends may still emit it.
    var onUtterance: ((String) -> Void)? { get set }

    /// Pre-load any model bundles so the first hotkey press is hot.
    /// Idempotent — safe to call repeatedly at startup.
    func warm() async throws

    /// Start microphone capture + decoding. Throws on permission /
    /// model failures; the popup surfaces the message verbatim.
    func start() async throws

    /// Stop capture and flush whatever tail audio is still in flight.
    /// Returns the final cumulative transcript so the controller can
    /// inject any remainder via the same auto-commit code path used
    /// during the live session.
    @discardableResult
    func stop() async -> String

    /// Clear in-memory transcript state without tearing down the
    /// loaded model. Used after the popup is dismissed so the next
    /// invocation starts with a blank slate.
    func reset() async
}
