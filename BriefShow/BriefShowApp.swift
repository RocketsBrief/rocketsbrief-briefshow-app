//
//  BriefShowApp.swift
//  BriefShow
//
//  Created by Esti Wahyuni on 7/6/26.
//

import SwiftUI

@main
struct BriefShowApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 1180, height: 560)
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
    }
}
