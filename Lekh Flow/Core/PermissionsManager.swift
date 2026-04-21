//
//  PermissionsManager.swift
//  Lekh Flow
//
//  Tracks the two permissions Lekh Flow actually needs:
//    1. Microphone — required to capture audio for Parakeet.
//    2. Accessibility — required to synthesise the ⌘V keystroke that
//       pastes the transcript into the focused text field.
//
//  We poll the Accessibility state on a short timer because there's no
//  Apple-blessed callback when the user flips the switch in System
//  Settings — but the user is going to do exactly that during onboarding,
//  and the UI needs to react.
//

import Foundation
import AVFoundation
import AppKit
import ApplicationServices
import Observation

@MainActor
@Observable
final class PermissionsManager {
    static let shared = PermissionsManager()

    private(set) var microphoneAuthorized: Bool = false
    private(set) var accessibilityAuthorized: Bool = false

    private var pollTimer: Timer?

    private init() {
        refresh()
    }

    func refresh() {
        microphoneAuthorized = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        accessibilityAuthorized = AXIsProcessTrusted()
    }

    /// Ask the system for microphone permission. Returns the final state
    /// — either previously-granted, freshly-granted, or denied.
    @discardableResult
    func requestMicrophone() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            microphoneAuthorized = true
            return true
        case .notDetermined:
            let granted = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    cont.resume(returning: granted)
                }
            }
            microphoneAuthorized = granted
            return granted
        case .denied, .restricted:
            microphoneAuthorized = false
            return false
        @unknown default:
            microphoneAuthorized = false
            return false
        }
    }

    /// Open the Accessibility prompt and start polling the trust state
    /// so the UI flips green the moment the user grants it. Caller is
    /// responsible for calling `stopPollingAccessibility()` once the UI
    /// no longer needs live updates (e.g. when onboarding is dismissed).
    func requestAccessibility() {
        let prompt: [String: Bool] = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        accessibilityAuthorized = AXIsProcessTrustedWithOptions(prompt as CFDictionary)
        startPollingAccessibility()
    }

    /// Pop System Settings → Privacy & Security → Accessibility so the
    /// user can flip our switch on without hunting through panes.
    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        startPollingAccessibility()
    }

    func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    private func startPollingAccessibility() {
        pollTimer?.invalidate()
        // Poll every 0.75s — fast enough that the UI feels live, slow
        // enough that we don't burn battery. Stops itself once the user
        // grants access. We schedule on the main run loop so the timer
        // body runs MainActor-isolated implicitly without dancing
        // around Sendable captures.
        let timer = Timer(timeInterval: 0.75, repeats: true) { _ in
            MainActor.assumeIsolated {
                PermissionsManager.shared.tickAccessibilityPoll()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func tickAccessibilityPoll() {
        let trusted = AXIsProcessTrusted()
        if trusted != accessibilityAuthorized {
            accessibilityAuthorized = trusted
        }
        if trusted {
            stopPollingAccessibility()
        }
    }

    func stopPollingAccessibility() {
        pollTimer?.invalidate()
        pollTimer = nil
    }
}
