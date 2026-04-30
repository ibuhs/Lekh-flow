//
//  ModelSettingsTab.swift
//  Lekh Flow
//
//  The "Model" settings tab. The user picks a language at the top —
//  English routes to Parakeet (low-latency streaming) and everything
//  else routes to WhisperKit (multilingual). Both backend panels
//  are always visible so the user can pre-download or reload either
//  one independently of which language is currently active.
//

import SwiftUI

struct ModelSettingsTab: View {
    private var controller: DictationController { .shared }
    @State private var isWarming = false

    var body: some View {
        @Bindable var settings = controller.settings

        Form {
            Section("Language") {
                Picker("Dictation language", selection: $settings.dictationLanguage) {
                    ForEach(DictationLanguage.all) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                }
                .pickerStyle(.menu)
                HStack(spacing: 6) {
                    Image(systemName: "cpu")
                        .foregroundStyle(.tint)
                    Text("Active backend: ")
                        .foregroundStyle(.secondary)
                    Text(settings.dictationLanguage.preferredBackend.displayName)
                        .fontWeight(.semibold)
                }
                .font(.callout)
                Text(settings.dictationLanguage.preferredBackend == .parakeet
                     ? "English uses NVIDIA's Parakeet streaming model — sub-second latency, no language switching."
                     : "Non-English routes through WhisperKit's multilingual Whisper models. Pick a model below.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            ParakeetModelSection(isWarming: $isWarming)
            WhisperKitModelSection(isWarming: $isWarming)

            Section("About on-device dictation") {
                Text("Audio never leaves your Mac. Both Parakeet (FluidAudio) and Whisper (WhisperKit) run on Apple Silicon's Neural Engine via CoreML.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Section header with active-backend pill

private struct BackendSectionHeader: View {
    let title: String
    let isActive: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
            if isActive {
                Text("ACTIVE")
                    .font(.system(size: 9, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(Color.accentColor)
                    )
            }
        }
    }
}

// MARK: - Parakeet (English) section

private struct ParakeetModelSection: View {
    @Binding var isWarming: Bool
    private var settings: AppSettings { .shared }
    private var parakeet: ParakeetTranscriber { .shared }

    var body: some View {
        @Bindable var bindable = settings
        let isActive = bindable.dictationLanguage.preferredBackend == .parakeet
        Group {
            Section {
                Picker("Latency vs accuracy", selection: $bindable.chunkSize) {
                    ForEach(LFChunkSize.allCases) { size in
                        Text(size.displayName).tag(size)
                    }
                }
                .pickerStyle(.inline)
                Text("Switching variants requires re-downloading the matching model bundle (~150 MB each).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } header: {
                BackendSectionHeader(title: "Parakeet — Streaming Quality", isActive: isActive)
            }
            Section("Parakeet — Model State") {
                HStack {
                    Image(systemName: parakeet.isReady ? "checkmark.circle.fill" : "circle.dotted")
                        .foregroundStyle(parakeet.isReady ? .green : .secondary)
                    Text(parakeet.isReady
                         ? "Parakeet \(bindable.chunkSize.displayName.lowercased()) is loaded and ready."
                         : "Model not loaded yet.")
                    Spacer()
                    if parakeet.isDownloading {
                        ProgressView(value: parakeet.downloadProgress)
                            .frame(width: 100)
                    } else {
                        Button(parakeet.isReady ? "Reload" : "Download now") {
                            warm()
                        }
                        .disabled(isWarming)
                    }
                }
            }
        }
    }

    private func warm() {
        isWarming = true
        Task {
            try? await parakeet.warm()
            isWarming = false
        }
    }
}

// MARK: - WhisperKit (other languages) section

private struct WhisperKitModelSection: View {
    @Binding var isWarming: Bool
    private var settings: AppSettings { .shared }
    private var whisper: WhisperKitTranscriber { .shared }

    var body: some View {
        @Bindable var bindable = settings
        let isActive = bindable.dictationLanguage.preferredBackend == .whisperKit
        Group {
            Section {
                Picker("Whisper model", selection: $bindable.whisperKitModel) {
                    if bindable.whisperKitModel.isEmpty {
                        Text("— Pick a model —").tag("")
                    }
                    ForEach(WhisperKitTranscriber.availableModels, id: \.self) { id in
                        Text(WhisperKitTranscriber.displayName(for: id)).tag(id)
                    }
                }
                .pickerStyle(.menu)
                Text("Larger models are more accurate but slower and use more memory. Each model downloads once and is cached locally.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Label("WhisperKit shows live transcription in the popup, but it commits only when you press the shortcut again to stop dictation.", systemImage: "keyboard")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } header: {
                BackendSectionHeader(title: "Whisper — Model", isActive: isActive)
            }
            Section("Whisper — Model State") {
                HStack {
                    Image(systemName: whisper.isReady ? "checkmark.circle.fill" : "circle.dotted")
                        .foregroundStyle(whisper.isReady ? .green : .secondary)
                    Text(stateText(model: bindable.whisperKitModel))
                    Spacer()
                    if whisper.isDownloading {
                        ProgressView(value: whisper.downloadProgress)
                            .frame(width: 100)
                    } else {
                        Button(whisper.isReady ? "Reload" : "Download now") {
                            warm()
                        }
                        .disabled(isWarming || bindable.whisperKitModel.isEmpty)
                    }
                }
                if whisper.isDownloading {
                    Text("\(Int(whisper.downloadProgress * 100))% downloaded — this may take a few minutes for larger models.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if !whisper.isReady, let error = whisper.lastError {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private func stateText(model: String) -> String {
        if model.isEmpty {
            return "No model selected — pick one above."
        }
        if whisper.isReady {
            return "\(WhisperKitTranscriber.displayName(for: model)) is loaded and ready."
        }
        return "Model not loaded yet."
    }

    private func warm() {
        isWarming = true
        Task {
            try? await whisper.warm()
            isWarming = false
        }
    }
}
