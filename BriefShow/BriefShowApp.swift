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
// @Published and ObservableObject live here. SwiftUI re-exports them in most
// projects, but this target builds with SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_
// VISIBILITY, which turns that convenience off — the module has to be imported
// where its members are used.
import Combine
// LSRegisterURL — see reregisterWithLaunchServicesIfVersionChanged.
import CoreServices

/// A folder handed to BriefShow from OUTSIDE the app — dropped on the Dock
/// icon, or opened through Finder's "Open With ▸ C4S Suite".
///
/// A holding place rather than a direct call into the view, because the two
/// events do not happen in a fixed order. Dropping a folder on the icon of an
/// app that is NOT running launches it, and the delegate callback can arrive
/// before ShowGrid's view exists to be told anything. So the delegate parks the
/// URL here and the view collects it whenever it turns up — which covers the
/// cold-launch case and the already-running case with the same code.
@MainActor
final class ExternalFolderOpen: ObservableObject {
    static let shared = ExternalFolderOpen()

    /// Set by the delegate, cleared by whoever acts on it.
    @Published var pendingFolder: URL?

    private init() {}
}

/// Handles folders arriving from outside the app.
///
/// This is the second half of the fix; the first half is CFBundleDocumentTypes
/// in Info.plist. Neither works alone — without the declaration Finder refuses
/// the drop and this is never called, and without this the drop is accepted and
/// nothing happens.
final class BriefShowAppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        // Only folders can actually arrive, since Info.plist declares only
        // public.folder — but filtered anyway rather than trusting that, because
        // "Open With" can be pointed at this app by hand.
        let folders = urls.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        }
        guard let folder = folders.first else {
            return
        }

        // A URL handed over this way comes with its own sandbox extension, and
        // that extension has to be claimed before the folder can be read. It is
        // never released: the folder stays open in the window for as long as the
        // client is looking at it, and RootFolderAccess beside it holds the home
        // grant the same way for the same reason.
        //
        // ⚠️ Session only. A folder OUTSIDE the client's home folder — an
        // external drive, a network share — is readable now but not after a
        // relaunch, because no bookmark is stored for it. Anything under home is
        // already covered by RootFolderAccess's own bookmark.
        _ = folder.startAccessingSecurityScopedResource()

        ExternalFolderOpen.shared.pendingFolder = folder

        // Brought forward, but NOT opened: creating a window from here is what
        // KORAK 51 found produces two of them. The window either already exists
        // or is being created by WindowGroup right now; either way it collects
        // the URL above by itself.
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Asks ShowGrid to open the import window. Set by File ▸ Import…, cleared by
/// the view that acts on it — the same holding-place pattern
/// `ExternalFolderOpen` above uses, and for the same reason: a menu command
/// cannot reach into a SwiftUI view.
@MainActor
final class ImportWindowRequest: ObservableObject {
    static let shared = ImportWindowRequest()
    @Published var pending: ImportSource?
    private init() {}
}

@main
struct BriefShowApp: App {
    @NSApplicationDelegateAdaptor(BriefShowAppDelegate.self) private var appDelegate

    init() {
        Self.registerBundledFonts()

        Self.reregisterWithLaunchServicesIfVersionChanged()

        // The "one email, one computer" check runs from the app itself,
        // not from a view: the client can be sitting in ShowGrid, the
        // BriefShow editor, LumenoLab or a full-screen slideshow, and the
        // seat has to keep being verified in all four.
        Task { @MainActor in SeatManager.shared.start() }

        // ⚠️ THE EARLIEST HONEST MOMENT to start loading the AI weights, and
        // the reason it moved here.
        //
        // Loading them is once per LAUNCH, not once ever — see the load-state
        // block in DevelopSDInpaint.swift. It used to start when LumenoLab
        // opened, which sounds early but is not: by then the client has picked
        // a photo and is a few seconds from painting, and on a Mac with no
        // Neural Engine the load is far longer than that. Reported from an
        // Intel Mac as a first Generative Clean Up of 1.5–2 minutes against 15
        // seconds for every one after it.
        //
        // Here it runs while the client is still choosing a folder — minutes
        // of real time, on a machine doing nothing else yet.
        //
        // Costs nothing when the feature is not in play: `warmUp()` returns
        // immediately if the weights are not installed, which is every client
        // who has not downloaded them. LumenoLab still calls it too, and that
        // is deliberate — it is idempotent, and it is the backstop for a
        // process where this ran before an install finished.
        SDInpaintPipeline.shared.warmUp()

        // Keeps the thumbnail cache under its budget. Once per launch, off
        // the main thread, and it reads the directory listing rather than the
        // files — see ThumbnailDiskCache.
        DispatchQueue.global(qos: .utility).async {
            ThumbnailDiskCache.pruneIfNeeded()
        }
    }

    /// Makes a NEW APP ICON actually appear after the client replaces the app
    /// in /Applications.
    ///
    /// macOS caches an app's icon in IconServices, keyed off the bundle's
    /// identity and version. Replacing a bundle at the same path, with the same
    /// CFBundleIdentifier and the same CFBundleVersion, is precisely the case
    /// where the system decides nothing changed and keeps drawing the old icon
    /// — for days, until something else flushes the cache.
    ///
    /// ⚠️ THE PRIMARY FIX IS NOT THIS FUNCTION, IT IS CURRENT_PROJECT_VERSION.
    /// That number was **17 in every build shipped so far — 6.0 and 10.1
    /// alike** (measured 2.09. across four built bundles). A build number that
    /// never moves is the strongest signal a client's Mac has that the app it
    /// just replaced is the same app. **It has to be incremented on every
    /// release**, and that is a release step, not something code can enforce.
    ///
    /// What this adds on top: after a version change, LaunchServices is told to
    /// re-read this bundle — the API behind `lsregister -f`. Cheap, and it runs
    /// only when the version actually moved, not on every launch.
    ///
    /// ⚠️ Not a guarantee, and it should not be sold as one. A tile the client
    /// has PINNED to the Dock is drawn from the Dock's own copy, and that one
    /// only lets go when the Dock restarts or the Mac does. If a future icon
    /// change still looks stale in the Dock, that is why, and it is not a bug
    /// in the app.
    private static func reregisterWithLaunchServicesIfVersionChanged() {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        let stamp = "\(short) (\(build))"

        let key = "com.rocketsbrief.briefshow.lastLaunchedBundleVersion"
        guard UserDefaults.standard.string(forKey: key) != stamp else {
            return
        }
        UserDefaults.standard.set(stamp, forKey: key)

        // Written before the call, not after: if registering ever hangs or
        // crashes, it must not do so on every single launch from then on.
        _ = LSRegisterURL(Bundle.main.bundleURL as CFURL, true)
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
    // still reachable from ShowGrid's own "C4S Suite" header button,
    // which opens it as a separate window via BriefShowWindowController.
    /// Only so Edit ▸ Theme has something to bind to. The rest of the app
    /// reads ThemeManager.shared directly.
    @ObservedObject private var themeManager = ThemeManager.shared

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
                .keyboardShortcut("k", modifiers: [.command, .shift])

                // ⚠️ Straight to defaults, without opening the window. It is
                // the one thing a client wants from a menu when a rebinding
                // has gone wrong — including a rebinding that took the key
                // they would use to reach the window.
                //
                // No confirmation, because there is nothing to lose that is
                // not one keystroke away from being set again, and every
                // binding it clears is visible in the window it does not open.
                Button("Reset Shortcuts to Defaults") {
                    ShortcutStore.resetAll()
                }

                Divider()

                // Edit ▸ Theme, where the three dots under the logo used to be.
                //
                // A theme is a preference, and a preference belongs in a menu
                // with a name on it — three unlabelled circles on the app's
                // first screen said nothing about what they were. Written in
                // the order the client names them: White, Sand, Dark.
                //
                // A Picker rather than three Buttons: it draws the tick beside
                // whichever theme is on, which is the one thing three separate
                // buttons could not do without each of them checking the state
                // itself.
                Picker("Theme", selection: $themeManager.current) {
                    ForEach([AppTheme.white, .buttery, .dark]) { theme in
                        Text(theme.title).tag(theme)
                    }
                }

                Divider()

                // ⚠️ NO Undo/Redo here, and that is deliberate. Both live in
                // local NSEvent monitors scoped by window title; a menu key
                // equivalent for ⌘Z would be a SECOND claimant on the same
                // press, racing the monitor, and the client's own rebinding
                // would show in only one of the two. The rule this file
                // already states for the shortcuts list applies to every
                // editing command: the monitors own the keys.
            }

            // File ▸ Import…
            //
            // The same window a connected camera opens by itself, reached by
            // hand — for the times nothing is plugged in and the photos are on
            // a card in a reader, or already in a folder somewhere. It opens
            // pointed at a folder the client chooses, and Choose Source… inside
            // it can repoint it afterwards.
            //
            // `.newItem` is where Open… lives, which is where a photographer
            // looks for Import.
            CommandGroup(after: .newItem) {
                Button("Import…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.allowsMultipleSelection = false
                    panel.prompt = "Import"
                    panel.message = "Choose the card or folder to import from."
                    // A card in a reader mounts under /Volumes, and that is the
                    // common case for this menu item.
                    panel.directoryURL = URL(fileURLWithPath: "/Volumes")

                    guard panel.runModal() == .OK, let chosen = panel.url else {
                        return
                    }
                    ImportWindowRequest.shared.pending = .folder(chosen)
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])

                // Open a folder the way any Mac app does. The same door the
                // Finder drop and "Open With" already use — the delegate parks
                // a URL on ExternalFolderOpen and ShowGrid collects it — so
                // this needed no new plumbing and cannot drift from the drop.
                Button("Open Folder…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.allowsMultipleSelection = false
                    panel.prompt = "Open"
                    panel.message = "Choose a folder of photos to open."
                    guard panel.runModal() == .OK, let chosen = panel.url else {
                        return
                    }
                    ExternalFolderOpen.shared.pendingFolder = chosen
                }
                .keyboardShortcut("o", modifiers: [.command])

                Divider()

                // The camera window, by hand. It opens by itself when a camera
                // is plugged in (KORAK 35), and this is for the camera that was
                // ALREADY plugged in when the app launched — the one case that
                // deliberately does not pop a window.
                //
                // Disabled with nothing connected rather than hidden: a File
                // menu that changes shape depending on what is plugged in is a
                // menu the client cannot learn.
                Button("Import from Camera…") {
                    guard let camera = CameraBrowser.shared.cameras.first else {
                        return
                    }
                    ImportWindowRequest.shared.pending = .camera(camera)
                }
                .disabled(CameraBrowser.shared.cameras.isEmpty)

                Divider()

                // Where the app keeps what it makes, which is otherwise
                // invisible: the flattened copies and the layer pixels. Asked
                // about directly — "where are my originals, where is the rest"
                // — and the honest answer is that the originals are in the
                // client's own folder and NOTHING else of his is anywhere but
                // here.
                Button("Show App Files in Finder") {
                    guard let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                                              in: .userDomainMask).first else {
                        return
                    }
                    let directory = base.appendingPathComponent("BriefShow", isDirectory: true)
                    try? FileManager.default.createDirectory(at: directory,
                                                             withIntermediateDirectories: true)
                    NSWorkspace.shared.activateFileViewerSelecting([directory])
                }
            }

            // Help ▸ the two things a client actually looks for there.
            CommandGroup(replacing: .help) {
                Button("C4S Suite Help") {
                    if let url = URL(string: "https://github.com/\(Self.repositoryPath)") {
                        NSWorkspace.shared.open(url)
                    }
                }

                Button("Check for Updates…") {
                    if let url = URL(string: "https://github.com/\(Self.repositoryPath)/releases/latest") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }

    /// Written once. Both Help items point at the same repository, and a second
    /// hand-typed copy is a second thing to get wrong.
    private static let repositoryPath = "RocketsBrief/rocketsbrief-briefshow-app"
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
