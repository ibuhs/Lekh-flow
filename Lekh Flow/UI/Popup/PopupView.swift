//
//  PopupView.swift
//  Lekh Flow
//
//  The visible UI of the dictation popup. Top half is the live
//  caption (or model-download progress, or error), bottom half is the
//  animated waveform + control row. Wrapped in a glassy capsule that
//  sits on top of every other window via NonActivatingPanel.
//

import SwiftUI
import AppKit

struct PopupView: View {
    @Bindable var model: PopupViewModel

    var body: some View {
        VStack(spacing: 0) {
            content
                .padding(.horizontal, 22)
                .padding(.vertical, 18)
        }
        .background(background)
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: .black.opacity(0.14), radius: 10, x: 0, y: 4)
        .frame(width: 560)
        .padding(3) // minimal room so the softer shadow doesn't clip
    }

    @ViewBuilder
    private var content: some View {
        if let error = model.errorMessage {
            errorView(error)
        } else if let final = model.finalText {
            finalView(final)
        } else if model.isModelDownloading {
            downloadingView
        } else {
            liveView
        }
    }

    // MARK: - Live transcription

    private var liveView: some View {
        VStack(alignment: .leading, spacing: 14) {
            transcriptText
            HStack(spacing: 14) {
                statusDot
                WaveformView(level: model.micLevel, color: .accentColor)
                    .frame(height: 28)
                    .padding(.horizontal, 4)
                Text(hotkeyHint)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                cancelButton
            }
        }
    }

    private var transcriptText: some View {
        let text = model.transcript
        return Group {
            if text.isEmpty {
                Text("Listening…")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            } else {
                Text(text)
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                    .truncationMode(.head)
                    .transition(.opacity)
                    .animation(.easeOut(duration: 0.12), value: text)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var statusDot: some View {
        Circle()
            .fill(Color.red)
            .frame(width: 8, height: 8)
            .opacity(0.85)
            .overlay(
                Circle()
                    .stroke(Color.red.opacity(0.35), lineWidth: 4)
                    .scaleEffect(1.6)
                    .opacity(model.micLevel > 0.05 ? 0.6 : 0.2)
                    .animation(.easeOut(duration: 0.25), value: model.micLevel)
            )
    }

    private var hotkeyHint: String {
        if model.backendKind == .whisperKit {
            switch model.hotkeyMode {
            case .toggle:     return "Tap shortcut again to commit"
            case .pushToTalk: return "Release to commit"
            }
        }
        switch model.hotkeyMode {
        case .toggle:     return "Tap shortcut to finish"
        case .pushToTalk: return "Release to finish"
        }
    }

    private var cancelButton: some View {
        Button {
            model.cancel()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .bold))
                .frame(width: 22, height: 22)
                .foregroundStyle(.secondary)
                .background(
                    Circle()
                        .fill(Color.primary.opacity(0.08))
                )
        }
        .buttonStyle(.plain)
        .help("Cancel (Esc)")
    }

    // MARK: - Model download

    private var downloadingView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.tint)
                Text("Downloading \(model.backendKind.displayName) model…")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                Spacer()
                Text("\(Int(model.modelDownloadProgress * 100))%")
                    .font(.system(size: 13, weight: .medium, design: .rounded).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: model.modelDownloadProgress)
                .progressViewStyle(.linear)
                .tint(.accentColor)
            Text("Lekh Flow runs entirely on-device. Model bundles are cached after the first download.")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Final transcript (keep-on-screen mode)

    private func finalView(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Transcript")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    model.controller.cancel()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 22, height: 22)
                        .foregroundStyle(.secondary)
                        .background(Circle().fill(Color.primary.opacity(0.08)))
                }
                .buttonStyle(.plain)
            }
            ScrollView {
                Text(text)
                    .font(.system(size: 16, weight: .regular, design: .rounded))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 180)

            HStack(spacing: 10) {
                Spacer()
                Button {
                    model.copyFinal()
                    model.controller.cancel()
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)

                Button {
                    model.pasteFinal()
                    model.controller.cancel()
                } label: {
                    Label("Paste", systemImage: "arrow.down.doc")
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: - Error

    private func errorView(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Lekh Flow can't dictate yet")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                Spacer()
                Button {
                    model.controller.cancel()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 22, height: 22)
                        .foregroundStyle(.secondary)
                        .background(Circle().fill(Color.primary.opacity(0.08)))
                }
                .buttonStyle(.plain)
            }
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                Spacer()
                Button("Open System Settings") {
                    PermissionsManager.shared.openMicrophoneSettings()
                }
                .buttonStyle(.bordered)
            }
        }
    }

    // MARK: - Background

    private var background: some View {
        // Deliberately flat, non-vibrant fill. Using `NSVisualEffectView`
        // here creates a subtle frosted halo around the capsule that
        // reads as unwanted blur/gradient in screenshots.
        Color(nsColor: NSColor.windowBackgroundColor)
            .opacity(0.98)
    }
}
