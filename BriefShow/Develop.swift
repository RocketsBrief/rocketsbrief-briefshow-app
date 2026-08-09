//
//  Develop.swift
//  BriefShow
//
//  "Develop" — a standalone, Lightroom-style non-destructive photo editor,
//  opened from ShowGrid's own "Develop" header button (see ContentView.swift).
//  Deliberately kept separate from PhotoShowSheet (ShowGrid's grid/loupe/
//  rating screen) and from the Kousei/Kirigami/Origami slideshow pipeline —
//  editing a photo here never touches the original file on disk and never
//  affects a slideshow export. It only writes a small per-photo settings
//  record (see PhotoEditStore) that this screen reads back on reopen, and
//  "Export Edited Copy" writes a brand-new file alongside the original.
//

import SwiftUI
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import UniformTypeIdentifiers

// MARK: - Edit model

// Every field here is a delta around 0 = "untouched" (never an absolute
// filter parameter), so a fresh PhotoEditSettings() is trivially "no edit
// at all" (see isNeutral) and each slider can be reset independently just
// by setting it back to 0.
struct PhotoEditSettings: Codable, Equatable {
    var exposure: Double = 0        // EV, roughly -3...3
    var contrast: Double = 0        // -1...1
    var highlights: Double = 0      // -1 (recover blown highlights) ...1
    var shadows: Double = 0         // -1 (darken) ...1 (lift)
    var saturation: Double = 0      // -1...1
    var vibrance: Double = 0        // -1...1
    var temperature: Double = 0     // -1 (cooler) ...1 (warmer)
    var tint: Double = 0            // -1 (green) ...1 (magenta)
    var sharpness: Double = 0       // 0...1
    var vignette: Double = 0        // 0...1
    var rotationQuarterTurns: Int = 0   // 0...3, applied in 90° steps
    var straightenDegrees: Double = 0   // -45...45, fine rotation
    var crop: EditCropRect?             // nil = uncropped

    var isNeutral: Bool {
        exposure == 0 && contrast == 0 && highlights == 0 && shadows == 0
            && saturation == 0 && vibrance == 0 && temperature == 0 && tint == 0
            && sharpness == 0 && vignette == 0 && rotationQuarterTurns == 0
            && straightenDegrees == 0 && crop == nil
    }
}

// A crop rectangle in the unit square (0...1 on each axis) of the image
// AFTER rotation/straighten — so it stays valid across preview resolutions,
// and applying rotation before crop in PhotoEditRenderer.render always
// lines it up with what the crop overlay showed on screen.
struct EditCropRect: Codable, Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    static let full = EditCropRect(x: 0, y: 0, width: 1, height: 1)
}

// MARK: - Persistence

// Mirrors PhotoLabelStore's name+size keying (see ContentView.swift) — an
// edit follows a photo through a move/rename inside BriefShow, but not
// through changes to the file's actual bytes made outside it.
enum PhotoEditStore {
    private static let defaultsKey = "com.rocketsbrief.briefshow.photoEditSettings"

    private static func key(for url: URL) -> String {
        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? -1
        return "\(url.lastPathComponent)|\(fileSize)"
    }

    static func settings(for url: URL) -> PhotoEditSettings {
        allSettings[key(for: url)] ?? PhotoEditSettings()
    }

    static func setSettings(_ settings: PhotoEditSettings, for url: URL) {
        var all = allSettings
        if settings.isNeutral {
            all.removeValue(forKey: key(for: url))
        } else {
            all[key(for: url)] = settings
        }
        allSettings = all
    }

    // Powers the small "has edits" badge on a filmstrip thumbnail.
    static func hasEdits(_ url: URL) -> Bool {
        allSettings[key(for: url)] != nil
    }

    private static var allSettings: [String: PhotoEditSettings] {
        get {
            guard let data = UserDefaults.standard.data(forKey: defaultsKey) else {
                return [:]
            }
            return (try? JSONDecoder().decode([String: PhotoEditSettings].self, from: data)) ?? [:]
        }
        set {
            UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: defaultsKey)
        }
    }
}

// MARK: - Render pipeline

enum PhotoEditRenderer {
    // RAW formats decode through CIRAWFilter instead of a plain CIImage
    // decode — a real demosaic with highlight-recovery headroom a JPEG/
    // HEIC preview embedded in the RAW file wouldn't have, rather than
    // just editing the camera's baked-in preview.
    private static let rawExtensions: Set<String> = [
        "cr2", "cr3", "nef", "arw", "dng", "raf", "orf", "rw2", "pef", "srw", "raw"
    ]

    static func isRAW(_ url: URL) -> Bool {
        rawExtensions.contains(url.pathExtension.lowercased())
    }

    // The full-resolution decode, with no edits applied yet — loaded once
    // per photo by DevelopView and reused both for the downsampled live
    // preview and the full-resolution export.
    static func loadBaseImage(from url: URL) -> CIImage? {
        if isRAW(url), let rawFilter = CIRAWFilter(imageURL: url) {
            // Full quality, not the fast/lossy draft decode — this is for
            // an actual edit session, not a filmstrip thumbnail.
            rawFilter.isDraftModeEnabled = false
            return rawFilter.outputImage
        }

        var options: [CIImageOption: Any] = [.applyOrientationProperty: true]
        if #available(macOS 14.0, *) {
            options[.expandToHDR] = false
        }
        return CIImage(contentsOf: url, options: options)
    }

    // Rotate/straighten, then adjust, then crop last — in that order so
    // the crop rect (defined in the post-rotation coordinate space, see
    // EditCropRect) always lines up with the image it was drawn against.
    // `applyCrop` is false while the crop tool itself is open, so the
    // overlay draws against the full, uncropped frame.
    static func render(_ settings: PhotoEditSettings, on image: CIImage, applyCrop: Bool = true) -> CIImage {
        var output = image

        if settings.rotationQuarterTurns != 0 {
            let turns = ((settings.rotationQuarterTurns % 4) + 4) % 4
            let angle = CGFloat(turns) * (.pi / 2)
            output = output.transformed(by: CGAffineTransform(rotationAngle: angle))
        }

        if settings.straightenDegrees != 0 {
            let radians = settings.straightenDegrees * .pi / 180
            output = output.transformed(by: CGAffineTransform(rotationAngle: -radians))
        }

        if settings.temperature != 0 || settings.tint != 0 {
            let filter = CIFilter.temperatureAndTint()
            filter.inputImage = output
            filter.neutral = CIVector(x: 6500 - settings.temperature * 3000, y: settings.tint * 100)
            filter.targetNeutral = CIVector(x: 6500, y: 0)
            output = filter.outputImage ?? output
        }

        if settings.exposure != 0 {
            let filter = CIFilter.exposureAdjust()
            filter.inputImage = output
            filter.ev = Float(settings.exposure)
            output = filter.outputImage ?? output
        }

        if settings.highlights != 0 || settings.shadows != 0 {
            let filter = CIFilter.highlightShadowAdjust()
            filter.inputImage = output
            filter.radius = 0
            filter.highlightAmount = Float(1 - settings.highlights)
            filter.shadowAmount = Float(settings.shadows)
            output = filter.outputImage ?? output
        }

        if settings.contrast != 0 || settings.saturation != 0 {
            let filter = CIFilter.colorControls()
            filter.inputImage = output
            filter.contrast = Float(1 + settings.contrast)
            filter.saturation = Float(1 + settings.saturation)
            filter.brightness = 0
            output = filter.outputImage ?? output
        }

        if settings.vibrance != 0 {
            let filter = CIFilter.vibrance()
            filter.inputImage = output
            filter.amount = Float(settings.vibrance)
            output = filter.outputImage ?? output
        }

        if settings.sharpness > 0 {
            let filter = CIFilter.sharpenLuminance()
            filter.inputImage = output
            filter.sharpness = Float(settings.sharpness * 2.2)
            output = filter.outputImage ?? output
        }

        if settings.vignette > 0 {
            let filter = CIFilter.vignette()
            filter.inputImage = output
            filter.radius = 1.6
            filter.intensity = Float(settings.vignette)
            output = filter.outputImage ?? output
        }

        if applyCrop, let crop = settings.crop {
            let extent = output.extent
            guard extent.width.isFinite, extent.height.isFinite, extent.width > 0, extent.height > 0 else {
                return output
            }
            let rect = CGRect(
                x: extent.origin.x + crop.x * extent.width,
                y: extent.origin.y + (1 - crop.y - crop.height) * extent.height,
                width: crop.width * extent.width,
                height: crop.height * extent.height
            ).integral
            output = output.cropped(to: rect)
        }

        return output
    }
}

private let briefEditsSRGBColorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

// One shared, Metal-backed context for both the live (downsampled) preview
// and the full-resolution export — CIContext is safe to reuse across many
// renders of different sizes.
private let briefEditsCIContext = CIContext(options: [
    .workingColorSpace: briefEditsSRGBColorSpace,
    .outputColorSpace: briefEditsSRGBColorSpace,
    .cacheIntermediates: false
])

// MARK: - Window lifecycle

// Mirrors ShowGridWindowController/BriefShowWindowController exactly — its
// own standalone, resizable window (not an overlay inside ShowGrid, which
// is sized to its own content and would clip a Lightroom-style layout).
// Same simplification those two make too: if a Develop window is already
// open, this just refocuses it rather than swapping in a new photo set —
// re-opening Develop while a session is already in progress there
// shouldn't interrupt it.
final class DevelopWindowController {
    static let shared = DevelopWindowController()

    private var windowController: NSWindowController?

    private init() {}

    func open(photoURLs: [URL], initialSelection: URL?) {
        if let controller = windowController {
            controller.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1500, height: 940),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Develop"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 980, height: 640)
        window.center()

        let controller = NSWindowController(window: window)
        windowController = controller

        window.contentView = NSHostingView(
            rootView: DevelopView(
                photoURLs: photoURLs,
                initialSelection: initialSelection,
                onClose: { [weak self] in
                    self?.close()
                }
            )
        )

        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        windowController?.close()
        windowController = nil
    }
}

// MARK: - Main view

struct DevelopView: View {
    let photoURLs: [URL]
    let initialSelection: URL?
    let onClose: () -> Void

    @ObservedObject private var themeManager = ThemeManager.shared

    @State private var selectedURL: URL?
    @State private var settings = PhotoEditSettings()
    @State private var fullBaseImage: CIImage?
    @State private var previewBaseImage: CIImage?
    @State private var displayedImage: NSImage?
    @State private var filmstripThumbnails: [URL: NSImage] = [:]
    @State private var isLoadingPreview = false
    @State private var showOriginal = false
    @State private var isCropping = false
    @State private var pendingCrop: EditCropRect = .full
    @State private var dragStartCrop: EditCropRect?
    @State private var exportStatusText: String?
    @State private var renderWorkItem: DispatchWorkItem?

    // Same soft-yellow-in-Dark, mid-gray-elsewhere accent PhotoShowSheet
    // uses for its own selection border, kept consistent here for the
    // filmstrip's selection ring and the "has edits" badge.
    private var accentColor: Color {
        themeManager.current == .dark
            ? Color(red: 1.0, green: 0.94, blue: 0.62)
            : Color(red: 0.56, green: 0.56, blue: 0.58)
    }

    var body: some View {
        HStack(spacing: 0) {
            filmstrip

            Divider()

            VStack(spacing: 0) {
                topBar

                Divider()

                centerPreview
            }
            .frame(maxWidth: .infinity)

            Divider()

            adjustmentPanel
        }
        .background(AppColors.background)
        .onAppear {
            if selectedURL == nil, let initial = initialSelection ?? photoURLs.first {
                selectPhoto(initial)
            }
        }
        .onChange(of: settings) { _ in scheduleRender() }
        .onChange(of: pendingCrop) { _ in
            if isCropping {
                scheduleRender()
            }
        }
        .onChange(of: showOriginal) { _ in renderNow() }
    }

    // MARK: Filmstrip

    private var filmstrip: some View {
        ScrollView {
            VStack(spacing: 8) {
                ForEach(photoURLs, id: \.self) { url in
                    filmstripThumbnail(for: url)
                }
            }
            .padding(10)
        }
        .frame(width: 120)
        .background(AppColors.panel)
    }

    private func filmstripThumbnail(for url: URL) -> some View {
        let isSelected = selectedURL == url
        let hasEdits = PhotoEditStore.hasEdits(url)

        return ZStack(alignment: .topTrailing) {
            Group {
                if let image = filmstripThumbnails[url] {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Rectangle().fill(AppColors.panelAlt)
                }
            }
            .frame(width: 100, height: 100)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isSelected ? accentColor : Color.clear, lineWidth: 2.5)
            )

            if hasEdits {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(.white)
                    .padding(4)
                    .background(Circle().fill(accentColor))
                    .padding(4)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            selectPhoto(url)
        }
        .onAppear {
            loadFilmstripThumbnail(for: url)
        }
    }

    private func loadFilmstripThumbnail(for url: URL) {
        guard filmstripThumbnails[url] == nil else {
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let image = makeShowGridThumbnail(from: url, maxPixelSize: 240)

            DispatchQueue.main.async {
                if let image {
                    filmstripThumbnails[url] = image
                }
            }
        }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 14) {
            if let selectedURL {
                Text(selectedURL.lastPathComponent)
                    .font(.custom("Figtree", size: 13).weight(.semibold))
                    .foregroundColor(AppColors.ink)
                    .lineLimit(1)

                if PhotoEditRenderer.isRAW(selectedURL) {
                    rawBadge
                }
            }

            Spacer()

            if let exportStatusText {
                Text(exportStatusText)
                    .font(.custom("Figtree", size: 12).weight(.medium))
                    .foregroundColor(AppColors.muted)
            }

            beforeAfterButton

            Button("Done") {
                onClose()
            }
            .buttonStyle(ShowHeaderButtonStyle())
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var rawBadge: some View {
        Text("RAW")
            .font(.custom("Figtree", size: 9).weight(.bold))
            .foregroundColor(AppColors.muted)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(AppColors.border, lineWidth: 1)
            )
    }

    // Press-and-hold (rather than a toggle) so comparing back to the
    // original is a quick glance, not an extra click to undo — the same
    // interaction Lightroom's own "\\" before/after key gives you, just on
    // a button since this has no keyboard shortcut plumbing yet.
    private var beforeAfterButton: some View {
        Text(showOriginal ? "Original" : "Before / After")
            .font(.custom("Figtree", size: 12).weight(.semibold))
            .foregroundColor(showOriginal ? AppColors.hoverInk : AppColors.ink)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(showOriginal ? AppColors.panelAlt : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(AppColors.border.opacity(0.6), lineWidth: 1)
            )
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in showOriginal = true }
                    .onEnded { _ in showOriginal = false }
            )
    }

    // MARK: Center preview + crop overlay

    private var centerPreview: some View {
        GeometryReader { proxy in
            ZStack {
                AppColors.panelAlt.opacity(0.4)

                if let displayedImage {
                    let fitted = fittedImageFrame(imageSize: displayedImage.size, in: proxy.size)

                    Image(nsImage: displayedImage)
                        .resizable()
                        .frame(width: fitted.width, height: fitted.height)
                        .position(x: proxy.size.width / 2, y: proxy.size.height / 2)

                    if isCropping {
                        cropOverlay(frame: fitted, containerSize: proxy.size)
                    }
                } else if isLoadingPreview {
                    ProgressView()
                } else {
                    Text("Select a photo from the filmstrip")
                        .font(.custom("Figtree", size: 13))
                        .foregroundColor(AppColors.muted)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .padding(24)
    }

    private func fittedImageFrame(imageSize: CGSize, in containerSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, containerSize.width > 0, containerSize.height > 0 else {
            return CGRect(origin: .zero, size: containerSize)
        }

        let scale = min(containerSize.width / imageSize.width, containerSize.height / imageSize.height)
        let width = imageSize.width * scale
        let height = imageSize.height * scale
        return CGRect(x: (containerSize.width - width) / 2, y: (containerSize.height - height) / 2, width: width, height: height)
    }

    private enum CropHandle: CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight
    }

    private func cropOverlay(frame: CGRect, containerSize: CGSize) -> some View {
        let rect = CGRect(
            x: frame.minX + pendingCrop.x * frame.width,
            y: frame.minY + pendingCrop.y * frame.height,
            width: pendingCrop.width * frame.width,
            height: pendingCrop.height * frame.height
        )

        return ZStack {
            // Even-odd fill of [full canvas, crop rect] darkens everything
            // outside the crop rect while leaving the rect itself clear.
            Path { path in
                path.addRect(CGRect(origin: .zero, size: containerSize))
                path.addRect(rect)
            }
            .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
            .allowsHitTesting(false)

            Rectangle()
                .stroke(Color.white, lineWidth: 1.5)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture()
                        .onChanged { value in moveCrop(by: value.translation, frame: frame) }
                        .onEnded { _ in dragStartCrop = nil }
                )

            ForEach(CropHandle.allCases, id: \.self) { handle in
                cropHandleView(handle, rect: rect, frame: frame)
            }
        }
    }

    private func cropHandleView(_ handle: CropHandle, rect: CGRect, frame: CGRect) -> some View {
        let position: CGPoint
        switch handle {
        case .topLeft: position = CGPoint(x: rect.minX, y: rect.minY)
        case .topRight: position = CGPoint(x: rect.maxX, y: rect.minY)
        case .bottomLeft: position = CGPoint(x: rect.minX, y: rect.maxY)
        case .bottomRight: position = CGPoint(x: rect.maxX, y: rect.maxY)
        }

        return Circle()
            .fill(Color.white)
            .frame(width: 12, height: 12)
            .shadow(radius: 1)
            .position(position)
            .gesture(
                DragGesture()
                    .onChanged { value in resizeCrop(handle, by: value.translation, frame: frame) }
                    .onEnded { _ in dragStartCrop = nil }
            )
    }

    private func moveCrop(by translation: CGSize, frame: CGRect) {
        if dragStartCrop == nil {
            dragStartCrop = pendingCrop
        }
        guard let start = dragStartCrop, frame.width > 0, frame.height > 0 else {
            return
        }

        let dx = translation.width / frame.width
        let dy = translation.height / frame.height

        var next = start
        next.x = min(max(0, start.x + dx), 1 - start.width)
        next.y = min(max(0, start.y + dy), 1 - start.height)
        pendingCrop = next
    }

    private func resizeCrop(_ handle: CropHandle, by translation: CGSize, frame: CGRect) {
        if dragStartCrop == nil {
            dragStartCrop = pendingCrop
        }
        guard let start = dragStartCrop, frame.width > 0, frame.height > 0 else {
            return
        }

        let dx = translation.width / frame.width
        let dy = translation.height / frame.height
        let minSize = 0.05

        var next = start
        switch handle {
        case .topLeft:
            next.x = max(0, min(start.x + dx, start.x + start.width - minSize))
            next.y = max(0, min(start.y + dy, start.y + start.height - minSize))
            next.width = start.x + start.width - next.x
            next.height = start.y + start.height - next.y
        case .topRight:
            next.y = max(0, min(start.y + dy, start.y + start.height - minSize))
            next.height = start.y + start.height - next.y
            next.width = max(minSize, min(start.width + dx, 1 - start.x))
        case .bottomLeft:
            next.x = max(0, min(start.x + dx, start.x + start.width - minSize))
            next.width = start.x + start.width - next.x
            next.height = max(minSize, min(start.height + dy, 1 - start.y))
        case .bottomRight:
            next.width = max(minSize, min(start.width + dx, 1 - start.x))
            next.height = max(minSize, min(start.height + dy, 1 - start.y))
        }
        pendingCrop = next
    }

    // MARK: Adjustment panel

    private var adjustmentPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                cropRotateSection

                Divider()

                lightSection

                Divider()

                colorSection

                Divider()

                detailSection

                Divider()

                resetButton
                exportButton
            }
            .padding(18)
        }
        .frame(width: 300)
        .background(AppColors.panel)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.custom("Figtree", size: 10).weight(.bold))
            .tracking(1)
            .foregroundColor(AppColors.muted.opacity(0.7))
    }

    private var cropRotateSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Crop & Rotate")

            HStack(spacing: 10) {
                Button {
                    rotateQuarterTurn(-1)
                } label: {
                    Image(systemName: "rotate.left")
                }
                .buttonStyle(EditToolButtonStyle())

                Button {
                    rotateQuarterTurn(1)
                } label: {
                    Image(systemName: "rotate.right")
                }
                .buttonStyle(EditToolButtonStyle())

                Button {
                    toggleCropMode()
                } label: {
                    Image(systemName: "crop")
                }
                .buttonStyle(EditToolButtonStyle(isActive: isCropping))

                Spacer()
            }

            editSlider("Straighten", value: $settings.straightenDegrees, range: -45...45) {
                String(format: "%+.1f°", $0)
            }

            if isCropping {
                HStack {
                    Button("Reset Crop") {
                        pendingCrop = .full
                    }
                    .buttonStyle(ShowHeaderButtonStyle())

                    Spacer()

                    Button("Done") {
                        commitCrop()
                    }
                    .buttonStyle(ShowHeaderButtonStyle())
                }
            }
        }
    }

    private var lightSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("Light")
            editSlider("Exposure", value: $settings.exposure, range: -3...3) { String(format: "%+.2f", $0) }
            editSlider("Contrast", value: $settings.contrast, range: -1...1)
            editSlider("Highlights", value: $settings.highlights, range: -1...1)
            editSlider("Shadows", value: $settings.shadows, range: -1...1)
        }
    }

    private var colorSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("Color")
            editSlider("Temperature", value: $settings.temperature, range: -1...1)
            editSlider("Tint", value: $settings.tint, range: -1...1)
            editSlider("Saturation", value: $settings.saturation, range: -1...1)
            editSlider("Vibrance", value: $settings.vibrance, range: -1...1)
        }
    }

    private var detailSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("Detail & Effects")
            editSlider("Sharpness", value: $settings.sharpness, range: 0...1) { String(format: "%.0f", $0 * 100) }
            editSlider("Vignette", value: $settings.vignette, range: 0...1) { String(format: "%.0f", $0 * 100) }
        }
    }

    private func editSlider(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        format: @escaping (Double) -> String = { String(format: "%+.0f", $0 * 100) }
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.custom("Figtree", size: 12).weight(.medium))
                    .foregroundColor(AppColors.ink)

                Spacer()

                Text(format(value.wrappedValue))
                    .font(.custom("Figtree", size: 11))
                    .foregroundColor(AppColors.muted)
                    .monospacedDigit()
            }

            Slider(value: value, in: range)
        }
    }

    private var resetButton: some View {
        Button("Reset All") {
            settings = PhotoEditSettings()
            pendingCrop = .full
        }
        .buttonStyle(ShowHeaderButtonStyle())
        .opacity(settings.isNeutral ? 0.4 : 1)
        .disabled(settings.isNeutral)
    }

    private var exportButton: some View {
        Button {
            exportEditedCopy()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "square.and.arrow.up")
                Text("Export Edited Copy")
            }
        }
        .buttonStyle(ShowHeaderButtonStyle())
        .opacity(fullBaseImage == nil ? 0.4 : 1)
        .disabled(fullBaseImage == nil)
    }

    // MARK: Actions

    private func selectPhoto(_ url: URL) {
        guard url != selectedURL else {
            return
        }

        selectedURL = url
        isCropping = false
        dragStartCrop = nil
        showOriginal = false
        settings = PhotoEditStore.settings(for: url)
        pendingCrop = settings.crop ?? .full
        loadImages(for: url)
    }

    private func rotateQuarterTurn(_ delta: Int) {
        settings.rotationQuarterTurns = ((settings.rotationQuarterTurns + delta) % 4 + 4) % 4
    }

    private func toggleCropMode() {
        if isCropping {
            commitCrop()
        } else {
            pendingCrop = settings.crop ?? .full
            isCropping = true
            scheduleRender()
        }
    }

    private func commitCrop() {
        settings.crop = (pendingCrop == .full) ? nil : pendingCrop
        isCropping = false
        scheduleRender()
    }

    private func loadImages(for url: URL) {
        isLoadingPreview = true
        fullBaseImage = nil
        previewBaseImage = nil
        displayedImage = nil

        DispatchQueue.global(qos: .userInitiated).async {
            guard let base = PhotoEditRenderer.loadBaseImage(from: url) else {
                DispatchQueue.main.async {
                    if url == selectedURL {
                        isLoadingPreview = false
                    }
                }
                return
            }

            let extent = base.extent
            let longEdge = max(extent.width, extent.height)
            let previewMax: CGFloat = 1600
            let scale = (longEdge.isFinite && longEdge > previewMax) ? previewMax / longEdge : 1
            let preview = scale < 1 ? base.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) : base

            DispatchQueue.main.async {
                // The client may have already clicked another filmstrip
                // thumbnail while this decode was still running.
                guard url == selectedURL else {
                    return
                }
                fullBaseImage = base
                previewBaseImage = preview
                isLoadingPreview = false
                renderNow()
            }
        }
    }

    // A short debounce so dragging a slider re-renders once it settles
    // rather than on every intermediate value.
    private func scheduleRender() {
        renderWorkItem?.cancel()
        let workItem = DispatchWorkItem { renderNow() }
        renderWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02, execute: workItem)
    }

    private func renderNow() {
        if let selectedURL {
            PhotoEditStore.setSettings(settings, for: selectedURL)
        }

        guard let previewBaseImage else {
            return
        }

        let effectiveSettings = showOriginal ? PhotoEditSettings() : settings
        let cropEnabled = !isCropping
        let source = previewBaseImage
        let photoAtRenderTime = selectedURL

        DispatchQueue.global(qos: .userInteractive).async {
            let rendered = PhotoEditRenderer.render(effectiveSettings, on: source, applyCrop: cropEnabled)
            guard let cgImage = briefEditsCIContext.createCGImage(rendered, from: rendered.extent) else {
                return
            }
            let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))

            DispatchQueue.main.async {
                guard selectedURL == photoAtRenderTime else {
                    return
                }
                displayedImage = image
            }
        }
    }

    private func exportEditedCopy() {
        guard let selectedURL, let fullBaseImage else {
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.jpeg]
        panel.nameFieldStringValue = selectedURL.deletingPathExtension().lastPathComponent + " Edited.jpg"
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let destinationURL = panel.url else {
            return
        }

        let settingsSnapshot = settings
        exportStatusText = "Exporting…"

        DispatchQueue.global(qos: .userInitiated).async {
            let rendered = PhotoEditRenderer.render(settingsSnapshot, on: fullBaseImage)
            var didWrite = false

            if let cgImage = briefEditsCIContext.createCGImage(rendered, from: rendered.extent) {
                let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
                if let data = bitmapRep.representation(using: .jpeg, properties: [.compressionFactor: 0.92]) {
                    didWrite = (try? data.write(to: destinationURL)) != nil
                }
            }

            DispatchQueue.main.async {
                exportStatusText = didWrite ? "Exported" : "Export Failed"
                let dismissWorkItem = DispatchWorkItem { exportStatusText = nil }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: dismissWorkItem)
            }
        }
    }
}

// MARK: - Small tool button style (rotate/crop icon buttons)

private struct EditToolButtonStyle: ButtonStyle {
    var isActive: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(isActive ? AppColors.hoverInk : AppColors.ink)
            .frame(width: 30, height: 30)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isActive ? AppColors.panelAlt : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(AppColors.border.opacity(0.6), lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
    }
}
