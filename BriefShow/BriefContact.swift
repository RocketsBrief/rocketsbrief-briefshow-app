import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers
import Combine
import WebKit

// BriefContact in C4S Suite — asked for on 25.09: the photographer UPLOADS a
// client's photos here, sets how they look on the web (every control the web
// gallery has: lines, flicker, People only, flashlight, the guard), sets the
// price list, and presses Create link. The buyer on that link sees the photos
// exactly as set here, with no controls, marks the ones they want, pays, and
// either downloads at once or gets a link by email. Every paid order lands in
// the company's Orders list, in this window.
//
// The web side is its own project: ~/Desktop/BriefContact (Cloudflare Pages +
// D1 + R2), notes in BRIEFCONTACT_NOTES.md there. The company is recognised
// by this Mac's C4S sign-in — the server asks Supabase whose token it is.

enum BriefContactConfig {
    /// Where the galleries live. `briefContact.server` overrides it, for a
    /// local server (`npm run dev` in ~/Desktop/BriefContact).
    static var server: URL {
        if let s = UserDefaults.standard.string(forKey: "briefContact.server"), let url = URL(string: s) { return url }
        return URL(string: "https://briefcontact.pages.dev")!
    }

    /// Local testing only: the local server accepts this in place of a C4S
    /// sign-in (`DEV_AUTH_TOKEN` in its .dev.vars). Never used for a server
    /// that is not on this Mac.
    static var devToken: String? {
        guard let host = server.host, host == "127.0.0.1" || host == "localhost" else { return nil }
        return UserDefaults.standard.string(forKey: "briefContact.devToken")
    }
}

final class BriefContactWindowController {
    static let shared = BriefContactWindowController()
    private var windowController: NSWindowController?
    private var appearanceObserver: AnyCancellable?
    private init() {}

    // Native controls (pickers, steppers, sliders) take light or dark from
    // the window; everything else paints from AppColors. See the same note
    // on the BriefShow window in ContentView.
    private func syncAppearance(of window: NSWindow, _ theme: AppTheme) {
        window.appearance = NSAppearance(named: theme == .dark ? .darkAqua : .aqua)
    }

    func open() {
        if let controller = windowController, controller.window?.isVisible == true {
            NSApp.activate(ignoringOtherApps: true)
            controller.window?.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1240, height: 840),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "BriefContact"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 980, height: 620)
        window.center()
        window.contentView = NSHostingView(rootView: BriefContactView())
        syncAppearance(of: window, ThemeManager.shared.current)
        appearanceObserver = ThemeManager.shared.$current.sink { [weak self, weak window] theme in
            if let window { self?.syncAppearance(of: window, theme) }
        }
        let controller = NSWindowController(window: window)
        windowController = controller
        // Activate BEFORE ordering front — see DevelopWindowController.
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Server

enum BriefContactError: LocalizedError {
    case notSignedIn
    case server(String)
    var errorDescription: String? {
        switch self {
        case .notSignedIn: return "Sign in to C4S Suite first."
        case .server(let message): return message
        }
    }
}

@MainActor
enum BriefContactAPI {
    /// The C4S sign-in token. A token lasts an hour, so a 401 refreshes it
    /// once and tries again.
    private static func token() throws -> String {
        if let dev = BriefContactConfig.devToken { return dev }
        guard let session = AccountManager.shared.session else { throw BriefContactError.notSignedIn }
        return session.accessToken
    }

    @discardableResult
    static func call(_ method: String, _ path: String, query: [URLQueryItem] = [],
                     body: Data? = nil, contentType: String = "application/json") async throws -> Data {
        for attempt in 0..<2 {
            var parts = URLComponents(url: BriefContactConfig.server.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
            if !query.isEmpty { parts.queryItems = query }
            var request = URLRequest(url: parts.url!)
            request.httpMethod = method
            request.timeoutInterval = 120
            request.setValue("Bearer " + (try token()), forHTTPHeaderField: "Authorization")
            if let body {
                request.httpBody = body
                request.setValue(contentType, forHTTPHeaderField: "Content-Type")
            }
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 && attempt == 0 && BriefContactConfig.devToken == nil {
                await AccountManager.shared.refreshSessionIfNeeded()
                continue
            }
            guard (200..<300).contains(status) else {
                let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
                throw BriefContactError.server(message ?? "The server answered \(status).")
            }
            return data
        }
        throw BriefContactError.server("The C4S sign-in has expired. Sign in again.")
    }
}

// MARK: - Price list

/// The photographer's price list, in the gallery's currency.
struct BriefContactPackage: Codable, Identifiable, Equatable {
    var id = UUID()
    var count: Int
    var price: Double
    var extra: Double
}

struct BriefContactPricing: Codable, Equatable {
    var perPhoto: Double = 10
    var packages: [BriefContactPackage] = [
        BriefContactPackage(count: 5, price: 40, extra: 7),
        BriefContactPackage(count: 10, price: 60, extra: 5),
    ]

    var json: [String: Any] {
        [
            "perPhoto": Self.cents(perPhoto),
            "packages": packages.map { ["count": $0.count, "price": Self.cents($0.price), "extra": Self.cents($0.extra)] },
        ]
    }

    static func cents(_ value: Double) -> Int { max(0, Int((value * 100).rounded())) }

    /// ⚠️ The same rule as `price()` in BriefContact's public/pricing.js — the
    /// server charges by that one; this only shows the photographer the
    /// table. Photo by photo until the first package; past a package every
    /// extra photo costs THAT package's extra price, never the starting one;
    /// and never more than the next package up.
    func total(for n: Int) -> (cents: Int, package: Int?) {
        guard n > 0 else { return (0, nil) }
        let packs = packages.sorted { $0.count < $1.count }
        var cents = n * Self.cents(perPhoto)
        var pack: Int?
        for p in packs where p.count <= n {
            cents = Self.cents(p.price) + (n - p.count) * Self.cents(p.extra)
            pack = p.count
        }
        if let next = packs.first(where: { $0.count > n }), Self.cents(next.price) <= cents {
            cents = Self.cents(next.price)
            pack = next.count
        }
        return (cents, pack)
    }
}

// MARK: - Look

/// How the gallery looks on the web — one field per control on the web page,
/// under the SAME ids, so the page can take them as they are. Defaults are
/// the client's own from the phone tests (23.09) and People only (25.09).
struct BriefContactLook: Codable, Equatable {
    var rowH = 300.0, gridW = 70.0
    var meshOn = true, peopleOnly = true, blurry = false
    var lines = 40.0, thick = 2.0, speed = 103.0, vertical = true
    var flicker = true, fspeed = 17.0
    var haloOn = true, halo = 6.0
    var flash = true, flashR = 115.0
    var guardOn = true, thresh = 0.75, corners = true, motion = true, pose = true
    var face = true, active = true, pinned = true

    var json: [String: Any] {
        [
            "rowH": rowH, "gridW": gridW, "meshOn": meshOn, "peopleOnly": peopleOnly,
            "lineBlack": !blurry, "lineBlurry": blurry,
            "lines": lines, "thick": thick, "speed": speed, "vertical": vertical,
            "flicker": flicker, "fspeed": fspeed, "haloOn": haloOn, "halo": halo,
            "flash": flash, "flashR": flashR,
            "guardOn": guardOn, "thresh": thresh, "corners": corners, "motion": motion, "pose": pose,
            "face": face, "active": active, "pinned": pinned, "showCam": false,
        ]
    }
}

// MARK: - New gallery

struct BriefContactPhoto: Identifiable {
    let id = UUID()
    let url: URL
    let thumbnail: NSImage?
    var name: String { url.lastPathComponent }
}

@MainActor
final class BriefContactGallery: ObservableObject {
    @Published var photos: [BriefContactPhoto] = []
    @Published var title = ""
    @Published var currency = UserDefaults.standard.string(forKey: "briefContact.currency") ?? "EUR" {
        didSet { UserDefaults.standard.set(currency, forKey: "briefContact.currency") }
    }
    @Published var delivery = UserDefaults.standard.string(forKey: "briefContact.delivery") ?? "download" {
        didSet { UserDefaults.standard.set(delivery, forKey: "briefContact.delivery") }
    }
    // The look and the price list are kept between galleries: a studio sets
    // them once and changes them only when it wants to.
    @Published var look: BriefContactLook = BriefContactGallery.load("briefContact.look") ?? BriefContactLook() {
        didSet { Self.save(look, "briefContact.look") }
    }
    @Published var pricing: BriefContactPricing = BriefContactGallery.load("briefContact.pricing") ?? BriefContactPricing() {
        didSet { Self.save(pricing, "briefContact.pricing") }
    }
    @Published var progress: (done: Int, total: Int)?
    /// The people in each photo, found by the preview page as soon as the
    /// photo is added: a PNG mask, or EMPTY data when nobody is in it. Sent
    /// up with the gallery, so the buyer's page draws the lines on the people
    /// from the first frame. (25.09: lines over the whole photo for the
    /// first seconds was a bug.)
    @Published var masks: [UUID: Data] = [:]
    @Published var phase: String?
    @Published var link: URL?
    @Published var error: String?

    private static func load<T: Decodable>(_ key: String) -> T? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }
    private static func save<T: Encodable>(_ value: T, _ key: String) {
        UserDefaults.standard.set(try? JSONEncoder().encode(value), forKey: key)
    }

    func addPhotos() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        panel.message = "Choose the client's photos"
        guard panel.runModal() == .OK else { return }
        let known = Set(photos.map(\.url))
        for url in panel.urls where !known.contains(url) {
            photos.append(BriefContactPhoto(url: url, thumbnail: Self.image(url, maxSide: 320).map {
                NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height))
            }))
        }
        link = nil
    }

    func remove(_ photo: BriefContactPhoto) { photos.removeAll { $0.id == photo.id } }
    func clear() { photos.removeAll(); masks.removeAll(); link = nil; error = nil }

    var masksDone: Int { photos.filter { masks[$0.id] != nil }.count }

    var isUploading: Bool { progress != nil }

    /// Creates the gallery, then uploads every photo twice: the PREVIEW the
    /// buyer sees (1600 px) and the ORIGINAL, released only after payment.
    /// The web gallery never holds the full photo.
    func createLink() async {
        guard !photos.isEmpty, !isUploading else { return }
        error = nil
        link = nil
        progress = (0, photos.count)
        defer { progress = nil; phase = nil }
        do {
            let body = try JSONSerialization.data(withJSONObject: [
                "title": title, "currency": currency, "delivery": delivery,
                "pricing": pricing.json, "settings": look.json,
            ] as [String: Any])
            let created = try JSONSerialization.jsonObject(with: try await BriefContactAPI.call("POST", "api/galleries", body: body)) as? [String: Any]
            guard let id = created?["id"] as? String, let linkText = created?["link"] as? String else {
                throw BriefContactError.server("The server did not return a link.")
            }
            // People only: every mask first. They are made in the background
            // from the moment the photos are added, so usually this is done.
            // If it stalls, the photos go up without — the buyer's page then
            // finds the people itself.
            if look.peopleOnly {
                var last = masksDone, stalled = Date()
                while masksDone < photos.count && Date().timeIntervalSince(stalled) < 90 {
                    phase = "Finding the people in the photos \(masksDone) / \(photos.count)"
                    try await Task.sleep(nanoseconds: 300_000_000)
                    if masksDone != last { last = masksDone; stalled = Date() }
                }
                phase = nil
            }
            for (index, photo) in photos.enumerated() {
                let accessed = photo.url.startAccessingSecurityScopedResource()
                defer { if accessed { photo.url.stopAccessingSecurityScopedResource() } }
                guard let preview = Self.jpeg(photo.url, maxSide: 1600, quality: 0.85) else {
                    throw BriefContactError.server("\(photo.name) could not be read.")
                }
                try await BriefContactAPI.call("PUT", "api/galleries/\(id)/photos/\(index + 1)", query: [
                    URLQueryItem(name: "kind", value: "preview"), URLQueryItem(name: "name", value: photo.name),
                    URLQueryItem(name: "w", value: String(preview.width)), URLQueryItem(name: "h", value: String(preview.height)),
                ], body: preview.data, contentType: "image/jpeg")
                if let mask = masks[photo.id] {
                    if mask.isEmpty {
                        try await BriefContactAPI.call("PUT", "api/galleries/\(id)/photos/\(index + 1)", query: [
                            URLQueryItem(name: "kind", value: "mask"), URLQueryItem(name: "none", value: "1")])
                    } else {
                        try await BriefContactAPI.call("PUT", "api/galleries/\(id)/photos/\(index + 1)",
                                                       query: [URLQueryItem(name: "kind", value: "mask")],
                                                       body: mask, contentType: "image/png")
                    }
                }
                let original = try Self.original(photo.url)
                try await BriefContactAPI.call("PUT", "api/galleries/\(id)/photos/\(index + 1)",
                                               query: [URLQueryItem(name: "kind", value: "original")],
                                               body: original.data, contentType: original.type)
                progress = (index + 1, photos.count)
            }
            link = URL(string: linkText)
        } catch {
            self.error = error.localizedDescription
        }
    }

    // A JPEG or PNG goes up as it is; anything else (RAW, HEIC, TIFF) as a
    // full-size JPEG at top quality.
    private static func original(_ url: URL) throws -> (data: Data, type: String) {
        let type = UTType(filenameExtension: url.pathExtension.lowercased())
        if type == .jpeg || type == .png, let data = try? Data(contentsOf: url) {
            return (data, type == .png ? "image/png" : "image/jpeg")
        }
        guard let jpeg = jpeg(url, maxSide: nil, quality: 0.95) else {
            throw BriefContactError.server("\(url.lastPathComponent) could not be read.")
        }
        return (jpeg.data, "image/jpeg")
    }

    /// The photo upright (orientation applied), no longer than `maxSide`.
    static func image(_ url: URL, maxSide: Int?) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        var options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        if let maxSide { options[kCGImageSourceThumbnailMaxPixelSize] = maxSide }
        else if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int {
            options[kCGImageSourceThumbnailMaxPixelSize] = max(w, h)
        }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func jpeg(_ url: URL, maxSide: Int?, quality: Double) -> (data: Data, width: Int, height: Int)? {
        guard let image = image(url, maxSide: maxSide) else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return (data as Data, image.width, image.height)
    }
}

// MARK: - Orders

struct BriefContactOrder: Decodable, Identifiable {
    struct Photo: Decodable { let n: Int; let name: String }
    let id: String
    let gallery_title: String
    let client_email: String
    let photos: [Photo]
    let count: Int
    let amount_cents: Int
    let currency: String
    let delivery: String
    let status: String
    let created_at: String
    let paid_at: String?
}

@MainActor
final class BriefContactOrders: ObservableObject {
    @Published var orders: [BriefContactOrder] = []
    @Published var showUnpaid = false
    @Published var loading = false
    @Published var error: String?

    var shown: [BriefContactOrder] { showUnpaid ? orders : orders.filter { $0.status == "paid" } }

    func refresh() async {
        loading = true
        error = nil
        defer { loading = false }
        do {
            struct List: Decodable { let orders: [BriefContactOrder] }
            orders = try JSONDecoder().decode(List.self, from: try await BriefContactAPI.call("GET", "api/orders")).orders
        } catch {
            self.error = error.localizedDescription
        }
    }
}

func briefContactMoney(_ cents: Int, _ currency: String) -> String {
    let f = NumberFormatter()
    f.numberStyle = .currency
    f.currencyCode = currency
    f.locale = Locale(identifier: "en_GB")
    return f.string(from: NSNumber(value: Double(cents) / 100)) ?? "\(cents / 100) \(currency)"
}

private func copyToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

// MARK: - Views

struct BriefContactView: View {
    @StateObject private var gallery = BriefContactGallery()
    @StateObject private var orders = BriefContactOrders()
    @ObservedObject private var account = AccountManager.shared
    // ⚠️ In the C4S theme's colours — 25.09: *„isto da briefcontact bude u
    // boji theme u c4s-u"*. Observed so a theme change repaints at once.
    @ObservedObject private var theme = ThemeManager.shared
    @State private var tab = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $tab) {
                    Text("New gallery").tag(0)
                    Text("Orders").tag(1)
                }
                .pickerStyle(.segmented)
                .frame(width: 260)
                Spacer()
                Text(BriefContactConfig.devToken != nil ? "Local test server"
                     : account.session.map { "Signed in as \($0.email)" } ?? "Not signed in")
                    .foregroundStyle(AppColors.inkSecondary)
            }
            .padding(12)
            .background(AppColors.panel)
            Rectangle().fill(AppColors.border).frame(height: 1)
            if tab == 0 { BriefContactNewGalleryView(gallery: gallery) }
            else { BriefContactOrdersView(orders: orders) }
        }
        .foregroundStyle(AppColors.ink)
        .background(AppColors.background)
        .id(theme.current)   // AppColors are read, not observed: rebuild on a theme change
    }
}

private struct BriefContactNewGalleryView: View {
    @ObservedObject var gallery: BriefContactGallery

    var body: some View {
        HSplitView {
            photosPane.frame(minWidth: 420)
            ScrollView { settingsPane.padding(16) }
                .frame(minWidth: 400, idealWidth: 460, maxWidth: 560)
                .background(AppColors.panel)
        }
    }

    private var photosPane: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Add Photos…") { gallery.addPhotos() }.disabled(gallery.isUploading)
                Button("Clear") { gallery.clear() }.disabled(gallery.photos.isEmpty || gallery.isUploading)
                Spacer()
                if gallery.masksDone < gallery.photos.count {
                    Text("finding people \(gallery.masksDone) / \(gallery.photos.count)").foregroundStyle(AppColors.inkSecondary)
                }
                Text("\(gallery.photos.count) photos").foregroundStyle(AppColors.inkSecondary)
            }
            .padding(12)
            // ⚠️ LIVE PREVIEW — 25.09: *„fotograf mora da ima live preview
            // kakav je flicker kakve linije blurr"*. The real web page, with
            // the first two photos, and every change on the right sent to it
            // at once: lines, flicker, blur, People only, the flashlight
            // under the mouse — exactly what the buyer will see.
            VStack(alignment: .leading, spacing: 4) {
                Text("Live preview — what the buyer sees. Move the mouse over it for the flashlight.")
                    .font(.caption).foregroundStyle(AppColors.inkSecondary)
                BriefContactPreview(gallery: gallery)
                    .frame(minHeight: 300, idealHeight: 380)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            Rectangle().fill(AppColors.border).frame(height: 1)
            if gallery.photos.isEmpty {
                Spacer()
                Text("Add the client's photos. They are uploaded when you create the link.")
                    .foregroundStyle(AppColors.inkSecondary)
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                        ForEach(Array(gallery.photos.enumerated()), id: \.element.id) { index, photo in
                            VStack(spacing: 4) {
                                ZStack(alignment: .topTrailing) {
                                    Group {
                                        if let t = photo.thumbnail { Image(nsImage: t).resizable().scaledToFit() }
                                        else { Rectangle().fill(.quaternary) }
                                    }
                                    .frame(height: 110)
                                    if !gallery.isUploading {
                                        Button { gallery.remove(photo) } label: { Image(systemName: "xmark.circle.fill") }
                                            .buttonStyle(.plain).padding(4)
                                    }
                                }
                                Text("\(index + 1). \(photo.name)").font(.caption).lineLimit(1).truncationMode(.middle)
                            }
                        }
                    }
                    .padding(12)
                }
            }
        }
    }

    private var settingsPane: some View {
        VStack(alignment: .leading, spacing: 18) {
            section("Client") {
                TextField("Client or gallery name", text: $gallery.title)
            }
            section("How the photos look on the web") { BriefContactLookEditor(look: $gallery.look) }
            section("Price list") { BriefContactPriceEditor(pricing: $gallery.pricing, currency: $gallery.currency) }
            section("After payment") {
                Picker("", selection: $gallery.delivery) {
                    Text("Download at once").tag("download")
                    Text("Link sent by email").tag("link")
                }
                .pickerStyle(.radioGroup)
                Text(gallery.delivery == "download"
                     ? "The buyer downloads the photos right after paying."
                     : "The buyer leaves an email; you see the order in Orders and send the link.")
                    .font(.caption).foregroundStyle(AppColors.inkSecondary)
            }
            createBox
        }
    }

    private var createBox: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                Task { await gallery.createLink() }
            } label: {
                Text("Create link").frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(gallery.photos.isEmpty || gallery.isUploading)
            if let phase = gallery.phase {
                ProgressView(value: Double(gallery.masksDone), total: Double(max(gallery.photos.count, 1))) { Text(phase) }
            } else if let p = gallery.progress {
                ProgressView(value: Double(p.done), total: Double(max(p.total, 1))) {
                    Text("Uploading \(p.done) / \(p.total)")
                }
            }
            if let error = gallery.error {
                Text(error).foregroundStyle(.red)
            }
            if let link = gallery.link {
                Text("Link for the client").font(.headline)
                Text(link.absoluteString).textSelection(.enabled).font(.system(.body, design: .monospaced))
                HStack {
                    Button("Copy link") { copyToPasteboard(link.absoluteString) }
                    Button("Open") { NSWorkspace.shared.open(link) }
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(AppColors.panelAlt))
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content()
        }
    }
}

private struct BriefContactLookEditor: View {
    @Binding var look: BriefContactLook

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            group("Lines") {
                Toggle("Lines on the photos", isOn: $look.meshOn)
                Toggle("Only over people (background clean)", isOn: $look.peopleOnly)
                Picker("Lines are", selection: $look.blurry) {
                    Text("Black").tag(false)
                    Text("Blurry").tag(true)
                }
                .pickerStyle(.segmented)
                slider("Lines", $look.lines, 2...40, 1, "%.0f")
                slider("Thickness", $look.thick, 2...80, 1, "%.0f px")
                slider("Speed", $look.speed, 0...600, 1, "%.0f px/s")
                Toggle("Vertical lines too", isOn: $look.vertical)
                Toggle("Blur around the lines", isOn: $look.haloOn)
                if look.haloOn { slider("Blur", $look.halo, 1...24, 1, "%.0f px") }
            }
            group("Flicker") {
                Toggle("Flicker", isOn: $look.flicker)
                if look.flicker { slider("Flicker speed", $look.fspeed, 0.5...30, 0.5, "%.1f /s") }
            }
            group("Flashlight") {
                Toggle("Flashlight (only a circle round the mouse is sharp)", isOn: $look.flash)
                if look.flash { slider("Light size", $look.flashR, 30...400, 1, "%.0f px") }
            }
            group("Layout") {
                slider("Size", $look.rowH, 80...700, 1, "%.0f px")
                slider("Width", $look.gridW, 30...100, 1, "%.0f %%")
                Toggle("Pinned under the camera", isOn: $look.pinned)
            }
            group("Camera guard") {
                Toggle("Phone guard", isOn: $look.guardOn)
                if look.guardOn { slider("Sensitivity", $look.thresh, 0.1...0.95, 0.05, "%.2f") }
                Toggle("Look in the corners", isOn: $look.corners)
                Toggle("Motion at the edges", isOn: $look.motion)
                Toggle("Arm raised", isOn: $look.pose)
                Toggle("Face needed", isOn: $look.face)
                Toggle("Mouse needed", isOn: $look.active)
            }
            Button("Back to the defaults") { look = BriefContactLook() }.controlSize(.small)
        }
    }

    private func group<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(AppColors.inkSecondary)
            content()
        }
    }

    private func slider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, _ step: Double, _ format: String) -> some View {
        HStack {
            Text(title).frame(width: 96, alignment: .leading)
            Slider(value: value, in: range, step: step)
            Text(String(format: format, value.wrappedValue)).monospacedDigit().frame(width: 70, alignment: .trailing)
        }
    }
}

private struct BriefContactPriceEditor: View {
    @Binding var pricing: BriefContactPricing
    @Binding var currency: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Currency", selection: $currency) {
                Text("EUR €").tag("EUR")
                Text("GBP £").tag("GBP")
                Text("USD $").tag("USD")
            }
            .pickerStyle(.segmented)
            HStack {
                Text("One photo")
                Spacer()
                money($pricing.perPhoto)
            }
            Text("Packages — past a package every extra photo costs that package's extra price.")
                .font(.caption).foregroundStyle(AppColors.inkSecondary)
            ForEach($pricing.packages) { $pack in
                HStack(spacing: 6) {
                    Stepper(value: $pack.count, in: 2...500) { Text("\(pack.count) photos") }
                        .frame(width: 120, alignment: .leading)
                    money($pack.price)
                    Text("then")
                    money($pack.extra)
                    Text("each")
                    Button { pricing.packages.removeAll { $0.id == pack.id } } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.plain)
                }
            }
            Button("Add package") {
                let last = pricing.packages.map(\.count).max() ?? 0
                pricing.packages.append(BriefContactPackage(count: max(last + 5, 2), price: 0, extra: pricing.perPhoto))
            }
            .controlSize(.small)
            table
        }
    }

    private func money(_ value: Binding<Double>) -> some View {
        TextField("", value: value, format: .number.precision(.fractionLength(0...2)))
            .frame(width: 64)
            .multilineTextAlignment(.trailing)
    }

    /// What a buyer pays for 1, 2, 3 … photos — so the list can be checked
    /// before a buyer ever sees it.
    private var table: some View {
        let top = max(12, (pricing.packages.map(\.count).max() ?? 0) + 3)
        return VStack(alignment: .leading, spacing: 2) {
            Text("What the buyer pays").font(.caption.weight(.semibold)).foregroundStyle(AppColors.inkSecondary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3), spacing: 2) {
                ForEach(1...top, id: \.self) { n in
                    let t = pricing.total(for: n)
                    Text("\(n) → \(briefContactMoney(t.cents, currency))" + (t.package.map { " (\($0))" } ?? ""))
                        .font(.caption.monospacedDigit())
                }
            }
        }
    }
}

private struct BriefContactOrdersView: View {
    @ObservedObject var orders: BriefContactOrders

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Refresh") { Task { await orders.refresh() } }.disabled(orders.loading)
                Toggle("Show unpaid", isOn: $orders.showUnpaid)
                if orders.loading { ProgressView().controlSize(.small) }
                Spacer()
                Text("\(orders.shown.count) orders").foregroundStyle(AppColors.inkSecondary)
            }
            .padding(12)
            if let error = orders.error { Text(error).foregroundStyle(.red).padding(.bottom, 8) }
            if orders.shown.isEmpty && !orders.loading {
                Spacer()
                Text("No orders yet.").foregroundStyle(AppColors.inkSecondary)
                Spacer()
            } else {
                List(orders.shown) { order in row(order).listRowBackground(AppColors.background) }
                    .scrollContentBackground(.hidden)
            }
        }
        .task { await orders.refresh() }
    }

    private func row(_ o: BriefContactOrder) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(o.gallery_title.isEmpty ? "Untitled gallery" : o.gallery_title).font(.headline)
                Text(o.status == "paid" ? "Paid" : "Not paid")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(o.status == "paid" ? Color.green.opacity(0.25) : Color.orange.opacity(0.25)))
                Spacer()
                Text(briefContactMoney(o.amount_cents, o.currency)).font(.headline.monospacedDigit())
            }
            HStack(spacing: 10) {
                Text(o.client_email).textSelection(.enabled)
                Button("Copy email") { copyToPasteboard(o.client_email) }.controlSize(.small)
                Text(o.delivery == "download" ? "Downloaded by the buyer" : "Send the link by email")
                    .font(.caption)
                    .foregroundStyle(o.delivery == "download" ? AppColors.inkSecondary : Color.orange)
                Spacer()
                Text(o.paid_at ?? o.created_at).font(.caption).foregroundStyle(AppColors.inkSecondary)
            }
            HStack(alignment: .top) {
                Text("\(o.count) photos: " + o.photos.map { "\($0.n). \($0.name)" }.joined(separator: ", "))
                    .font(.caption).textSelection(.enabled)
                Spacer()
                Button("Copy names") { copyToPasteboard(o.photos.map(\.name).joined(separator: "\n")) }.controlSize(.small)
            }
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Live preview

/// The BriefContact web page itself in `?preview` mode (no camera, no guard,
/// no controls), fed the first photos and the look from this window.
private struct BriefContactPreview: NSViewRepresentable {
    @ObservedObject var gallery: BriefContactGallery

    func makeCoordinator() -> Coordinator { Coordinator(gallery: gallery) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // What the page's models say ends up in the app's log ("BriefContact
        // preview: …"), since a preview in a window has no console to read.
        config.userContentController.add(context.coordinator, name: "bcLog")
        // The people masks it makes for this window come back here.
        config.userContentController.add(context.coordinator, name: "bcMask")
        let web = WKWebView(frame: .zero, configuration: config)
        if #available(macOS 13.3, *) { web.isInspectable = true }
        web.navigationDelegate = context.coordinator
        context.coordinator.web = web
        web.load(URLRequest(url: BriefContactConfig.server.appendingPathComponent("/").appending(queryItems: [URLQueryItem(name: "preview", value: "1")])))
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        context.coordinator.flush()
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        weak var web: WKWebView?
        private let gallery: BriefContactGallery
        private var loaded = false
        private var sentPhotos: String?
        private var sentLook: BriefContactLook?
        private var maskFor: UUID?   // the photo the page is finding people in now

        init(gallery: BriefContactGallery) { self.gallery = gallery }

        /// Only what changed goes over: the first two photos when they (or
        /// their masks) change, the look on every change, and the next photo
        /// still without a mask.
        func flush() {
            guard loaded, web != nil else { return }
            let shown = Array(gallery.photos.prefix(2))
            let key = shown.map { "\($0.id)\(gallery.masks[$0.id] == nil ? "?" : "!")" }.joined()
            if key != sentPhotos {
                sentPhotos = key
                call("bcPreview.photos", shown.compactMap { photo -> [String: Any]? in
                    guard let (url, aspect) = Self.dataURL(photo.url, maxSide: 1400) else { return nil }
                    var item: [String: Any] = ["url": url, "aspect": aspect]
                    if let mask = gallery.masks[photo.id] {
                        item["mask"] = mask.isEmpty ? "none" : "data:image/png;base64," + mask.base64EncodedString()
                    }
                    return item
                })
            }
            if gallery.look != sentLook {
                sentLook = gallery.look
                call("bcPreview.settings", gallery.look.json)
            }
            if maskFor == nil, let next = gallery.photos.first(where: { gallery.masks[$0.id] == nil }) {
                guard let (url, _) = Self.dataURL(next.url, maxSide: 1024) else {
                    // Unreadable: no mask. Set outside the view update this runs in.
                    DispatchQueue.main.async { [gallery] in gallery.masks[next.id] = Data() }
                    return
                }
                maskFor = next.id
                call("bcPreview.mask", ["id": next.id.uuidString, "url": url])
            }
        }

        private static func dataURL(_ url: URL, maxSide: Int) -> (String, Double)? {
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            guard let image = BriefContactGallery.image(url, maxSide: maxSide) else { return nil }
            let data = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
            guard CGImageDestinationFinalize(dest) else { return nil }
            return ("data:image/jpeg;base64," + (data as Data).base64EncodedString(),
                    Double(image.width) / Double(max(image.height, 1)))
        }

        private func call(_ function: String, _ argument: Any) {
            guard let data = try? JSONSerialization.data(withJSONObject: argument),
                  let json = String(data: data, encoding: .utf8) else { return }
            web?.evaluateJavaScript("\(function)(\(json))", completionHandler: nil)
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "bcMask" {
                guard let body = message.body as? [String: Any], let idText = body["id"] as? String,
                      let id = UUID(uuidString: idText) else { return }
                if maskFor == id { maskFor = nil }
                var mask = Data()
                if let png = body["png"] as? String, let comma = png.firstIndex(of: ",") {
                    mask = Data(base64Encoded: String(png[png.index(after: comma)...])) ?? Data()
                }
                gallery.masks[id] = mask
                flush()
                return
            }
            NSLog("BriefContact preview: %@", String(describing: message.body))
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loaded = webView.url?.query?.contains("preview") == true
            sentPhotos = nil
            sentLook = nil
            maskFor = nil
            flush()
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            loaded = false
            webView.loadHTMLString("""
                <body style="background:#1e1e20;color:#8a8a93;font:13px -apple-system;display:flex;align-items:center;justify-content:center;height:90vh">
                The preview needs the BriefContact server (\(BriefContactConfig.server.absoluteString)).</body>
                """, baseURL: nil)
        }
    }
}
