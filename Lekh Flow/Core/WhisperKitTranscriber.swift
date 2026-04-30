//
//  WhisperKitTranscriber.swift
//  Lekh Flow
//
//  WhisperKit-backed `LiveTranscriber` for non-English dictation.
//  Lifted from Thinklet's `WhisperKitService` and adapted for macOS:
//
//    - drops AVAudioSession plumbing (iOS-only)
//    - lets WhisperKit's own `AudioProcessor` own the mic engine,
//      since we don't have a usable hook to inject external buffers
//      into `audioProcessor.audioSamples`
//    - publishes a smoothed 0…1 level computed from the
//      processor's `relativeEnergy` so the popup waveform animates
//      identically to the Parakeet path
//    - mirrors the same `liveText` / `isReady` / `isDownloading`
//      semantics Parakeet exposes so `DictationController`'s
//      transcript-stability auto-commit loop works unchanged
//
//  This deliberately stays read-mostly: the user picks a model in
//  Settings, the router warms it on launch, and from there each
//  hotkey press calls `start()` / `stop()` like any other backend.
//

import Foundation
import AVFoundation
import CoreML
import Observation
import WhisperKit

@MainActor
@Observable
final class WhisperKitTranscriber: LiveTranscriber {
    static let shared = WhisperKitTranscriber()

    // MARK: - LiveTranscriber identity

    nonisolated var kind: TranscriberKind { .whisperKit }

    // MARK: - Public state (LiveTranscriber)

    /// Concatenation of every confirmed and unconfirmed segment from
    /// the most recent decode pass. Updated after each periodic
    /// transcription tick during `start()`.
    private(set) var liveText: String = ""

    /// True once the selected model bundle is downloaded, prewarmed,
    /// and loaded into the active WhisperKit instance.
    private(set) var isReady: Bool = false

    /// True while the model bundle is being fetched from HuggingFace.
    /// The popup binds to this so the download progress bar replaces
    /// the live caption.
    private(set) var isDownloading: Bool = false

    /// 0…1 download progress for the active model bundle. WhisperKit
    /// streams progress via `progressCallback` during `download(...)`.
    private(set) var downloadProgress: Double = 0

    /// True between `start()` and `stop()`.
    private(set) var isRunning: Bool = false

    /// Last error, if any. Cleared on the next successful `start()`
    /// or `warm()`.
    private(set) var lastError: String?

    /// Smoothed 0…1 level for the popup waveform. Derived from the
    /// processor's `relativeEnergy` array on the same cadence as the
    /// Parakeet mic level so the visuals match.
    private(set) var currentLevel: Float = 0

    /// EOU/utterance hook. WhisperKit doesn't natively emit utterance
    /// boundaries the way FluidAudio does, so this stays nil — the
    /// controller's silence-stability detector does the pacing.
    var onUtterance: ((String) -> Void)?

    // MARK: - Private state

    private var whisperKit: WhisperKit?
    /// Identifier of the model the live `whisperKit` instance has
    /// loaded. We re-load on `warm()` whenever this drifts from
    /// `AppSettings.shared.whisperKitModel`.
    private var loadedModel: String?

    /// In-flight model load. Used to coalesce concurrent `warm()`
    /// calls so two callers don't race on the same HuggingFace
    /// download (which leaves stale `.incomplete` files behind and
    /// breaks the rename step).
    private var warmTask: Task<Void, Error>?

    /// Background task that drives `transcribeCurrentBuffer()` while
    /// `isRunning` is true.
    private var transcriptionTask: Task<Void, Never>?
    /// Background task that polls `relativeEnergy` and updates
    /// `currentLevel` so the popup waveform animates while WhisperKit
    /// owns the mic engine.
    private var levelTask: Task<Void, Never>?

    // Streaming bookkeeping — see `transcribeCurrentBuffer()` for how
    // these are used to split confirmed / unconfirmed segments.
    private var lastBufferSize: Int = 0
    private var lastConfirmedSegmentEndSeconds: Float = 0
    private var confirmedSegments: [TranscriptionSegment] = []
    private var unconfirmedSegments: [TranscriptionSegment] = []

    /// HuggingFace repo + on-disk cache root WhisperKit uses by
    /// default. We keep the same convention as Thinklet so a user
    /// who's already downloaded a model on iOS could (in theory)
    /// share it across devices.
    private let repoName = "argmaxinc/whisperkit-coreml"
    private let modelStoragePath = "huggingface/models/argmaxinc/whisperkit-coreml"

    private init() {
        NSLog("🟣 WhisperKitTranscriber.init — singleton came alive")
    }

    // MARK: - Lifecycle

    /// Download (if needed) and load the currently-selected WhisperKit
    /// model so the next `start()` is hot. Idempotent — a no-op when
    /// the desired model is already loaded, and concurrent calls
    /// piggy-back on the in-flight load instead of starting a second
    /// (racy) download.
    func warm() async throws {
        let desiredModel = AppSettings.shared.whisperKitModel
        // No model selected yet — the user hasn't been through
        // onboarding for a non-English language. Skip silently
        // rather than failing, so launch-time warmup doesn't log
        // a confusing error.
        guard !desiredModel.isEmpty else { return }
        if isReady, loadedModel == desiredModel { return }

        if let warmTask {
            try await warmTask.value
            return
        }

        NSLog("🟣 WhisperKit.warm — loading model '\(desiredModel)'")
        let task = Task<Void, Error> { [weak self] in
            guard let self else { return }
            try await self.loadModel(desiredModel)
        }
        warmTask = task
        do {
            try await task.value
            warmTask = nil
            NSLog("🟣 WhisperKit.warm — model '\(desiredModel)' ready")
        } catch {
            warmTask = nil
            throw error
        }
    }

    /// Start live recording + streaming transcription.
    func start() async throws {
        NSLog("🟣 WhisperKit.start — beginning (lang=\(AppSettings.shared.dictationLanguage.id), model=\(AppSettings.shared.whisperKitModel))")
        lastError = nil
        liveText = ""
        resetStreamingState()

        try await warm()
        guard let whisperKit, isReady else {
            NSLog("🟣 WhisperKit.start — model not ready, aborting")
            throw WhisperKitTranscriberError.modelNotLoaded
        }

        // WhisperKit's processor owns the AVAudioEngine for the
        // duration of the session. The realtime loop polls
        // `audioSamples` directly, so this callback is only used
        // for diagnostics.
        try whisperKit.audioProcessor.startRecordingLive { samples in
            // Audio thread — keep work minimal. The realtime loop
            // does the actual transcription work; this callback is
            // just here so we can plumb in diagnostics later.
            _ = samples.count
        }

        isRunning = true
        startRealtimeLoop()
        startLevelLoop()
        NSLog("🟣 WhisperKit.start — pipeline live")
    }

    /// Stop recording and run one final transcribe pass over whatever
    /// audio is still in the buffer so the tail words make it into
    /// `liveText` before the controller flushes them.
    @discardableResult
    func stop() async -> String {
        guard isRunning else { return liveText }
        isRunning = false

        transcriptionTask?.cancel()
        transcriptionTask = nil
        levelTask?.cancel()
        levelTask = nil

        whisperKit?.audioProcessor.stopRecording()

        // One last pass so the audio captured between the previous
        // tick and `stop()` actually gets decoded.
        do {
            try await transcribeCurrentBuffer(force: true)
        } catch {
            NSLog("🟣 WhisperKit.stop — final transcribe failed: \(error)")
        }

        currentLevel = 0
        let final = liveText
        if !final.isEmpty {
            onUtterance?(final)
        }
        return final
    }

    /// Clear streaming + transcript state without unloading the
    /// model. Mirrors `ParakeetTranscriber.reset()`.
    func reset() async {
        liveText = ""
        resetStreamingState()
    }

    // MARK: - Model loading

    private func loadModel(_ model: String) async throws {
        guard !model.isEmpty else {
            lastError = "No Whisper model selected. Pick one in Settings → Model."
            throw WhisperKitTranscriberError.modelNotLoaded
        }

        // Reset *all* derived state up front so the popup / settings
        // never display a stale "ready" badge alongside a fresh
        // error from a retry. Anything that survives until the
        // success block at the end stays nil/false.
        isReady = false
        lastError = nil
        whisperKit = nil
        loadedModel = nil

        let cachedFolder = locallyCachedFolder(for: model)
        let alreadyOnDisk = cachedFolder.map { folder in
            FileManager.default.fileExists(atPath: folder.path)
                && hasModelFiles(in: folder)
        } ?? false

        isDownloading = !alreadyOnDisk
        downloadProgress = alreadyOnDisk ? 1.0 : 0
        defer { isDownloading = false }

        // Resolve the folder the model lives in — either the local
        // cache or a freshly-downloaded copy. We do the download in
        // a separate step (rather than letting `WhisperKit(config)`
        // do it) so the popup / settings can render real download
        // progress instead of an indefinitely-spinning bar.
        let folder: URL
        do {
            folder = try await ensureModelOnDisk(
                model: model,
                cachedFolder: cachedFolder,
                alreadyOnDisk: alreadyOnDisk
            )
        } catch {
            lastError = "Failed to download model: \(error.localizedDescription)"
            NSLog("🟣 WhisperKit.loadModel — download failed: \(error)")
            throw error
        }

        let config = WhisperKitConfig(
            model: model,
            modelRepo: repoName,
            modelFolder: folder.path,
            computeOptions: ModelComputeOptions(
                audioEncoderCompute: .cpuAndNeuralEngine,
                textDecoderCompute: .cpuAndNeuralEngine
            ),
            verbose: false,
            logLevel: .error,
            prewarm: true,
            load: true,
            download: false
        )

        do {
            let kit = try await WhisperKit(config)
            whisperKit = kit
            loadedModel = model
            isReady = true
            lastError = nil
            downloadProgress = 1.0
            NSLog("🟣 WhisperKit.loadModel — '\(model)' loaded successfully")
        } catch {
            isReady = false
            whisperKit = nil
            loadedModel = nil
            lastError = "Failed to load model: \(error.localizedDescription)"
            NSLog("🟣 WhisperKit.loadModel — '\(model)' failed: \(error)")
            throw error
        }
    }

    /// Returns the on-disk folder containing the requested model,
    /// downloading it from HuggingFace if it's not already cached.
    /// Sweeps stale `.incomplete` files first because the HF Hub
    /// downloader will otherwise refuse to resume past them and
    /// produce the "couldn't be moved to whisper-base" error users
    /// have hit when retrying after a flaky download.
    private func ensureModelOnDisk(
        model: String,
        cachedFolder: URL?,
        alreadyOnDisk: Bool
    ) async throws -> URL {
        if alreadyOnDisk, let cachedFolder {
            return cachedFolder
        }

        // Pre-create the destination tree so HF Hub's rename step
        // never fails because a parent directory is missing.
        if let cachedFolder {
            try? FileManager.default.createDirectory(
                at: cachedFolder,
                withIntermediateDirectories: true
            )
            removeIncompleteArtifacts(in: cachedFolder)
        }

        let folder = try await WhisperKit.download(
            variant: model,
            from: repoName,
            progressCallback: { [weak self] progress in
                Task { @MainActor [weak self] in
                    // Reserve the last 10% for prewarm + load so
                    // the bar doesn't sit at 100% while CoreML does
                    // the heavy lift.
                    self?.downloadProgress = progress.fractionCompleted * 0.9
                }
            }
        )
        downloadProgress = 0.9
        return folder
    }

    /// Filesystem location the all-in-one WhisperKit init uses by
    /// default. Used so we can tell whether a model is already on
    /// disk and skip the download path entirely.
    private func locallyCachedFolder(for model: String) -> URL? {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        return documents
            .appendingPathComponent(modelStoragePath)
            .appendingPathComponent(model)
    }

    /// Whether the cached model folder actually has the .mlmodelc
    /// bundles WhisperKit needs. A bare directory with only
    /// metadata can fool `fileExists` and trick us into skipping a
    /// re-download that we actually need.
    private func hasModelFiles(in folder: URL) -> Bool {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: folder.path) else { return false }
        return entries.contains { $0.hasSuffix(".mlmodelc") || $0.hasSuffix(".mlpackage") }
    }

    /// Recursively delete any `*.incomplete` files left behind by a
    /// previous interrupted HuggingFace download. These stop the
    /// next `WhisperKit(config)` call from progressing past the
    /// rename step.
    private func removeIncompleteArtifacts(in folder: URL) {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: folder, includingPropertiesForKeys: nil) else { return }
        for case let url as URL in enumerator where url.pathExtension == "incomplete" || url.lastPathComponent.contains(".incomplete") {
            try? fm.removeItem(at: url)
        }
    }

    // MARK: - Realtime decode loop

    private func startRealtimeLoop() {
        transcriptionTask?.cancel()
        transcriptionTask = Task { [weak self] in
            while let self, !Task.isCancelled, self.isRunning {
                do {
                    try await self.transcribeCurrentBuffer(force: false)
                } catch {
                    if !Task.isCancelled {
                        NSLog("🟣 WhisperKit.realtimeLoop — error: \(error)")
                    }
                    break
                }
                try? await Task.sleep(for: .milliseconds(120))
            }
        }
    }

    /// Polls WhisperKit's accumulated audio buffer and runs a
    /// transcribe pass once enough fresh audio has arrived (or the
    /// caller forces a pass on `stop()`).
    private func transcribeCurrentBuffer(force: Bool) async throws {
        guard let whisperKit else {
            NSLog("🟣 transcribe — no whisperKit instance")
            return
        }

        let currentBuffer = whisperKit.audioProcessor.audioSamples
        let nextBufferSize = currentBuffer.count - lastBufferSize
        let nextBufferSeconds = Float(nextBufferSize) / Float(WhisperKit.sampleRate)

        if !force {
            // Wait for at least 1 s of new audio between passes —
            // WhisperKit's CoreML graph is heavy enough that decoding
            // every 100 ms saturates the ANE.
            guard nextBufferSeconds > 1.0 else { return }

            // Cheap VAD so we don't keep re-decoding silence. Use a
            // forgiving threshold — anything higher gates out quiet
            // speech (especially languages with softer phonemes).
            let energy = whisperKit.audioProcessor.relativeEnergy
            let voiceDetected = AudioProcessor.isVoiceDetected(
                in: energy,
                nextBufferInSeconds: nextBufferSeconds,
                silenceThreshold: 0.05
            )
            if !voiceDetected {
                let recentMax = energy.suffix(20).max() ?? 0
                NSLog("🟣 transcribe — silence (recent energy max=\(recentMax))")
                return
            }
        }

        let language = AppSettings.shared.dictationLanguage
        let isEnglish = language == .english
        // `nil` here is WhisperKit's "auto-detect" mode — we let the
        // model pick when the user explicitly chose Auto. Otherwise
        // we pass the resolved Whisper language code (`hi`, not
        // `hindi`; `fr`, not `french`; etc.).
        let effectiveLanguage = language.whisperLanguageCode

        NSLog("🟣 transcribe — pass: buffer=\(currentBuffer.count) samples (\(String(format: "%.1f", Float(currentBuffer.count) / Float(WhisperKit.sampleRate)))s), language=\(language.id), code=\(effectiveLanguage ?? "auto"), confirmedEnd=\(lastConfirmedSegmentEndSeconds)s")

        lastBufferSize = currentBuffer.count

        let seekClip: [Float] = lastConfirmedSegmentEndSeconds > 0 ? [lastConfirmedSegmentEndSeconds] : []

        // Deliberately permissive options. WhisperKit's defaults are
        // tuned for English benchmark accuracy and silently drop
        // non-English audio when the chunker's VAD or the
        // `noSpeechThreshold` decide the clip is silence. For live
        // dictation we'd rather see imperfect text than nothing.
        let options = DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: effectiveLanguage,
            temperature: 0,
            temperatureFallbackCount: 5,
            sampleLength: 224,
            usePrefillPrompt: true,
            usePrefillCache: true,
            skipSpecialTokens: true,
            withoutTimestamps: false,
            wordTimestamps: false,
            clipTimestamps: seekClip,
            suppressBlank: false,
            compressionRatioThreshold: isEnglish ? 2.4 : 2.8,
            logProbThreshold: -1.5,
            noSpeechThreshold: 0.3,
            concurrentWorkerCount: 1,
            chunkingStrategy: ChunkingStrategy.none
        )

        let results: [TranscriptionResult]
        do {
            results = try await whisperKit.transcribe(
                audioArray: Array(currentBuffer),
                decodeOptions: options
            )
        } catch {
            NSLog("🟣 transcribe — WhisperKit.transcribe threw: \(error)")
            throw error
        }

        let merged = TranscriptionUtilities.mergeTranscriptionResults(results)
        let segments = merged.segments
        NSLog("🟣 transcribe — got \(results.count) results → \(segments.count) segments, text='\(merged.text.prefix(80))'")
        guard !segments.isEmpty else { return }

        // Append confirmed segments to the rolling list so we keep
        // history; only re-decode the trailing tail. Advance
        // `lastConfirmedSegmentEndSeconds` so the next pass can
        // skip everything before the last confirmed segment.
        let requiredConfirmations = 2
        if segments.count > requiredConfirmations {
            let newConfirmed = Array(segments.prefix(segments.count - requiredConfirmations))
            let unconfirmed = Array(segments.suffix(requiredConfirmations))
            if let lastEnd = newConfirmed.last?.end, lastEnd > lastConfirmedSegmentEndSeconds {
                lastConfirmedSegmentEndSeconds = lastEnd
                confirmedSegments.append(contentsOf: newConfirmed)
            }
            unconfirmedSegments = unconfirmed
        } else {
            unconfirmedSegments = segments
        }

        let allSegments = confirmedSegments + unconfirmedSegments
        let fullText = allSegments
            .map { $0.text.trimmingCharacters(in: .whitespaces) }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if fullText != liveText {
            NSLog("🟣 transcribe — liveText updated: '\(fullText.prefix(120))'")
        }
        liveText = fullText
    }

    private func resetStreamingState() {
        lastBufferSize = 0
        lastConfirmedSegmentEndSeconds = 0
        confirmedSegments = []
        unconfirmedSegments = []
    }

    // MARK: - Waveform level loop

    /// WhisperKit's audio processor publishes a rolling
    /// `relativeEnergy` array (one Float per ~100 ms chunk). We poll
    /// the tail of it and apply the same cube-root compression /
    /// attack-decay shaping the Parakeet `MicrophoneCapture` does so
    /// the popup waveform looks identical between backends.
    private func startLevelLoop() {
        levelTask?.cancel()
        levelTask = Task { [weak self] in
            while let self, !Task.isCancelled, self.isRunning {
                self.tickLevel()
                try? await Task.sleep(for: .milliseconds(60))
            }
        }
    }

    private func tickLevel() {
        guard let whisperKit else { return }
        let energies = whisperKit.audioProcessor.relativeEnergy
        guard let latest = energies.last else { return }

        // Match `MicrophoneCapture.updateLevel` so the popup waveform
        // animates with the same feel regardless of backend.
        let compressed = pow(latest, 1.0 / 3.0) * 1.6
        let scaled = min(1, compressed)
        if scaled > currentLevel {
            currentLevel = currentLevel * 0.2 + scaled * 0.8
        } else {
            currentLevel = currentLevel * 0.92 + scaled * 0.08
        }
    }

    // MARK: - Errors

    enum WhisperKitTranscriberError: LocalizedError {
        case modelNotLoaded

        var errorDescription: String? {
            switch self {
            case .modelNotLoaded:
                return "WhisperKit isn't loaded yet. Open Settings → Model and download a Whisper variant."
            }
        }
    }
}

// MARK: - Convenience: model catalog

extension WhisperKitTranscriber {
    /// Hard-coded list of WhisperKit model variants we surface in the
    /// Settings picker. We avoid pulling `recommendedRemoteModels()`
    /// at launch so the UI stays responsive offline; users can still
    /// type any HuggingFace variant by editing UserDefaults.
    static let availableModels: [String] = [
        "openai_whisper-tiny",
        "openai_whisper-base",
        "openai_whisper-small",
        "openai_whisper-medium",
        "openai_whisper-large-v3-v20240930_turbo",
    ]

    /// Human-friendly label for a model id.
    static func displayName(for model: String) -> String {
        let trimmed = model.replacingOccurrences(of: "openai_whisper-", with: "")
        switch trimmed {
        case "tiny":   return "Tiny — Fastest, ~75 MB"
        case "base":   return "Base — Good balance, ~140 MB"
        case "small":  return "Small — Better accuracy, ~460 MB"
        case "medium": return "Medium — High accuracy, ~1.5 GB"
        case "large-v3-v20240930_turbo": return "Large v3 Turbo — Best, ~950 MB"
        default:       return trimmed.capitalized
        }
    }
}
