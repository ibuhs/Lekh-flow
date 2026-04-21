//
//  TextInjector.swift
//  Lekh Flow
//
//  Drops the final transcript into whichever app was focused when the
//  user pressed the hotkey. Two strategies in order of preference:
//
//   1. Direct insert via the Accessibility API. We grab the focused
//      `AXUIElement`, look up its `AXSelectedTextRange`, and use
//      `AXSelectedTextAttributedString`-style injection by setting
//      `AXValue`. This works in most cocoa text fields and Electron
//      apps that support AX. No clipboard pollution, no race with the
//      user typing.
//
//   2. Clipboard-then-paste fallback. Copy the text to the pasteboard,
//      synthesise ⌘V, and (after a short delay) restore the original
//      pasteboard contents. This is universally supported but loses
//      anything the user had on the clipboard for a brief moment.
//
//  Either path requires Accessibility permission. If that's missing
//  the popup will fall back to "copy-only" mode and tell the user how
//  to grant it.
//

import Foundation
import AppKit
import ApplicationServices

@MainActor
enum TextInjector {

    /// Best-effort paste of `text` into the focused text field of the
    /// frontmost app. Returns `true` if the text appears to have been
    /// delivered; `false` only if both the AX path and the keystroke
    /// fallback could not run (e.g. no Accessibility permission).
    @discardableResult
    static func paste(_ text: String) -> Bool {
        guard !text.isEmpty else { return true }

        let trusted = AXIsProcessTrusted()
        let frontBundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "<nil>"
        NSLog("✏️ TextInjector.paste — AXIsProcessTrusted=\(trusted) frontApp=\(frontBundle) text='\(text)'")

        // We deliberately skip the AX-direct insertion path. It works
        // in vanilla Cocoa text views but every Electron / Chromium
        // app (Cursor, VS Code, Slack, Discord, Linear, Notion,
        // ChatGPT desktop, anything built with todesktop) accepts the
        // AXSelectedText set call and returns .success without
        // actually inserting anything visible. The clipboard +
        // synthesised ⌘V path is universal — works identically in
        // native, Electron, browser, and terminal apps.
        if !trusted {
            // Without AX trust we can't post synthetic key events. Best
            // we can do is leave the text on the clipboard so the user
            // can hit ⌘V manually.
            copy(text)
            NSLog("✏️ TextInjector.paste — no AX trust, text only copied to clipboard")
            return false
        }

        let ok = pasteViaKeystroke(text)
        NSLog("✏️ TextInjector.paste — pasteViaKeystroke returned \(ok)")
        return ok
    }

    /// Copy without pasting. Used when the user picks "Copy to
    /// clipboard" as their completion action, or as the safety net
    /// when Accessibility permission is missing.
    static func copy(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    // MARK: - Strategy 1: AX direct insert

    private static func insertViaAccessibility(_ text: String) -> Bool {
        let systemWide = AXUIElementCreateSystemWide()

        var focusedRef: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        )
        guard err == .success, let focusedRef else { return false }
        let focused = focusedRef as! AXUIElement

        // Try `AXSelectedText` first — the most surgical option.
        let setErr = AXUIElementSetAttributeValue(
            focused,
            kAXSelectedTextAttribute as CFString,
            text as CFString
        )
        if setErr == .success {
            return true
        }

        // Some elements only honour `AXValue` (replaces the whole
        // contents), so we don't take that path here — it would clobber
        // pre-existing text. Bail and let the keystroke fallback handle
        // it.
        return false
    }

    // MARK: - Strategy 2: clipboard + ⌘V

    private static func pasteViaKeystroke(_ text: String) -> Bool {
        let pb = NSPasteboard.general
        // Snapshot whatever was on the clipboard so we can restore it
        // after the paste completes.
        let savedItems = pb.pasteboardItems?.map { item -> [NSPasteboard.PasteboardType: Data] in
            var dict: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    dict[type] = data
                }
            }
            return dict
        } ?? []

        pb.clearContents()
        pb.setString(text, forType: .string)

        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            return false
        }

        // ANSI 'v' = 0x09
        let vKey: CGKeyCode = 0x09
        let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        cmdDown?.flags = .maskCommand
        let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        cmdUp?.flags = .maskCommand

        cmdDown?.post(tap: .cgAnnotatedSessionEventTap)
        cmdUp?.post(tap: .cgAnnotatedSessionEventTap)

        // Restore the clipboard a moment later so the paste actually
        // takes effect first. 0.5s is plenty for the destination app
        // to read the data.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            pb.clearContents()
            for snap in savedItems {
                let item = NSPasteboardItem()
                for (type, data) in snap {
                    item.setData(data, forType: type)
                }
                pb.writeObjects([item])
            }
        }

        return true
    }
}
