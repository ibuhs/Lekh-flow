//
//  ModelSettingsTab.swift
//  Lekh Flow
//

import SwiftUI

struct ModelSettingsTab: View {
    private var controller: DictationController { .shared }
    @State private var isWarming = false

    var body: some View {
        @Bindable var settings = controller.settings

        Form {
            Section("Streaming Quality") {
                Picker("Latency vs accuracy", selection: $settings.chunkSize) {
                    ForEach(LFChunkSize.allCases) { size in
                        Text(size.displayName).tag(size)
                    }
                }
                .pickerStyle(.inline)
                Text("Switching variants requires re-downloading the matching model bundle (~150 MB each).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section("Model State") {
                HStack {
                    Image(systemName: controller.transcriber.isReady
                          ? "checkmark.circle.fill"
                          : "circle.dotted")
                        .foregroundStyle(controller.transcriber.isReady ? .green : .secondary)
                    Text(controller.transcriber.isReady
                         ? "Parakeet \(settings.chunkSize.displayName.lowercased()) is loaded and ready."
                         : "Model not loaded yet.")
                    Spacer()
                    if controller.transcriber.isDownloading {
                        ProgressView(value: controller.transcriber.downloadProgress)
                            .frame(width: 100)
                    } else {
                        Button(controller.transcriber.isReady ? "Reload" : "Download now") {
                            isWarming = true
                            Task {
                                try? await controller.transcriber.warm()
                                isWarming = false
                            }
                        }
                        .disabled(isWarming)
                    }
                }
            }
            Section("About Parakeet") {
                Text("Lekh Flow uses NVIDIA's Parakeet 120M streaming ASR model via the FluidAudio CoreML runtime. Everything runs on your Mac's Apple Silicon — no audio leaves the device.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
