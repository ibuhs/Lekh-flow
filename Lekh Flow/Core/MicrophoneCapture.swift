//
//  MicrophoneCapture.swift
//  Lekh Flow
//
//  Thin wrapper around AVAudioEngine that delivers 16 kHz mono Float32
//  PCM buffers to whoever installed an `onBuffer` handler. That format
//  is exactly what FluidAudio's streaming Parakeet manager expects, so
//  we do the resampling once here rather than letting every consumer
//  re-derive it.
//
//  We also expose an instantaneous RMS-derived level via `level` so the
//  popup waveform can animate without having to peek at PCM data
//  itself.
//

import Foundation
@preconcurrency import AVFoundation
import Observation

@MainActor
@Observable
final class MicrophoneCapture {
    /// 0…1 instantaneous level. Smoothed with a small exponential decay
    /// so the waveform feels organic.
    private(set) var level: Float = 0

    /// True between `start()` and `stop()`. Drives the popup's
    /// "recording" UI.
    private(set) var isCapturing: Bool = false

    /// Called for each downmixed-to-16kHz-mono buffer. Always invoked
    /// on the main actor to make plumbing into the transcriber simple.
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    /// Cached output format we hand to the converter — always 16 kHz
    /// mono Float32 to match Parakeet's expectations.
    private let targetFormat: AVAudioFormat = {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        )!
    }()

    /// Diagnostic: how many input buffers we've delivered since last
    /// start. Logged the first time and then every 50 buffers so we
    /// can see in Console whether audio is actually flowing.
    private var bufferCount = 0

    func start() throws {
        guard !isCapturing else { return }

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        NSLog("🎤 mic.start — input format: \(inputFormat)")

        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw NSError(
                domain: "MicrophoneCapture",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Couldn't build AVAudioConverter"]
            )
        }
        self.converter = converter
        let target = targetFormat
        bufferCount = 0

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            // Convert synchronously on the audio thread so the converter
            // never enters an end-of-stream terminal state between tap
            // callbacks. Hop to the main actor only with the already-
            // converted 16 kHz mono buffer.
            guard let outBuffer = Self.convert(buffer, with: converter, to: target) else { return }
            Task { @MainActor [weak self] in
                self?.deliver(outBuffer)
            }
        }

        engine.prepare()
        try engine.start()
        isCapturing = true
        NSLog("🎤 mic.start — engine running")
    }

    func stop() {
        guard isCapturing else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isCapturing = false
        level = 0
    }

    private nonisolated static func convert(
        _ buffer: AVAudioPCMBuffer,
        with converter: AVAudioConverter,
        to target: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let ratio = target.sampleRate / buffer.format.sampleRate
        let outCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1024)
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outCapacity) else { return nil }

        var error: NSError?
        var feedDone = false
        let status = converter.convert(to: outBuffer, error: &error) { _, outStatus in
            if feedDone {
                // Keep the converter reusable for the next tap callback.
                outStatus.pointee = .noDataNow
                return nil
            }
            feedDone = true
            outStatus.pointee = .haveData
            return buffer
        }

        guard status != .error, error == nil, outBuffer.frameLength > 0 else { return nil }
        return outBuffer
    }

    private func deliver(_ outBuffer: AVAudioPCMBuffer) {
        bufferCount += 1
        if bufferCount == 1 || bufferCount % 50 == 0 {
            NSLog("🎤 mic — delivered buffer #\(bufferCount) (frames=\(outBuffer.frameLength))")
        }
        updateLevel(from: outBuffer)
        onBuffer?(outBuffer)
    }

    private func updateLevel(from buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData?[0] else { return }
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return }

        var sumSquares: Float = 0
        var peak: Float = 0
        for i in 0..<frameLength {
            let s = channelData[i]
            sumSquares += s * s
            let abs_s = abs(s)
            if abs_s > peak { peak = abs_s }
        }
        let rms = sqrt(sumSquares / Float(frameLength))

        // RMS for conversational speech rarely exceeds ~0.15 and quiet
        // speech sits at ~0.02. Cube-root + a hot gain compresses that
        // so the bars actually swing across most of their range for
        // everyday talking; peak-blending keeps consonants/transients
        // snappy.
        let compressed = pow(rms, 1.0 / 3.0) * 1.6
        let mixed = max(compressed, peak * 1.2)
        let scaled = min(1, mixed)

        // Snappy attack so the very first syllable jumps; slow decay
        // so brief inter-word silences don't collapse the row.
        if scaled > level {
            level = level * 0.2 + scaled * 0.8
        } else {
            level = level * 0.92 + scaled * 0.08
        }
    }
}
