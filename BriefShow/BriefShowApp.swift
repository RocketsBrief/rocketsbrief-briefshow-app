//
//  BriefShowApp.swift
//  BriefShow
//
//  Created by Esti Wahyuni on 7/6/26.
//

import SwiftUI
import CoreText

@main
struct BriefShowApp: App {
    init() {
        Self.registerBundledFonts()
    }

    // "Figtree" is only available on Macs where it happens to be
    // installed system-wide (e.g. this dev machine's Font Book) unless
    // the app registers its own bundled copy — without this, every
    // other Mac silently falls back to the system font.
    private static func registerBundledFonts() {
        guard let url = Bundle.main.url(
            forResource: "Figtree-VariableFont_wght",
            withExtension: "ttf"
        ) else {
            return
        }

        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 1180, height: 560)
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
    }
}
