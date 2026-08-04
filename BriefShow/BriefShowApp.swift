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
    }
}
