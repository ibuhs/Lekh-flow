//
//  ParakeetTranscriber.swift
//  Lekh Flow
//
//  Live, on-device dictation powered by FluidAudio's streaming Parakeet
//  EOU manager. We only ever transcribe a single channel (the mic) so
//  this is dramatically simpler than the dual-channel orchestrator
//  used in MeetingMind — one manager, one decoder state, one rolling
//  partial.
//
//  The streaming manager's partial/EOU callbacks always deliver the
//  *cumulative* transcript decoded since the last `reset()`. That's
//  awkward for live UI, so we strip whatever's already been committed
//  before publishing the in-progress partial.
//

import Foundation
import AVFoundation
import FluidAudio
import Observation

@MainActor
@Observable
final class ParakeetTranscriber {
    static let shared = ParakeetTranscriber()

    // MARK: - Public state

    /// Concatenation of every utterance that's been finalised by the
    /// EOU detector since `start()`. Plus, after `stop()`, the trailing
    /// audio that hadn't yet triggered EOU.
    private(set) var committedText: String = ""

    /// In-progress text since the last EOU. Updates several times a
    /// second while you're talking.
    private(set) var partialText: String = ""

    /// Convenience: committed + partial concatenated, with appropriate
    /// spacing. Exactly what the popup binds to.
    var liveText: String {
        let committed = committedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let partial   = partialText.trimmingCharacters(in: .whitespacesAndNewlines)
        switch (committed.isEmpty, partial.isEmpty) {
        case (true, true):   return ""
        case (false, true):  return committed
        case (true, false):  return partial
        case (false, false): return committed + " " + partial
        }
    }

    /// Whether the streaming model bundle is downloaded + loaded into
    /// the active manager. Driven by `warm()` and `start()`.
    private(set) var isReady: Bool = false

    /// True while the streaming model bundle is downloading from
    /// HuggingFace. The popup and onboarding both bind to this so the
    /// download progress bar replaces the live caption.
    private(set) var isDownloading: Bool = false

    /// 0…1 download progress for the streaming Parakeet bundle.
    private(set) var downloadProgress: Double = 0

    /// True between `start()` and `stop()`. Also true while we're still
    /// flushing the tail audio after `stop()`.
    private(set) var isRunning: Bool = false

    /// Last error, if any. Cleared on the next successful `start()`.
    private(set) var lastError: String?

    /// Fired on the main actor every time an utterance is finalised by
    /// the EOU detector (or by the tail-flush in `stop()`). The string
    /// is just the *new* text since the previous EOU — never the full
    /// rolling transcript. `DictationController` uses this to live-paste
    /// each segment at the cursor as the user pauses.
    var onUtterance: ((String) -> Void)?

    // MARK: - Private state

    private var manager: StreamingEouAsrManager?
    private var processingTask: Task<Void, Never>?
    private var loadedChunkSize: LFChunkSize?

    /// The streaming manager's callbacks ship the cumulative transcript
    /// — `accumulatedTokenIds` is never cleared between EOUs. To show
    /// only the new portion of each utterance (and to commit only the
    /// new portion on EOU), we remember everything that's already been
    /// committed and strip that prefix from every incoming text.
    private var committedPrefix: String = ""

    private let tickInterval: Duration = .milliseconds(120)

    private init() {
        NSLog("🟠 ParakeetTranscriber.init — FluidAudio singleton came alive")
    }

    // MARK: - Lifecycle

    /// Download + load the streaming model bundle without starting any
    /// audio capture. Called at app startup so the first hotkey press
    /// has a hot model. Idempotent.
    func warm() async throws {
        if manager != nil, loadedChunkSize == AppSettings.shared.chunkSize { return }
        NSLog("🟠 ParakeetTranscriber.warm() called — beginning model download / load")
        try await downloadIfNeeded()
        try await ensureManager()
        NSLog("🟠 ParakeetTranscriber.warm() finished — model is hot")
    }

    /// Start the live transcription pipeline. Safe to call repeatedly —
    /// subsequent calls in the same session reset the rolling state but
    /// keep the underlying manager warm.
    func start() async throws {
        NSLog("🧠 transcriber.start — beginning")
        lastError = nil
        committedText = ""
        partialText = ""
        committedPrefix = ""

        try await downloadIfNeeded()
        NSLog("🧠 transcriber.start — model downloaded/cached")
        try await ensureManager()
        NSLog("🧠 transcriber.start — manager ready")
        guard let mgr = manager else { return }

        await mgr.reset()
        await mgr.setPartialCallback { [weak self] text in
            NSLog("🧠 partial: '\(text)'")
            Task { @MainActor [weak self] in
                self?.handlePartial(text)
            }
        }
        await mgr.setEouCallback { [weak self] text in
            NSLog("🧠 EOU: '\(text)'")
            Task { @MainActor [weak self] in
                self?.handleEou(text)
            }
        }

        isRunning = true
        startProcessingLoop()
        NSLog("🧠 transcriber.start — processing loop running")
    }

    /// Append a 16 kHz mono Float32 PCM buffer for live transcription.
    /// Returns immediately; decoding happens on the streaming manager's
    /// internal queue.
    private var appendCount = 0

    func append(_ buffer: AVAudioPCMBuffer) {
        guard isRunning, let mgr = manager else {
            if !isRunning { NSLog("🧠 append — dropped (transcriber not running)") }
            else if manager == nil { NSLog("🧠 append — dropped (manager is nil)") }
            return
        }
        appendCount += 1
        if appendCount == 1 || appendCount % 50 == 0 {
            NSLog("🧠 append — forwarded buffer #\(appendCount) (frames=\(buffer.frameLength))")
        }
        Task.detached(priority: .userInitiated) {
            try? await mgr.appendAudio(buffer)
        }
    }

    /// Flush remaining audio through the manager and stop the processing
    /// loop. Returns the final, fully-finalised transcript including any
    /// tail that hadn't yet triggered EOU.
    @discardableResult
    func stop() async -> String {
        guard isRunning else { return committedText }
        isRunning = false

        processingTask?.cancel()
        processingTask = nil

        if let mgr = manager {
            let tail = (try? await mgr.finish()) ?? ""
            let newTail = stripCommittedPrefix(tail, committed: committedPrefix)
            let cleanedTail = newTail.trimmingCharacters(in: .whitespacesAndNewlines)
            commit(newTail)
            partialText = ""
            committedPrefix = ""
            if !cleanedTail.isEmpty {
                onUtterance?(cleanedTail)
            }
        }
        return committedText
    }

    /// Clear the rolling state without tearing down the manager. Useful
    /// when the user dismisses the popup mid-utterance.
    func reset() async {
        if let mgr = manager { await mgr.reset() }
        committedText = ""
        partialText = ""
        committedPrefix = ""
    }

    // MARK: - Internals

    private func downloadIfNeeded() async throws {
        let desiredChunkSize = AppSettings.shared.chunkSize
        guard manager == nil || loadedChunkSize != desiredChunkSize else { return }
        isDownloading = true
        downloadProgress = 0
        defer { isDownloading = false }
        do {
            // Spin up a throwaway manager just to drive the download —
            // the real one comes from `ensureManager()`. The bundle is
            // shared across instances via the on-disk cache so this is
            // free after the first run.
            let probe = desiredChunkSize.makeManager()
            try await probe.loadModelsFromHuggingFace(progressHandler: { [weak self] progress in
                Task { @MainActor [weak self] in
                    self?.downloadProgress = progress.fractionCompleted
                }
            })
            await probe.cleanup()
            downloadProgress = 1.0
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    private func ensureManager() async throws {
        let desiredChunkSize = AppSettings.shared.chunkSize
        if manager != nil, loadedChunkSize == desiredChunkSize { return }

        if let manager {
            await manager.cleanup()
            self.manager = nil
            isReady = false
        }

        let mgr = desiredChunkSize.makeManager()
        try await mgr.loadModelsFromHuggingFace()
        manager = mgr
        loadedChunkSize = desiredChunkSize
        isReady = true
    }

    private func startProcessingLoop() {
        processingTask?.cancel()
        let mgr = manager
        let interval = tickInterval
        processingTask = Task.detached(priority: .userInitiated) {
            while !Task.isCancelled {
                if let mgr {
                    try? await mgr.processBufferedAudio()
                }
                if Task.isCancelled { break }
                try? await Task.sleep(for: interval)
            }
        }
    }

    private func handlePartial(_ text: String) {
        partialText = stripCommittedPrefix(text, committed: committedPrefix)
    }

    private func handleEou(_ text: String) {
        let newText = stripCommittedPrefix(text, committed: committedPrefix)
        let cleaned = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        commit(newText)
        // Anything in `text` is now considered committed, so subsequent
        // partials show only what's after this point.
        committedPrefix = text
        partialText = ""
        if !cleaned.isEmpty {
            onUtterance?(cleaned)
        }
    }

    private func stripCommittedPrefix(_ text: String, committed: String) -> String {
        guard !committed.isEmpty else { return text }
        if text.hasPrefix(committed) {
            return String(text.dropFirst(committed.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    private func commit(_ text: String) {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        if committedText.isEmpty {
            committedText = cleaned
        } else {
            committedText += " " + cleaned
        }
    }
}

// MARK: - Chunk size → manager factory

extension LFChunkSize {
    /// Build a fresh streaming Parakeet manager configured for the
    /// chunk size. The cast is safe because every `parakeetEou*ms`
    /// variant resolves to a `StreamingEouAsrManager` inside FluidAudio.
    fileprivate func makeManager() -> StreamingEouAsrManager {
        switch self {
        case .ms160:  return StreamingModelVariant.parakeetEou160ms.createManager() as! StreamingEouAsrManager
        case .ms320:  return StreamingModelVariant.parakeetEou320ms.createManager() as! StreamingEouAsrManager
        case .ms1280: return StreamingModelVariant.parakeetEou1280ms.createManager() as! StreamingEouAsrManager
        }
    }
}
