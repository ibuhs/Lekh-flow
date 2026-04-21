//
//  DictationController.swift
//  Lekh Flow
//
//  The single source of truth for "is the user dictating right now?".
//  Owns the global hotkey registration, the popup window, the
//  microphone, and the Parakeet transcriber. Everything else in the
//  app reads its state through this controller and tells it to start
//  / stop.
//

import Foundation
import AppKit
import AVFoundation
import KeyboardShortcuts
import Observation

@MainActor
@Observable
final class DictationController {
    /// Process-wide singleton. Other singletons (AppSettings,
    /// PermissionsManager, ParakeetTranscriber) all use the same
    /// pattern, so we follow suit rather than threading the instance
    /// through @NSApplicationDelegateAdaptor — accessing
    /// `appDelegate.dictation` from the App body was causing scene
    /// re-evaluation thrash on macOS 26.
    static let shared = DictationController()

    /// The popup window controller. Built lazily because constructing
    /// an NSPanel before the app finishes launching causes AppKit to
    /// log "no eventTap" warnings.
    private var popup: PopupWindowController?

    private let mic = MicrophoneCapture()

    /// Whether the popup is currently on screen and recording.
    private(set) var isActive: Bool = false

    /// True between hotkey-press and hotkey-release in `pushToTalk`
    /// mode. Used so we don't end recording when a stray release event
    /// arrives without a matching down event (which can happen if the
    /// user presses the hotkey while the popup is animating in).
    private var pttArmed: Bool = false

    /// True after we've live-pasted at least one utterance in the
    /// current session. Used so consecutive utterances get a leading
    /// space ("hello" + "world" → "hello world", not "helloworld") and
    /// only the first segment gets auto-capitalised.
    private var hasInjectedSegment: Bool = false
    private var lastInjectedTranscript: String = ""
    private var deliveredTranscript: String = ""
    private var autoCommitTask: Task<Void, Never>?
    private var lastObservedTranscript: String = ""
    private var lastTranscriptActivityAt = Date.distantPast
    private var hasPendingTranscriptChange = false

    private let silenceCommitDelay: TimeInterval = 0.45

    // Live observers — view layer can read these directly.
    var transcriber: ParakeetTranscriber { ParakeetTranscriber.shared }
    var settings: AppSettings { AppSettings.shared }
    var permissions: PermissionsManager { PermissionsManager.shared }
    var microphone: MicrophoneCapture { mic }

    init() {
        // Wire mic buffers straight into the transcriber. Set once and
        // forget — append() is a no-op when the transcriber isn't running.
        mic.onBuffer = { [weak self] buffer in
            guard let self else { return }
            self.transcriber.append(buffer)
        }

        // We intentionally do not use FluidAudio's built-in EOU callback
        // to decide when to paste. In practice it's a bit sluggish and
        // has been unreliable after the first utterance in a session.
        // Instead we run our own lightweight silence detector on top of
        // the rolling transcript and paste deltas ourselves.
        transcriber.onUtterance = nil
    }

    /// Called from the app delegate after launch. Idempotent.
    func bootstrap() {
        registerHotkey()
    }

    // MARK: - Hotkey

    func registerHotkey() {
        // Always reset both handlers — the user may be reconfiguring
        // them at runtime through the Settings → Shortcut tab.
        KeyboardShortcuts.removeAllHandlers()
        let bound = KeyboardShortcuts.getShortcut(for: .toggleDictation)
        NSLog("🎹 registerHotkey — current binding: \(bound.map(String.init(describing:)) ?? "<none>")")
        KeyboardShortcuts.onKeyDown(for: .toggleDictation) { [weak self] in
            NSLog("🎹 hotkey keyDown fired")
            Task { @MainActor [weak self] in
                self?.handleKeyDown()
            }
        }
        KeyboardShortcuts.onKeyUp(for: .toggleDictation) { [weak self] in
            NSLog("🎹 hotkey keyUp fired")
            Task { @MainActor [weak self] in
                self?.handleKeyUp()
            }
        }
    }

    private func handleKeyDown() {
        NSLog("🎹 handleKeyDown — mode=\(settings.hotkeyMode) isActive=\(isActive)")
        switch settings.hotkeyMode {
        case .toggle:
            if isActive {
                Task { await stop(commit: true) }
            } else {
                Task { await start() }
            }
        case .pushToTalk:
            // Only react to the *first* keydown in a press — KeyboardShortcuts
            // can fire repeats while held.
            guard !isActive else { return }
            pttArmed = true
            Task { await start() }
        }
    }

    private func handleKeyUp() {
        guard settings.hotkeyMode == .pushToTalk else { return }
        guard pttArmed else { return }
        pttArmed = false
        Task { await stop(commit: true) }
    }

    // MARK: - Lifecycle

    /// Cancel without committing. Used by the popup's Esc-to-cancel
    /// shortcut and the "X" button.
    func cancel() {
        Task { await stop(commit: false) }
    }

    func start() async {
        NSLog("▶️ start() called — already active? \(isActive)")
        guard !isActive else { return }

        let mic = await permissions.requestMicrophone()
        NSLog("▶️ start() — mic permission: \(mic)")
        if !mic {
            presentPopupForPermissionDenied()
            return
        }

        showPopup()
        isActive = true
        hasInjectedSegment = false
        lastInjectedTranscript = ""
        deliveredTranscript = ""
        lastObservedTranscript = ""
        lastTranscriptActivityAt = Date()
        hasPendingTranscriptChange = false
        transcriber.onUtterance = nil
        NSLog("▶️ start() — popup presented, isActive=true; booting transcriber + mic")

        do {
            try await transcriber.start()
            NSLog("▶️ start() — transcriber.start() returned")
            try self.mic.start()
            NSLog("▶️ start() — mic.start() returned; pipeline live")
            startAutoCommitLoop()
            playStartSound()
        } catch {
            NSLog("⚠️ start() — failed: \(error)")
            isActive = false
            autoCommitTask?.cancel()
            autoCommitTask = nil
            popup?.showError("Couldn't start dictation: \(error.localizedDescription)")
        }
    }

    /// Stop continuous dictation. Text has been streamed live to the
    /// focused app via `onUtterance` throughout the session, so all
    /// this does is flush the tail audio (any words spoken since the
    /// last EOU) — those final words are pasted via `onUtterance` too
    /// — then dismiss the popup. `commit:false` is used by the popup
    /// X / Esc to suppress that tail when the user wants to throw away
    /// the in-flight thought.
    func stop(commit: Bool) async {
        NSLog("⏹ stop() called — commit=\(commit) isActive=\(isActive)")
        guard isActive else { return }
        isActive = false

        autoCommitTask?.cancel()
        autoCommitTask = nil
        mic.stop()
        if commit {
            let finalText = await transcriber.stop()
            injectAvailableTranscript(from: finalText)
        } else {
            transcriber.onUtterance = nil
            _ = await transcriber.stop()
        }

        hidePopup()
        playStopSound()
        await transcriber.reset()
        hasInjectedSegment = false
        lastInjectedTranscript = ""
        deliveredTranscript = ""
        lastObservedTranscript = ""
        hasPendingTranscriptChange = false
    }

    private func startAutoCommitLoop() {
        autoCommitTask?.cancel()
        autoCommitTask = Task { [weak self] in
            while let self, !Task.isCancelled, self.isActive {
                await MainActor.run {
                    self.tickAutoCommit()
                }
                try? await Task.sleep(for: .milliseconds(90))
            }
        }
    }

    private func tickAutoCommit() {
        let currentTranscript = transcriber.liveText.trimmingCharacters(in: .whitespacesAndNewlines)
        let now = Date()

        if currentTranscript != lastObservedTranscript {
            lastObservedTranscript = currentTranscript
            lastTranscriptActivityAt = now
            if !currentTranscript.isEmpty {
                hasPendingTranscriptChange = true
            }
            return
        }

        guard hasPendingTranscriptChange else { return }
        guard now.timeIntervalSince(lastTranscriptActivityAt) >= silenceCommitDelay else { return }
        if injectAvailableTranscript(from: transcriber.liveText) {
            hasPendingTranscriptChange = false
        }
    }

    @discardableResult
    private func injectAvailableTranscript(from transcript: String) -> Bool {
        let current = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !current.isEmpty else { return false }

        let delta: String
        if lastInjectedTranscript.isEmpty {
            delta = current
        } else if current.hasPrefix(lastInjectedTranscript) {
            delta = String(current.dropFirst(lastInjectedTranscript.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else if current == lastInjectedTranscript {
            delta = ""
        } else {
            // If the engine ever rewrites earlier text, prefer duplicating
            // a little over dropping fresh dictation on the floor.
            delta = current
        }

        let processed = postprocess(delta)
        guard !processed.isEmpty else { return false }

        let deliveredDelta = hasInjectedSegment ? " " + processed : processed
        NSLog("✏️ auto-commit — '\(deliveredDelta)' action=\(settings.completionAction.rawValue)")
        switch settings.completionAction {
        case .pasteIntoFocused:
            _ = TextInjector.paste(deliveredDelta)
        case .copyToClipboard:
            deliveredTranscript += deliveredDelta
            TextInjector.copy(deliveredTranscript)
        }
        hasInjectedSegment = true
        lastInjectedTranscript = current
        lastObservedTranscript = current
        if settings.completionAction == .pasteIntoFocused {
            deliveredTranscript += deliveredDelta
        }
        return true
    }

    // MARK: - Popup

    private func showPopup() {
        if popup == nil {
            popup = PopupWindowController(controller: self)
        }
        popup?.present()
    }

    private func hidePopup() {
        popup?.dismiss()
    }

    private func presentPopupForPermissionDenied() {
        if popup == nil {
            popup = PopupWindowController(controller: self)
        }
        popup?.present()
        popup?.showError("Microphone access is denied. Open System Settings → Privacy & Security → Microphone and turn it on for Lekh Flow.")
    }

    // MARK: - Sounds

    private func playStartSound() {
        guard settings.playSounds else { return }
        NSSound(named: .init("Tink"))?.play()
    }

    private func playStopSound() {
        guard settings.playSounds else { return }
        NSSound(named: .init("Pop"))?.play()
    }

    // MARK: - Post-processing

    private func postprocess(_ raw: String) -> String {
        var result = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if settings.autoCapitalize, let first = result.first, first.isLowercase {
            result = String(first).uppercased() + result.dropFirst()
        }
        return result
    }
}
