//
//  AboutSettingsTab.swift
//  Lekh Flow
//

import SwiftUI

struct AboutSettingsTab: View {
    var compact: Bool = false

    private var brandIcon: NSImage {
        if let url = Bundle.main.url(forResource: "icon", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        return NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
    }

    var body: some View {
        VStack(spacing: compact ? 14 : 18) {
            Image(nsImage: brandIcon)
                .resizable()
                .interpolation(.high)
                .frame(width: compact ? 64 : 84, height: compact ? 64 : 84)
                .clipShape(RoundedRectangle(cornerRadius: compact ? 14 : 18, style: .continuous))
            Text("Lekh Flow")
                .font(.system(size: 22, weight: .semibold, design: .rounded))
            Text("Version \(Bundle.main.shortVersion) (\(Bundle.main.buildNumber))")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("System-wide on-device dictation powered by Parakeet & FluidAudio.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, compact ? 18 : 40)
            Text("Made with ❤️ in 🇨🇦 by Shubi")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            if !compact {
                Spacer()
            }
        }
        .padding(.top, compact ? 22 : 30)
        .padding(.bottom, compact ? 20 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension Bundle {
    var shortVersion: String {
        (infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0"
    }
    var buildNumber: String {
        (infoDictionary?["CFBundleVersion"] as? String) ?? "1"
    }
}
