//
//  BriefShowApp.swift
//  BriefShow
//
//  Created by Esti Wahyuni on 7/6/26.
//

import SwiftUI
import CoreText
import UniformTypeIdentifiers
import AppKit

@main
struct BriefShowApp: App {
    init() {
        Self.registerBundledFonts()
    }

    // "Figtree" and "Unbounded" are only available on Macs where they
    // happen to be installed system-wide (e.g. this dev machine's Font
    // Book) unless the app registers its own bundled copy — without this,
    // every other Mac silently falls back to the system font.
    private static func registerBundledFonts() {
        for resourceName in ["Figtree-VariableFont_wght", "Unbounded-VariableFont_wght"] {
            guard let url = Bundle.main.url(forResource: resourceName, withExtension: "ttf") else {
                continue
            }

            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    // ShowGrid — Desktop folder tree on the left, photo grid on the
    // right — is the app's first (and main) screen now, replacing the old
    // two-card BriefShow/ShowGrid Welcome chooser. BriefShow itself is
    // still reachable from ShowGrid's own "BriefShow" header button,
    // which opens it as a separate window via BriefShowWindowController.
    var body: some Scene {
        WindowGroup {
            PhotoShowSheet(onClose: {})
                .frame(minWidth: 700, minHeight: 480)
        }
        .defaultSize(width: 1400, height: 900)
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .commands {
            // Edit ▸ Keyboard Shortcuts…
            //
            // ONE item, deliberately, rather than a menu listing every command
            // with its key equivalent. Both of this app's keyboard shortcuts
            // live in local NSEvent monitors scoped by window title, and a menu
            // key equivalent for the same key would be a second claimant on
            // every press — two paths to the same action, racing, with the
            // client's own rebinding visible in only one of them. The window
            // that opens IS the list, and it is the editable one.
            CommandGroup(after: .pasteboard) {
                Divider()
                Button("Keyboard Shortcuts…") {
                    ShortcutsWindowController.shared.open()
                }
            }
        }
    }
}

/// The Keyboard Shortcuts window.
///
/// Its own window rather than a sheet: the shortcuts it lists belong to two
/// different windows, so hanging it off either one would have said it was
/// about that one. Built the same way LumenoLab's is, including activating
/// BEFORE ordering front — see DevelopWindowController for why that order is
/// not interchangeable.
final class ShortcutsWindowController {
    static let shared = ShortcutsWindowController()

    static let windowTitle = "Keyboard Shortcuts"

    private var windowController: NSWindowController?

    private init() {}

    func open() {
        if let controller = windowController, controller.window?.isVisible == true {
            NSApp.activate(ignoringOtherApps: true)
            controller.window?.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 640),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = Self.windowTitle
        window.isReleasedWhenClosed = false
        window.center()
        window.contentView = NSHostingView(rootView: ShortcutsView())

        let controller = NSWindowController(window: window)
        windowController = controller

        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }
}
