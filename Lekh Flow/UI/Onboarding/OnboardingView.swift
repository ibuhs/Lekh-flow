//
//  OnboardingView.swift
//  Lekh Flow
//
//  Five-step first-launch flow:
//    1. Welcome — what is Lekh Flow.
//    2. Microphone permission.
//    3. Accessibility permission (so paste-into-app works).
//    4. Pick a global shortcut.
//    5. Download the streaming Parakeet model.
//

import SwiftUI
import KeyboardShortcuts

enum OnboardingStep: Int, CaseIterable {
    case welcome
    case microphone
    case accessibility
    case shortcut
    case model
    case done
}

struct OnboardingView: View {
    let dictation: DictationController
    let onFinish: () -> Void

    @State private var step: OnboardingStep = .welcome

    /// Mirrors `KeyboardShortcuts.getShortcut(for: .toggleDictation) != nil`.
    /// Updated by `ShortcutStep`'s `onChange` callback so the primary
    /// button label flips from "Set later" → "Continue" the instant
    /// the user commits a shortcut. KeyboardShortcuts.Recorder doesn't
    /// publish to SwiftUI's observation system, so we mirror it here.
    @State private var shortcutIsSet: Bool = KeyboardShortcuts.getShortcut(for: .toggleDictation) != nil

    var body: some View {
        // Diagnostic: if this counter ever blows up at idle in
        // Console.app, we know SwiftUI is in a render loop.
        let _ = Self._renderCount.advance()
        return ZStack {
            background
            VStack(spacing: 0) {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, 48)
                    .padding(.top, 36)

                footer
                    .padding(.horizontal, 48)
                    .padding(.bottom, 36)
            }
        }
        .frame(width: 720, height: 520)
    }

    /// Per-process render counter logged every 30 evaluations. Lets us
    /// catch SwiftUI re-evaluation storms without spamming Console.
    private final class RenderCounter: @unchecked Sendable {
        private var count = 0
        func advance() {
            count += 1
            if count % 30 == 0 { NSLog("🟡 OnboardingView.body rendered \(count) times") }
        }
    }
    private static let _renderCount = RenderCounter()

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome:
            WelcomeStep()
        case .microphone:
            MicrophoneStep(dictation: dictation)
        case .accessibility:
            AccessibilityStep(dictation: dictation)
        case .shortcut:
            ShortcutStep(onShortcutChange: { shortcut in
                shortcutIsSet = shortcut != nil
                // Re-register the hotkey handlers so the new shortcut
                // becomes live immediately — without this the user
                // would have to restart the app for the hotkey to fire.
                dictation.registerHotkey()
            })
        case .model:
            ModelStep(dictation: dictation)
        case .done:
            DoneStep()
        }
    }

    private var footer: some View {
        HStack {
            ProgressDots(current: step)
            Spacer()
            if step != .welcome {
                Button("Back") {
                    if let prev = OnboardingStep(rawValue: step.rawValue - 1) {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                            step = prev
                        }
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
            Button(primaryButtonLabel) {
                advance()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!canAdvance)
        }
    }

    private var primaryButtonLabel: String {
        switch step {
        case .welcome:       return "Get started"
        case .microphone:    return dictation.permissions.microphoneAuthorized ? "Continue" : "Grant access"
        case .accessibility: return dictation.permissions.accessibilityAuthorized ? "Continue" : "Open System Settings"
        case .shortcut:      return shortcutIsSet ? "Continue" : "Set later"
        case .model:         return dictation.transcriber.isReady ? "Finish" : (dictation.transcriber.isDownloading ? "Downloading…" : "Download model")
        case .done:          return "Finish"
        }
    }

    private var canAdvance: Bool {
        switch step {
        case .model:
            return !dictation.transcriber.isDownloading
        default:
            return true
        }
    }

    private func advance() {
        switch step {
        case .welcome:
            withAnimation(.spring) { step = .microphone }
        case .microphone:
            if dictation.permissions.microphoneAuthorized {
                withAnimation(.spring) { step = .accessibility }
            } else {
                Task {
                    await dictation.permissions.requestMicrophone()
                    if dictation.permissions.microphoneAuthorized {
                        withAnimation(.spring) { step = .accessibility }
                    }
                }
            }
        case .accessibility:
            if dictation.permissions.accessibilityAuthorized {
                withAnimation(.spring) { step = .shortcut }
            } else {
                dictation.permissions.openAccessibilitySettings()
            }
        case .shortcut:
            withAnimation(.spring) { step = .model }
        case .model:
            if dictation.transcriber.isReady {
                withAnimation(.spring) { step = .done }
            } else {
                Task {
                    try? await dictation.transcriber.warm()
                    if dictation.transcriber.isReady {
                        withAnimation(.spring) { step = .done }
                    }
                }
            }
        case .done:
            onFinish()
        }
    }

    private var background: some View {
        // macOS 26 (Tahoe) re-rasterises `.thinMaterial` constantly when
        // it sits behind a moving SwiftUI tree, which was driving the
        // launch-time CPU spike. Use a flat window background instead.
        Color(nsColor: .windowBackgroundColor)
            .overlay(
                LinearGradient(
                    colors: [
                        Color.accentColor.opacity(0.14),
                        Color.clear,
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .ignoresSafeArea()
    }
}

// MARK: - Step shared chrome

struct StepShell<Content: View>: View {
    let icon: String
    let title: String
    let subtitle: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(LinearGradient(
                                colors: [.accentColor, .accentColor.opacity(0.65)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ))
                    )
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                    Text(subtitle)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
            }
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Steps

struct WelcomeStep: View {
    var body: some View {
        StepShell(
            icon: "sparkles",
            title: "Welcome to Lekh Flow",
            subtitle: "Press a key. Speak. Watch your words land in any app."
        ) {
            VStack(alignment: .leading, spacing: 14) {
                FeatureBullet(
                    icon: "mic.fill",
                    title: "Push-to-talk dictation",
                    detail: "A single global shortcut starts and stops transcription."
                )
                FeatureBullet(
                    icon: "lock.shield.fill",
                    title: "100% on-device",
                    detail: "Audio never leaves your Mac. Powered by Parakeet via FluidAudio."
                )
                FeatureBullet(
                    icon: "bolt.fill",
                    title: "Lives in the menu bar",
                    detail: "Out of sight until you summon it. Settings whenever you need them."
                )
            }
        }
    }
}

struct MicrophoneStep: View {
    let dictation: DictationController
    var body: some View {
        StepShell(
            icon: "mic.fill",
            title: "Microphone access",
            subtitle: "We need to hear you in order to transcribe you."
        ) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Lekh Flow only listens while you hold (or have toggled on) your shortcut. The audio is processed locally and immediately discarded — nothing is recorded to disk.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                StatusBadge(
                    granted: dictation.permissions.microphoneAuthorized,
                    grantedText: "Microphone access granted",
                    waitingText: "Waiting for permission…"
                )
            }
        }
        .onAppear { dictation.permissions.refresh() }
    }
}

struct AccessibilityStep: View {
    let dictation: DictationController
    var body: some View {
        StepShell(
            icon: "keyboard",
            title: "Accessibility access",
            subtitle: "Required so the transcript can be pasted into your focused app."
        ) {
            VStack(alignment: .leading, spacing: 16) {
                Text("macOS treats simulated keystrokes as a privileged action. Open System Settings and turn the Lekh Flow toggle on under Privacy & Security → Accessibility.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                StatusBadge(
                    granted: dictation.permissions.accessibilityAuthorized,
                    grantedText: "Accessibility granted",
                    waitingText: "Waiting for permission…"
                )
                Button("Open Privacy & Security…") {
                    dictation.permissions.openAccessibilitySettings()
                }
                .buttonStyle(.bordered)
            }
        }
        .onAppear {
            dictation.permissions.refresh()
            dictation.permissions.requestAccessibility()
        }
        .onDisappear {
            dictation.permissions.stopPollingAccessibility()
        }
    }
}

struct ShortcutStep: View {
    let onShortcutChange: (KeyboardShortcuts.Shortcut?) -> Void

    var body: some View {
        StepShell(
            icon: "command",
            title: "Pick a shortcut",
            subtitle: "This is the key you'll press from anywhere to summon Lekh Flow."
        ) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Tap the recorder, press your desired combination, then press it again to confirm. Right ⌥, F5 or ⌃Space all make great choices.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                HStack {
                    Text("Toggle dictation")
                        .font(.system(size: 13, weight: .medium))
                    Spacer()
                    KeyboardShortcuts.Recorder(for: .toggleDictation, onChange: onShortcutChange)
                }
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.secondary.opacity(0.10))
                )
            }
        }
    }
}

struct ModelStep: View {
    let dictation: DictationController
    var body: some View {
        StepShell(
            icon: "cpu",
            title: "Download Parakeet",
            subtitle: "A one-time ~150 MB download. Then everything runs offline."
        ) {
            VStack(alignment: .leading, spacing: 18) {
                if dictation.transcriber.isReady {
                    StatusBadge(granted: true, grantedText: "Model loaded — you're ready to dictate.", waitingText: "")
                } else if dictation.transcriber.isDownloading {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Downloading model bundle…")
                            Spacer()
                            Text("\(Int(dictation.transcriber.downloadProgress * 100))%")
                                .monospacedDigit()
                        }
                        ProgressView(value: dictation.transcriber.downloadProgress)
                    }
                } else {
                    Text("Click the primary button below to start the download.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct DoneStep: View {
    var body: some View {
        StepShell(
            icon: "checkmark.seal.fill",
            title: "You're set up",
            subtitle: "Press your shortcut from any app and start talking."
        ) {
            VStack(alignment: .leading, spacing: 14) {
                FeatureBullet(
                    icon: "menubar.dock.rectangle",
                    title: "Find Lekh Flow in the menu bar",
                    detail: "Quick actions, status, and settings live there."
                )
                FeatureBullet(
                    icon: "gear",
                    title: "Tweak anything later",
                    detail: "Change the shortcut, completion behaviour, or model variant from Settings."
                )
            }
        }
    }
}

// MARK: - Reusable bits

struct FeatureBullet: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 26, height: 26)
                .background(
                    Circle().fill(Color.accentColor.opacity(0.12))
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }
}

struct StatusBadge: View {
    let granted: Bool
    let grantedText: String
    let waitingText: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(granted ? .green : .secondary)
                .font(.system(size: 16, weight: .semibold))
            Text(granted ? grantedText : waitingText)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(granted ? .primary : .secondary)
            Spacer()
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.secondary.opacity(0.10))
        )
    }
}

struct ProgressDots: View {
    let current: OnboardingStep

    var body: some View {
        HStack(spacing: 6) {
            ForEach(OnboardingStep.allCases, id: \.self) { step in
                Capsule()
                    .fill(step == current ? Color.accentColor : Color.secondary.opacity(0.25))
                    .frame(width: step == current ? 22 : 8, height: 8)
                    .animation(.spring(response: 0.4, dampingFraction: 0.85), value: current)
            }
        }
    }
}
