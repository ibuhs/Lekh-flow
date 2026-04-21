//
//  WaveformView.swift
//  Lekh Flow
//
//  Animated row of soundbars driven by `MicrophoneCapture.level`. The
//  bars carry a small staggered phase so even at constant level the
//  row "breathes" instead of looking like a flat row of rectangles.
//

import SwiftUI

struct WaveformView: View {
    /// 0…1 instantaneous mic level.
    let level: Float

    /// Master colour. Bars fade from transparent at the bottom to this
    /// colour at the top via a vertical gradient.
    var color: Color = .accentColor

    /// Number of bars across. 28 reads as "richly textured" without
    /// looking like a spectrogram.
    var barCount: Int = 28

    @State private var phase: Double = 0

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { context in
            let now = context.date.timeIntervalSinceReferenceDate
            GeometryReader { geo in
                let totalWidth = geo.size.width
                let totalHeight = geo.size.height
                let spacing: CGFloat = 4
                let barWidth = (totalWidth - spacing * CGFloat(barCount - 1)) / CGFloat(barCount)
                HStack(spacing: spacing) {
                    ForEach(0..<barCount, id: \.self) { index in
                        Capsule(style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        color.opacity(0.55),
                                        color.opacity(0.95),
                                    ],
                                    startPoint: .bottom,
                                    endPoint: .top
                                )
                            )
                            .frame(width: barWidth, height: barHeight(for: index, time: now, max: totalHeight))
                    }
                }
                .frame(width: totalWidth, height: totalHeight, alignment: .center)
            }
        }
    }

    /// Per-bar height = baseline + scaled mic level + small sine ripple.
    private func barHeight(for index: Int, time: TimeInterval, max maxHeight: CGFloat) -> CGFloat {
        // Boost so even moderate levels (~0.3) drive the bars to a
        // satisfying height. The mic-side computation already
        // compresses RMS into 0…1 but most conversation lives in the
        // bottom half of that range.
        let lvl = CGFloat(min(1, max(0, pow(level, 0.7) * 1.4)))
        // Baseline keeps the row visible even in dead silence.
        let baseline: CGFloat = 4
        // Spatial offset so the wave appears to travel left→right.
        let phaseOffset = Double(index) * 0.35
        let ripple = sin(time * 5.5 + phaseOffset) * 0.5 + 0.5  // 0…1
        // Bell-curve weighting — louder bars sit in the middle, edges
        // are quieter for visual focus. Softer falloff (1.05 vs 1.4)
        // so edge bars also visibly respond.
        let centre = Double(barCount - 1) / 2
        let dist = abs(Double(index) - centre) / centre
        let envelope = pow(1.0 - dist, 1.05)

        let dynamic = lvl * (CGFloat(0.7 + 0.3 * ripple)) * CGFloat(envelope)
        let height = baseline + dynamic * (maxHeight - baseline)
        return min(maxHeight, max(baseline, height))
    }
}
