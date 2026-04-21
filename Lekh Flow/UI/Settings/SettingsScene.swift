//
//  SettingsScene.swift
//  Lekh Flow
//
//  Tabbed Settings window. Stays minimal — Lekh Flow has so few knobs
//  that splitting them across more than four tabs would feel hollow.
//

import SwiftUI

struct SettingsScene: View {
    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }
            ShortcutSettingsTab()
                .tabItem { Label("Shortcut", systemImage: "command") }
            ModelSettingsTab()
                .tabItem { Label("Model", systemImage: "cpu") }
            AboutSettingsTab()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .padding(20)
    }
}
