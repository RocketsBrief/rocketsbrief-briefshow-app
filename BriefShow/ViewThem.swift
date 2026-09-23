//  ViewThem.swift
//
//  A proofing view for showing photographs to buyers — and the test bench for
//  keeping them from simply photographing the screen.
//
//  Asked for on 23.09: *„da za ljudsko oko bude visible … ali kada upere kameru
//  prema slici da ta slika ne bude vidljiva lepo … vise linija idu od dole na
//  gore presecaju sliku ali ljudsko oko to da ne vidi jer te linije trepere …
//  svaka treperi pojedinacnom brzinom tako da uvek kada telefon hoce da uslika
//  slika je presecena"*. First in the app; if it works it moves to the web.
//
//  ⚠️ THE PRINCIPLE, and its limit. Every band is drawn LIGHTER on one display
//  frame and DARKER by the same amount on the next. The eye integrates over
//  far more than one frame and sees the average — the photograph. A phone
//  camera pointed at a bright screen exposes for a fraction of one frame and
//  keeps whichever half it caught, so the band is in its picture. This is the
//  idea behind the "Kaleido" research on screen-recording deterrence. It is
//  NOT a guarantee: a phone that merges several exposures (night mode, some
//  HDR) averages the bands away just as the eye does. That is what this bench
//  is for — every number is on a slider so a real phone can decide.
//
//  ⚠️ Screenshots of this window are refused by the system (`sharingType =
//  .none`), which is the part that CAN be forbidden outright.
import SwiftUI
import Combine
import AppKit
import ImageIO
import UniformTypeIdentifiers

final class ViewThemWindowController {
    static let shared = ViewThemWindowController()

    static let windowTitle = "ViewThem"

    private var windowController: NSWindowController?

    private init() {}

    func open() {
        if let controller = windowController, controller.window?.isVisible == true {
            NSApp.activate(ignoringOtherApps: true)
            controller.window?.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 820),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = Self.windowTitle
        window.isReleasedWhenClosed = false
        // Narrow enough to be useful, wide enough that the header row (title,
        // size slider, Add Photos, Clear) never has to squeeze its labels.
        window.minSize = NSSize(width: 760, height: 480)
        // Kept out of screenshots and screen recordings — the window shows as
        // blank in them. A camera pointed at the screen is what the bands are for.
        // `viewThem.allowCapture` lets a developer screenshot the bench to see
        // single frames; never set for a client.
        window.sharingType = UserDefaults.standard.bool(forKey: "viewThem.allowCapture")
            ? .readOnly : .none
        window.center()
        window.contentView = NSHostingView(rootView: ViewThemView())

        let controller = NSWindowController(window: window)
        windowController = controller

        // Activate BEFORE ordering front — see DevelopWindowController.
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }
}

// MARK: - The photos

final class ViewThemStore: ObservableObject {
    @Published private(set) var urls: [URL] = []
    @Published private(set) var thumbnails: [URL: NSImage] = [:]
    /// Width over height, read off the file's header before any pixel is
    /// decoded, so the rows are packed once and do not reflow as images arrive
    /// — the KORAK 211 lesson.
    @Published private(set) var aspects: [URL: CGFloat] = [:]

    private static let defaultsKey = "viewThem.photoPaths"
    private static let thumbnailSide: CGFloat = 1600
    private let queue = DispatchQueue(label: "viewThem.thumbnails", qos: .userInitiated,
                                      attributes: .concurrent)

    init() {
        let paths = UserDefaults.standard.stringArray(forKey: Self.defaultsKey) ?? []
        let existing = paths.map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        add(existing, persist: false)
    }

    func add(_ newURLs: [URL], persist: Bool = true) {
        let fresh = newURLs.filter { !urls.contains($0) }
        guard !fresh.isEmpty else { return }

        var shapes = aspects
        for url in fresh { shapes[url] = Self.aspect(of: url) ?? 1.5 }
        aspects = shapes
        urls.append(contentsOf: fresh)
        if persist { save() }

        for url in fresh {
            queue.async {
                let image = Self.thumbnail(of: url)
                DispatchQueue.main.async {
                    guard let image else { return }
                    self.thumbnails[url] = image
                    // The decoded picture is the authority — a header can
                    // leave out the orientation a RAW is shown in.
                    if image.size.height > 0 {
                        self.aspects[url] = image.size.width / image.size.height
                    }
                }
            }
        }
    }

    func clear() {
        urls = []
        thumbnails = [:]
        aspects = [:]
        save()
    }

    private func save() {
        UserDefaults.standard.set(urls.map(\.path), forKey: Self.defaultsKey)
    }

    private static func aspect(of url: URL) -> CGFloat? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? CGFloat,
              let h = props[kCGImagePropertyPixelHeight] as? CGFloat,
              w > 0, h > 0
        else { return nil }
        let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
        // 5–8 are the quarter turns: the stored width is the shown height.
        return (5...8).contains(orientation) ? h / w : w / h
    }

    private static func thumbnail(of url: URL) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailSide
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}

// MARK: - The bands

/// Everything about the bands that a phone test might want to change.
struct ViewThemBands {
    enum Rhythm: String, CaseIterable, Identifiable {
        /// Every band flips every frame, neighbours in opposite phase — the
        /// fastest flicker the display can show, so the hardest for the eye.
        case everyFrame = "Same rate"
        /// Each band flips at its own rate, 1–3 frames — what was asked for.
        /// Slower flips are easier for the eye to catch; that is the trade.
        case ownRate = "Own rate"

        var id: String { rawValue }
    }

    /// Every band is SOLID BLACK on every frame — the cut is visible to the eye
    /// as well as to a camera. Asked for on 23.09: *„tu gde je iseceno da bude
    /// crno skroz … black black"*. The first version flickered black against a
    /// brightened frame, and the eye averaged the black away. Off returns to
    /// the ±strength flicker, which is the one meant to be invisible.
    ///
    /// Always 100% black — Strength is hidden while this is on, since a
    /// translucent black read as a soft fade (23.09), and a slider that is
    /// shown but does nothing read as broken (also 23.09).
    var fullBlack = true
    /// Bands that run top to bottom as well, moving across — asked for in the
    /// same message: *„da budu i vertikalne linije ne samo horizontalne"*.
    var vertical = true
    /// With Full black: the black bands blink instead of standing still — on in
    /// one frame, gone in the next, at the rhythm the picker sets. Asked for on
    /// 23.09: *„daj mi opciju da treperi da mogu da je ukljucim i iskljucim"*.
    var flicker = true
    /// How many times a second the black bands come and go when Flicker is on.
    ///
    /// ⚠️ Flipping on every display frame (the first version) is 30 a second on
    /// this screen: the eye averages it to grey and the black is gone —
    /// reported 23.09: *„cim si sada dodao flicker izgubio sam crnu boju
    /// preseka!! mora taj presek da bude crna boja pa onda slika pa crna boja
    /// skroz … daj mi isto da izaberem flicker brzinu"*. Now it is a rate you
    /// set, black for half of each cycle and picture for the other half. With
    /// Own rate each band runs at 1×, 1.5× or 2× of it.
    var flickerSpeed: Double = 14
    var strength: Double = 1.0
    // The defaults the client settled on after the phone tests, 23.09:
    // *„lines: 20, flicker speed: 14, ticknes: 10, Speed: 95. I sve ukljuceno
    // full black, Vertical, i Flicker"*.
    var count: Double = 20
    var thickness: Double = 10
    var speed: Double = 95
    var rhythm: Rhythm = .everyFrame
}

/// Counts display frames. A reference type on purpose: it is advanced from
/// inside the timelines' bodies, and a class that nothing observes cannot start
/// the render-invalidate loop that froze the app in KORAK 212.
///
/// ⚠️ Every photo has its own timeline, and they all tick on the same display
/// frame with the SAME date — so a date already seen is the same frame, not a
/// new one. Without that, ten photos would advance the count ten times a frame
/// and the bright/dark halves would stop alternating.
private final class FrameCounter {
    var frame = 0
    var lastTick: Date?
    var fps: Double = 0

    func tick(_ date: Date) -> Int {
        if date == lastTick { return frame }
        frame &+= 1
        if let last = lastTick {
            let dt = date.timeIntervalSince(last)
            if dt > 0 { fps = fps * 0.95 + (1 / dt) * 0.05 }
        }
        lastTick = date
        return frame
    }
}

/// The bands, drawn over ONE photo only.
///
/// Asked for on 23.09: *„samo na sliku da se ovo desava ne kad udjem u view
/// them … samo na slici!"*. So each picture carries its own overlay, clipped to
/// it — but the bands are laid out in WINDOW coordinates and each overlay draws
/// only its slice of them, so a band crosses two neighbouring photos as one
/// line instead of every photo starting its own pattern at its edge.
private struct ViewThemBandsOverlay: View {
    let image: NSImage
    let bands: ViewThemBands
    let counter: FrameCounter

    /// The length one full set of bands repeats over, in points. `count` bands
    /// share it, so the slider means "how dense", whatever the window size.
    static let period: CGFloat = 900

    var body: some View {
        GeometryReader { proxy in
            let origin = proxy.frame(in: .global).origin
            TimelineView(.animation) { timeline in
                let frame = counter.tick(timeline.date)
                let time = timeline.date.timeIntervalSinceReferenceDate
                let lit = rects(size: proxy.size, origin: origin, time: time) { isBright($0 + ($1 ? 1 : 0), frame) }
                let dark = rects(size: proxy.size, origin: origin, time: time) { !isBright($0 + ($1 ? 1 : 0), frame) }
                let s = min(max(bands.strength, 0), 1)
                if bands.fullBlack {
                    // ⚠️ SOLID BLACK ON EVERY FRAME — no bright half at all.
                    // The flickering pair averaged the black away, so to the
                    // eye the cut was never black; reported 23.09: *„full
                    // black nije full black!! … treba mi celo odsecanje! da
                    // bude black black!"*. The bands are now plainly visible
                    // and still moving; Strength is how black (1 = black).
                    Canvas { context, _ in
                        let shown = bands.flicker
                            ? rects(size: proxy.size, origin: origin, time: time) { index, vertical in
                                // ⚠️ The two directions in OPPOSITE phase:
                                // when the horizontals are black the verticals
                                // are gone, and the other way round. Reported
                                // 23.09 that a phone caught the black about
                                // half the time — *„sansa manje vise 50-50"* —
                                // because with every band in phase half of each
                                // cycle had no black anywhere. Now one set is
                                // black at every instant, at whatever speed.
                                isBlack(index, time, vertical: vertical)
                            }
                            : lit + dark
                        fill(&context, shown, .black)
                    }
                    // ⚠️ NO opacity, and no animation may reach it. Full black
                    // is black: reported 23.09 that the cut came and went
                    // *„smooth … vidi se crna li sa opacity"* — Strength below
                    // 1 was making it a translucent grey. A band is either
                    // fully black this frame or not drawn at all.
                    .transaction { $0.animation = nil }
                } else {
                    ZStack {
                        // plusLighter ADDS the colour; plusDarker adds it and
                        // subtracts one, so a grey of (1 − s) takes s away.
                        Canvas { context, _ in fill(&context, lit, Color(white: s)) }
                            .blendMode(.plusLighter)
                        Canvas { context, _ in fill(&context, dark, Color(white: 1 - s)) }
                            .blendMode(.plusDarker)
                    }
                }
            }
        }
        .clipped()
        .allowsHitTesting(false)
    }

    private func fill(_ context: inout GraphicsContext, _ rects: [CGRect], _ colour: Color) {
        for rect in rects { context.fill(Path(rect), with: .color(colour)) }
    }

    /// Every band in its `bright` (or dark) half this frame, in this photo's
    /// own coordinates.
    /// Whether band `i` is in its bright half this display frame — the ±
    /// flicker, which swaps every frame so the eye averages it away.
    private func isBright(_ i: Int, _ frame: Int) -> Bool {
        let rate: Int
        switch bands.rhythm {
        case .everyFrame: rate = 1
        case .ownRate: rate = 1 + (i * 7) % 3
        }
        return ((frame / rate) + i) % 2 == 0
    }

    /// Whether band `i` is black right now under Flicker: black for the first
    /// half of each cycle, picture for the second. Same rate blinks the whole
    /// mesh together; Own rate gives every band its own speed.
    private func isBlack(_ i: Int, _ time: Double, vertical: Bool) -> Bool {
        var hz = max(bands.flickerSpeed, 0.1)
        if bands.rhythm == .ownRate { hz *= [1, 1.5, 2][(i * 7) % 3] }
        // Where in its cycle this band is, 0..<1. The verticals run half a
        // cycle behind the horizontals — opposite phase.
        let cycle = time * hz + (vertical ? 0.5 : 0)
        let phase = cycle - floor(cycle)
        // Black for half the cycle PLUS the overlap, so the set coming in is
        // already black before the set going out lets go.
        return phase < 0.5 + Self.overlap
    }

    /// How long both directions are black together at each hand-over, as a
    /// share of one cycle.
    ///
    /// ⚠️ Asked for on 23.09: *„dodaj taj preklop da nikad nema trenutka bez
    /// crne"*. With the two sets meeting exactly, a phone that fired on the
    /// hand-over — or exposed across it — caught both half-gone, as a
    /// translucent grey. Now the incoming set is fully black a tenth of a cycle
    /// before the outgoing one disappears, so there is no instant with no
    /// black on the picture.
    static let overlap = 0.1

    private func rects(size: CGSize, origin: CGPoint, time: Double,
                       include: (_ index: Int, _ vertical: Bool) -> Bool) -> [CGRect] {
        let n = max(Int(bands.count), 1)
        let period = Self.period
        let spacing = period / CGFloat(n)
        let thickness = CGFloat(bands.thickness)
        let travel = CGFloat((time * bands.speed).truncatingRemainder(dividingBy: Double(period)))

        /// Window positions of every band along one axis that reach into the
        /// span [start, start + length], as positions within the span.
        func positions(start: CGFloat, length: CGFloat, direction: CGFloat,
                       vertical: Bool) -> [(Int, CGFloat)] {
            let low = start - thickness, high = start + length + thickness
            let first = Int(floor(low / period)) - 1, last = Int(floor(high / period)) + 1
            var out: [(Int, CGFloat)] = []
            for i in 0..<n where include(i, vertical) {
                let base = CGFloat(i) * spacing + spacing / 2 + direction * travel
                for k in first...last {
                    let p = base + CGFloat(k) * period
                    if p > low, p < high { out.append((i, p - start)) }
                }
            }
            return out
        }

        var result: [CGRect] = []
        // Horizontal bands, moving up.
        for (_, y) in positions(start: origin.y, length: size.height, direction: -1, vertical: false) {
            result.append(CGRect(x: 0, y: y - thickness / 2, width: size.width, height: thickness))
        }
        // Vertical bands, moving right, half a cycle out of step with the
        // horizontal ones so a crossing is not always the same phase.
        if bands.vertical {
            for (_, x) in positions(start: origin.x, length: size.width, direction: 1, vertical: true) {
                result.append(CGRect(x: x - thickness / 2, y: 0, width: thickness, height: size.height))
            }
        }
        return result
    }
}

// MARK: - The view

struct ViewThemView: View {
    @StateObject private var store = ViewThemStore()
    @State private var rowHeight: Double = 260
    @State private var bands = ViewThemBands()
    @State private var counter = FrameCounter()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(AppColors.border)
            ZStack {
                AppColors.background
                if store.urls.isEmpty {
                    emptyState
                } else {
                    grid
                }
            }
        }
        .background(AppColors.background)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Text("ViewThem")
                    .font(.custom("Figtree", size: 18).weight(.bold))
                    .foregroundColor(AppColors.ink)

                Text("\(store.urls.count) photos")
                    .font(.custom("Figtree", size: 12))
                    .foregroundColor(AppColors.muted)

                Spacer()

                HStack(spacing: 8) {
                    Image(systemName: "photo").font(.system(size: 10))
                    Slider(value: $rowHeight, in: 80...700).frame(width: 150)
                    Image(systemName: "photo.fill").font(.system(size: 15))
                }
                .foregroundColor(AppColors.muted)

                Button { addPhotos() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus")
                        Text("Add Photos")
                    }
                }
                .buttonStyle(ShowHeaderButtonStyle())

                Button { store.clear() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "xmark.circle")
                        Text("Clear")
                    }
                }
                .buttonStyle(ShowHeaderButtonStyle())
                .opacity(store.urls.isEmpty ? 0.4 : 1)
                .disabled(store.urls.isEmpty)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                bandControls
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(AppColors.panel)
    }

    /// The bench, in TWO rows — asked for on 23.09: *„stavi settings u gornjoj
    /// liniji u dva dela … moze u dva reda"*. What the bands ARE on the first,
    /// how they are drawn on the second.
    private var bandControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                HStack(spacing: 12) {
                    Picker("", selection: $bands.rhythm) {
                        ForEach(ViewThemBands.Rhythm.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 190)
                    .labelsHidden()

                    Toggle("Full black", isOn: $bands.fullBlack)
                        .toggleStyle(.switch)
                        .controlSize(.small)

                    Toggle("Vertical", isOn: $bands.vertical)
                        .toggleStyle(.switch)
                        .controlSize(.small)

                    Toggle("Flicker", isOn: $bands.flicker)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .disabled(!bands.fullBlack)

                    benchSlider("Flicker speed", $bands.flickerSpeed, 0.5...30, "%.1f /s")
                        .disabled(!bands.fullBlack || !bands.flicker)
                }

                TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                    Text(String(format: "%.0f fps", counter.fps))
                        .font(.custom("Figtree", size: 11).monospacedDigit())
                        .foregroundColor(AppColors.muted)
                        .fixedSize()
                }
            }

            HStack(spacing: 12) {
                // Only for the soft ± flicker — Full black is always 100%.
                if !bands.fullBlack {
                    benchSlider("Strength", $bands.strength, 0.02...1, "%.2f")
                }
                benchSlider("Lines", $bands.count, 2...40, "%.0f")
                benchSlider("Thickness", $bands.thickness, 2...80, "%.0f pt")
                benchSlider("Speed", $bands.speed, 0...600, "%.0f pt/s")
            }
        }
        .font(.custom("Figtree", size: 11))
        .foregroundColor(AppColors.inkSecondary)
        // ⚠️ Every label stays on one line. In a narrow window the row used
        // to squeeze "Strength" into a column of single letters — reported
        // 23.09. Now the rows keep their size and scroll sideways instead.
        .fixedSize()
        .padding(.vertical, 2)
    }

    private func benchSlider(_ title: String, _ value: Binding<Double>,
                             _ range: ClosedRange<Double>, _ format: String) -> some View {
        HStack(spacing: 6) {
            Text(title).lineLimit(1)
            Slider(value: value, in: range).frame(width: 70).controlSize(.small)
            Text(String(format: format, value.wrappedValue))
                .monospacedDigit()
                .frame(width: 50, alignment: .leading)
                .foregroundColor(AppColors.muted)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "eye")
                .font(.system(size: 34))
                .foregroundColor(AppColors.muted)
            Text("Add the photos your buyers should see.")
                .font(.custom("Figtree", size: 14))
                .foregroundColor(AppColors.inkSecondary)
            Button { addPhotos() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                    Text("Add Photos")
                }
            }
            .buttonStyle(ShowHeaderButtonStyle())
        }
    }

    /// Justified rows with NO gap: every row is scaled so its pictures fill the
    /// width exactly, and every picture is shown whole — never cropped. The
    /// slider sets the height a row aims for; the last row keeps that height
    /// rather than being stretched across the window.
    private var grid: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(rows(for: width).enumerated()), id: \.offset) { _, row in
                        HStack(spacing: 0) {
                            ForEach(row.urls, id: \.self) { url in
                                cell(url, height: row.height)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
        }
    }

    private func cell(_ url: URL, height: CGFloat) -> some View {
        let aspect = store.aspects[url] ?? 1.5
        return Group {
            if let image = store.thumbnails[url] {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .overlay {
                        ViewThemBandsOverlay(image: image, bands: bands, counter: counter)
                    }
            } else {
                AppColors.panelAlt
            }
        }
        .frame(width: aspect * height, height: height)
    }

    private struct Row {
        var urls: [URL]
        var height: CGFloat
    }

    private func rows(for width: CGFloat) -> [Row] {
        guard width > 0 else { return [] }
        let target = CGFloat(rowHeight)
        var result: [Row] = []
        var current: [URL] = []
        var aspectSum: CGFloat = 0

        for url in store.urls {
            let aspect = store.aspects[url] ?? 1.5
            current.append(url)
            aspectSum += aspect
            if aspectSum * target >= width {
                result.append(Row(urls: current, height: width / aspectSum))
                current = []
                aspectSum = 0
            }
        }
        if !current.isEmpty {
            result.append(Row(urls: current, height: min(target, width / aspectSum)))
        }
        return result
    }

    private func addPhotos() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.resolvesAliases = true
        guard panel.runModal() == .OK else { return }
        store.add(panel.urls)
    }
}
