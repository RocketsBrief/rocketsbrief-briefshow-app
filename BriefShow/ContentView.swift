import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Combine
import AVFoundation
import AVKit
import ImageIO
import CoreImage
import CoreGraphics
import QuartzCore

enum SlideshowTimingMode: String {
    case followMusic = "Follow Music"
    case customSpeed = "Custom Speed"
}

// How the live "Preview" card renders the slideshow. The two "live" modes
// drive the same real-time SwiftUI animation timer at a different tick rate;
// the two "rendered" modes instead pre-render the slideshow to an actual
// video file once (at 1080p or 4K) and play that back, which is perfectly
// smooth on weak hardware since it's just video playback rather than
// real-time compositing.
enum PreviewRenderMode: String {
    case liveFPS30
    case liveFPS60
    case renderedVideo
    case renderedVideo4K

    var isRenderedVideo: Bool {
        self == .renderedVideo || self == .renderedVideo4K
    }

    var videoResolutionName: String {
        self == .renderedVideo4K ? "4K" : "1080p"
    }
}

enum SlideshowTransitionStyle: String {
    case fade = "Fade"
    case blink = "Blink"
}

enum SlideshowVisualTheme: String {
    case singleFade = "Single Fade"
    case singleBlink = "Single Blink"
    case magazine = "Kousei"
    case magazine43 = "Kousei 4:3"
    case magazineFamily = "Magazine Family"
    case magazineCouples = "Magazine Couples"
    case origami = "Kirigami"
    case origami43 = "Kirigami 4:3"
    case imagination = "Kanata"
}

// A per-photo manual crop override for Kousei-family pages. `focusX`/`focusY`
// pin the point of the image (0...1, CSS object-position style) that stays
// centered in whatever slot the photo lands in; `zoom` (>=1) crops in tighter
// beyond the default cover-fill. Defaults reproduce the previous fixed
// "headroom preserving" auto-crop so untouched photos render unchanged.
struct MagazinePhotoCrop: Equatable {
    var focusX: Double = 0.5
    var focusY: Double = 0.15
    var zoom: Double = 1

    static let `default` = MagazinePhotoCrop()
}

private func magazineCropRenderSize(
    imageSize: CGSize,
    frameSize: CGSize,
    zoom: CGFloat
) -> CGSize {
    guard imageSize.width > 0, imageSize.height > 0,
          frameSize.width > 0, frameSize.height > 0
    else {
        return frameSize
    }

    let coverScale = max(
        frameSize.width / imageSize.width,
        frameSize.height / imageSize.height
    )

    let safeZoom = max(1, zoom)

    return CGSize(
        width: imageSize.width * coverScale * safeZoom,
        height: imageSize.height * coverScale * safeZoom
    )
}

// Returns the SwiftUI-convention offset (y increases downward) to apply to an
// aspect-filled, `zoom`-scaled image so that `crop`'s focus point stays
// visible. Callers drawing with a Core Graphics context (y increases upward)
// should negate the height component.
private func magazineCropOffset(
    imageSize: CGSize,
    frameSize: CGSize,
    crop: MagazinePhotoCrop
) -> CGSize {
    let renderedSize = magazineCropRenderSize(
        imageSize: imageSize,
        frameSize: frameSize,
        zoom: CGFloat(crop.zoom)
    )

    let overflowX = renderedSize.width - frameSize.width
    let overflowY = renderedSize.height - frameSize.height
    let focusX = min(1, max(0, crop.focusX))
    let focusY = min(1, max(0, crop.focusY))

    return CGSize(
        width: overflowX * (0.5 - focusX),
        height: overflowY * (0.5 - focusY)
    )
}

// Mirrors OrigamiPreviewPage's own photo classification thresholds (kept as
// a separate pure function rather than refactoring that view, so existing
// Kirigami layout selection is never at risk of changing). Kirigami's
// layouts are built specifically to match each photo's own shape to a
// same-shaped slot, so a photo's own aspect class is a good stand-in for
// whatever slot it will actually land in, without simulating the full
// multi-photo page layout.
private enum PhotoAspectClass {
    case ultraPortrait
    case portrait
    case square
    case landscape
    case wide
    case ultraWide
}

private func photoAspectClass(for ratio: CGFloat) -> PhotoAspectClass {
    switch ratio {
    case ..<0.72:
        return .ultraPortrait
    case ..<0.90:
        return .portrait
    case ..<1.15:
        return .square
    case ..<1.70:
        return .landscape
    case ..<2.30:
        return .wide
    default:
        return .ultraWide
    }
}

private func representativeAspectRatio(for photoClass: PhotoAspectClass) -> CGFloat {
    switch photoClass {
    case .ultraPortrait:
        return 0.65
    case .portrait:
        return 0.8
    case .square:
        return 1
    case .landscape:
        return 1.4
    case .wide:
        return 2
    case .ultraWide:
        return 2.6
    }
}

// Fraction of the image's area that stays visible when it's cover-fit into
// a `targetAspectRatio` frame at zoom 1 (no manual crop). Used to flag
// photos that need cropping attention before the client has looked at them.
private func magazineCropVisibleAreaFraction(
    imageAspectRatio: CGFloat,
    targetAspectRatio: CGFloat
) -> Double {
    guard imageAspectRatio > 0, targetAspectRatio > 0 else {
        return 1
    }

    return Double(
        min(imageAspectRatio, targetAspectRatio)
        / max(imageAspectRatio, targetAspectRatio)
    )
}

// A deterministic (non-animated) reconstruction of one Kirigami page's
// settled state: which photos are the page's own base-slot photos, and
// which later photos get folded into an existing slot as swap-in
// replacements — and into which slot. Mirrors ContentView's
// plannedOrigamiSlotCount / plannedOrigamiReplacementCount /
// origamiReplacementTargetSlots exactly, but as pure functions so the crop
// editor can reproduce the same result without a live playback session.
// Without this, the editor showed every photo in its own freshly-chosen
// slot, while live playback force-fits swap-in photos into a slot sized
// for a different photo — so a crop set in the editor didn't match what
// actually played.
struct OrigamiPagePlan {
    let baseRange: Range<Int>
    let consumedRange: Range<Int>
    let slotByReplacementIndex: [Int: Int]
}

private func origamiPlanAspectRatio(_ image: NSImage) -> Double {
    guard image.size.height > 0 else {
        return 1
    }

    return Double(image.size.width / image.size.height)
}

private func origamiPlanOrientationClass(_ image: NSImage) -> Int {
    let ratio = origamiPlanAspectRatio(image)

    if ratio > 1.15 {
        return 1
    }

    if ratio < 0.85 {
        return -1
    }

    return 0
}

private func origamiPlanSlotCount(pageIndex: Int, remainingPhotos: Int, isStrict43: Bool = false) -> Int {
    guard remainingPhotos > 0 else {
        return 0
    }

    let cycle = isStrict43 ? [2, 3, 2, 3, 4] : [3, 5, 6, 2, 4]
    let safePageIndex = max(0, pageIndex)

    var plannedCount = min(
        cycle[safePageIndex % cycle.count],
        remainingPhotos
    )

    if remainingPhotos - plannedCount == 1, plannedCount > 2 {
        plannedCount -= 1
    }

    return max(1, min(isStrict43 ? 4 : 6, plannedCount))
}

private func origamiPlanReplacementCount(
    baseSlotCount: Int,
    remainingPhotos: Int,
    imagesBeforePageChange: Int
) -> Int {
    let requestedReplacementCount = max(0, min(6, imagesBeforePageChange))

    var replacementCount = min(
        requestedReplacementCount,
        baseSlotCount,
        max(0, remainingPhotos - baseSlotCount)
    )

    if remainingPhotos - baseSlotCount - replacementCount == 1,
       replacementCount > 0 {
        replacementCount -= 1
    }

    return replacementCount
}

private func origamiPlanReplacementTargetSlots(
    for incomingImages: [NSImage],
    baseImages: [NSImage],
    runningReplacements: inout [Int: NSImage]
) -> [Int] {
    guard !baseImages.isEmpty else {
        return []
    }

    var availableSlots = Array(0..<baseImages.count)
    var targets: [Int] = []

    for incomingImage in incomingImages {
        guard !availableSlots.isEmpty else {
            break
        }

        let incomingRatio = origamiPlanAspectRatio(incomingImage)
        let incomingOrientation = origamiPlanOrientationClass(incomingImage)

        let target = availableSlots.min { leftSlot, rightSlot in
            func score(for slot: Int) -> Double {
                guard baseImages.indices.contains(slot) else {
                    return 100
                }

                let currentImage = runningReplacements[slot] ?? baseImages[slot]
                let currentRatio = origamiPlanAspectRatio(currentImage)
                let currentOrientation = origamiPlanOrientationClass(currentImage)
                let orientationPenalty = incomingOrientation == currentOrientation ? 0 : 8
                let ratioPenalty = abs(
                    log(max(0.05, incomingRatio) / max(0.05, currentRatio))
                )

                return Double(orientationPenalty) + ratioPenalty
            }

            return score(for: leftSlot) < score(for: rightSlot)
        }!

        targets.append(target)
        availableSlots.removeAll { $0 == target }
        runningReplacements[target] = incomingImage
    }

    return targets
}

private func buildOrigamiPagePlans(
    previewImages: [NSImage],
    imagesBeforePageChange: Int,
    isStrict43: Bool = false
) -> [OrigamiPagePlan] {
    var plans: [OrigamiPagePlan] = []
    var consumed = 0
    var pageIndex = 0
    let total = previewImages.count

    while consumed < total {
        let remaining = total - consumed

        let baseSlotCount = origamiPlanSlotCount(
            pageIndex: pageIndex,
            remainingPhotos: remaining,
            isStrict43: isStrict43
        )

        let baseEnd = min(total, consumed + baseSlotCount)

        guard baseEnd > consumed else {
            break
        }

        let baseRange = consumed..<baseEnd
        let baseImages = Array(previewImages[baseRange])

        let replacementCount = origamiPlanReplacementCount(
            baseSlotCount: baseImages.count,
            remainingPhotos: remaining,
            imagesBeforePageChange: imagesBeforePageChange
        )

        let replacementEnd = min(total, baseEnd + replacementCount)
        let incomingImages = Array(previewImages[baseEnd..<replacementEnd])

        var runningReplacements: [Int: NSImage] = [:]
        let targetSlots = origamiPlanReplacementTargetSlots(
            for: incomingImages,
            baseImages: baseImages,
            runningReplacements: &runningReplacements
        )

        var slotByReplacementIndex: [Int: Int] = [:]

        for (offset, slot) in targetSlots.enumerated() {
            slotByReplacementIndex[baseEnd + offset] = slot
        }

        plans.append(
            OrigamiPagePlan(
                baseRange: baseRange,
                consumedRange: consumed..<replacementEnd,
                slotByReplacementIndex: slotByReplacementIndex
            )
        )

        consumed = replacementEnd
        pageIndex += 1
    }

    return plans
}

struct ContentView: View {
    // Photos handed off from the Welcome screen's BriefShow square, if
    // that's how this window was reached — imported automatically on
    // first appear, same as picking them by hand.
    let initialPhotoURLs: [URL]

    init(initialPhotoURLs: [URL] = []) {
        self.initialPhotoURLs = initialPhotoURLs
    }

    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var accountManager = AccountManager.shared
    @ObservedObject private var remoteStatus = AppRemoteStatus.shared
    @State private var isProfileModalPresented = false
    @State private var selectedPhotoURLs: [URL] = []
    @State private var previewImages: [NSImage] = []
    @State private var isPreparingPhotos: Bool = false
    @State private var preparedPhotoCount: Int = 0
    @State private var selectedMusicURLs: [URL] = []
    @State private var currentMusicIndex: Int = 0
    @State private var currentMusicElapsedSeconds: Double = 0
    @State private var pendingMusicSlotIndex: Int?
    @State private var audioPlayer: AVAudioPlayer?

    private var selectedMusicURL: URL? {
        selectedMusicURLs.first
    }

    private var activeMusicURL: URL? {
        guard !selectedMusicURLs.isEmpty else {
            return nil
        }

        if selectedMusicURLs.indices.contains(currentMusicIndex) {
            return selectedMusicURLs[currentMusicIndex]
        }

        return selectedMusicURLs.first
    }

    private var selectedMusicTrackCount: Int {
        selectedMusicURLs.count
    }
    @State private var timingMode: SlideshowTimingMode = .customSpeed
    @State private var secondsPerPhoto: Double = 5
    @State private var fadeDuration: Double = 1
    @State private var magazineImageFadeSeconds: Double = 0.6
    @State private var magazineImageDelaySeconds: Double = 0.4
    @State private var musicFadeInSeconds: Double = 4
    @State private var musicFadeOutSeconds: Double = 4
    @State private var shouldLoopPreview: Bool = false
    @State private var transitionStyle: SlideshowTransitionStyle = .fade
    @State private var visualTheme: SlideshowVisualTheme = .singleFade
    @State private var selectedExportResolution: String = "4K"
    @State private var selectedExportFormat: String = "MP4"
    @State private var isExportingVideo: Bool = false
    @State private var exportStatusText: String?
    @State private var exportProgress: Double = 0
    @State private var activePhotoIndex: Int = 0
    @State private var previousPhotoIndex: Int?
    @State private var transitionProgress: Double = 1
    @State private var magazineRevealElapsedSeconds: Double = 0
    // Cached copy of the per-photo-set layout seed used by
    // plannedMagazineSlotCount, recomputed only when selectedPhotoURLs
    // actually changes instead of re-hashing every filename on every
    // 60fps preview tick.
    @State private var magazinePhotoSeed: Int = 0
    @State private var magazinePageIndex: Int = 0
    @State private var origamiPageIndex: Int = 0
    @State private var photoCropTransforms: [URL: MagazinePhotoCrop] = [:]
    @State private var manualMagazineLayoutOverrides: [Int: Int] = [:]
    @State private var manualOrigamiLayoutOverrides: [Int: Int] = [:]
    @State private var isCropEditorPresented: Bool = false

    // The Origami page remains fixed while individual
    // image slots are replaced one at a time.
    @State private var origamiSlotReplacementImages: [Int: NSImage] = [:]
    @State private var origamiCompletedSwapCount: Int = 0
    // Multiple Origami slots can fold together.
    @State private var origamiActiveSwapImages: [Int: NSImage] = [:]
    @State private var origamiActiveSwapStyles: [Int: Int] = [:]
    @State private var origamiSwapProgress: Double = 1
    @State private var isOrigamiSwapAnimating: Bool = false
    @State private var isOrigamiWholePageFoldAnimating: Bool = false
    @State private var origamiUsedReplacementSlots: Set<Int> = []

    // Previous complete Origami page used only during
    // the transition to the next page.
    // These values will be exposed in Slideshow Settings.
    @State private var origamiImagesBeforePageChange: Int = 2
    @State private var origamiInternalHoldSeconds: Double = 3.5
    @State private var origamiSimultaneousSwapCount: Int = 1

    // Live previous page used during the whole-page fold.
    // This avoids raster resizing, zoom and blink.
    @State private var previousOrigamiPageImages: [NSImage] = []
    @State private var previousOrigamiPageReplacements: [Int: NSImage] = [:]
    @State private var previousOrigamiPageAnimationVariant: Int = 0
    @State private var origamiWholePageFoldProgress: Double = 1

    @State private var isPreviewPlaying: Bool = false

    // Koristi se samo kada Imagination mora eksplicitno
    // ponovo da krene preko Play From Beginning.
    @State private var imaginationPlaybackRestartToken: Int = 0

    // Sprečava preklapanje dva Imagination page transitiona.
    // Motion fotografije i dust ostaju aktivni dok traje overlay.
    @State private var isImaginationPageTransitionAnimating: Bool = false

    // Uvodni/završni crni overlay (3s na početku, 4s na kraju),
    // nezavisan od overlaya koji se koristi između stranica.
    // Reveal animacija kreće normalno odmah, ispod ovog overlaya.
    @State private var imaginationIntroOutroOpacity: Double = 0

    // Sprečava da se outro sekvenca pokrene više puta dok traje.
    @State private var isImaginationOutroAnimating: Bool = false

    @State private var previewElapsedSeconds: Double = 0
    @State private var previewTotalElapsedSeconds: Double = 0
    @State private var isFullScreenPreviewPresented: Bool = false

    // Preview rendering mode (30fps live / 60fps live / pre-rendered 1080p
    // video) plus the pre-rendered-video bookkeeping: the tick counter lets
    // the single 60Hz timer skip every other tick for 30fps mode instead of
    // needing a second Timer publisher; the signature is a cheap fingerprint
    // of everything that affects the rendered output, used to detect when a
    // previously prepared preview video has gone stale and needs re-rendering.
    @State private var previewRenderMode: PreviewRenderMode = .liveFPS60
    @State private var previewTickCounter: Int = 0
    @State private var previewTickLastTimestamp: CFTimeInterval?
    @State private var previewVideoPlayer: AVPlayer?
    @State private var preparedPreviewVideoURL: URL?
    @State private var preparedPreviewVideoSignature: String?
    @State private var isPreparingPreviewVideo: Bool = false
    @State private var previewVideoPrepareProgress: Double = 0
    @State private var previewVideoPrepareError: String?
    @State private var savedWindowFrame: NSRect?
    @State private var savedPresentationOptions: NSApplication.PresentationOptions = []
    @State private var savedTitlebarAppearsTransparent: Bool = false
    @State private var savedTitleVisibility: NSWindow.TitleVisibility = .visible
    @State private var savedWindowStyleMask: NSWindow.StyleMask = []
    @State private var savedWindowLevel: NSWindow.Level = .normal
    @State private var savedCollectionBehavior: NSWindow.CollectionBehavior = []

    var body: some View {
        ZStack {
            AppColors.background
                .ignoresSafeArea()

            VStack(spacing: 10) {
                HeaderView(isProfileModalPresented: $isProfileModalPresented, onOpenShowScreen: {
                    // Closes this Slideshow editor window entirely and
                    // returns to the original Browse window (registered
                    // via WindowAccessor) instead of opening a second,
                    // duplicate one — going through the singleton's own
                    // close() also clears its stored window reference, so
                    // a later "Slideshow" click correctly opens a fresh
                    // editor instead of trying to refocus this closed one.
                    ShowGridWindowController.shared.open(initialPhotoURLs: selectedPhotoURLs)
                    BriefShowWindowController.shared.close()
                })

                HStack(alignment: .top, spacing: 14) {
                    LeftImportPanel(
                        timingMode: $timingMode,
                        secondsPerPhoto: $secondsPerPhoto,
                        fadeDuration: $fadeDuration,
                        magazineImageFadeSeconds: $magazineImageFadeSeconds,
                        magazineImageDelaySeconds: $magazineImageDelaySeconds,
                        origamiImagesBeforePageChange: $origamiImagesBeforePageChange,
                        origamiInternalHoldSeconds: $origamiInternalHoldSeconds,
                        musicFadeInSeconds: $musicFadeInSeconds,
                        musicFadeOutSeconds: $musicFadeOutSeconds,
                        shouldLoopPreview: $shouldLoopPreview,
                        transitionStyle: $transitionStyle,
                        visualTheme: $visualTheme,
                        hasPhotos: !selectedPhotoURLs.isEmpty,
                        onOpenCropEditor: {
                            isCropEditorPresented = true
                        }
                    )
                    CenterPreviewPanel(
                        activePreviewImage: activePreviewImage,
                        previousPreviewImage: previousPreviewImage,
                        activePhotoName: activePhotoName,
                        activePhotoIndex: activePhotoIndex,
                        photoCount: selectedPhotoURLs.count,
                        previewImages: previewImages,
                        origamiSlotReplacementImages: origamiSlotReplacementImages,
                        origamiActiveSwapImages: origamiActiveSwapImages,
                        origamiActiveSwapStyles: origamiActiveSwapStyles,
                        origamiSwapProgress: origamiSwapProgress,
                        previousOrigamiPageImages: previousOrigamiPageImages,
                        previousOrigamiPageReplacements: previousOrigamiPageReplacements,
                        previousOrigamiPageAnimationVariant: previousOrigamiPageAnimationVariant,
                        origamiWholePageFoldProgress: origamiWholePageFoldProgress,
                        origamiBlackOverlayOpacity: origamiBlackOverlayOpacity,
                        magazineBlackOverlayOpacity: magazineBlackOverlayOpacity,
                        visualTheme: visualTheme,
                        isPreparingPhotos: isPreparingPhotos,
                        preparedPhotoCount: preparedPhotoCount,
                        selectedMusicURL: selectedMusicURL,
                        selectedMusicURLs: selectedMusicURLs,
                        selectedMusicCount: selectedMusicTrackCount,
                        timeCounterText: timeCounterText,
                        transitionStyle: transitionStyle,
                        transitionProgress: usesMagazineTheme ? magazineRevealProgress : transitionProgress,
                        magazineImageFadeSeconds: magazineImageFadeSeconds,
                        magazineImageDelaySeconds: magazineImageDelaySeconds,
                        magazineLayoutSeed: magazinePageIndex,
                        photoCropByImageIdentity: photoCropByImageIdentity,
                        magazinePageSlotCount: currentPreviewPageSlotCount,
                        origamiAnimationSeed: origamiPageIndex,
                        manualMagazineLayoutOverrides: manualMagazineLayoutOverrides,
                        manualOrigamiLayoutOverrides: manualOrigamiLayoutOverrides,
                        isPreviewPlaying: isPreviewPlaying,
                        imaginationPlaybackRestartToken:
                            imaginationPlaybackRestartToken,
                        imaginationIntroOutroOpacity:
                            imaginationIntroOutroOpacity,
                        onAddPhotos: openPhotoPicker,
                        onAddMusic: { slotIndex in
                            openMusicPicker(for: slotIndex)
                        },
                        onDropPhotos: importPhotoURLs,
                        onDropMusic: { urls in
                            importMusicURLs(urls)
                        },
                        onTogglePreview: togglePreview,
                        onStartFromBeginning: startPreviewFromBeginning,
                        onOpenFullScreen: {
                            openCinemaFullScreenPreview()
                        },
                        previewRenderMode: previewRenderMode,
                        previewVideoPlayer: previewVideoPlayer,
                        isPreparingPreviewVideo: isPreparingPreviewVideo,
                        previewVideoPrepareProgress: previewVideoPrepareProgress,
                        previewVideoPrepareError: previewVideoPrepareError,
                        onSelectPreviewRenderMode: { mode in
                            selectPreviewRenderMode(mode)
                        }
                    )
                    RightExportPanel(
                        selectedResolution: $selectedExportResolution,
                        selectedFormat: $selectedExportFormat,
                        selectedMusicURL: selectedMusicURL,
                        selectedMusicCount: selectedMusicTrackCount,
                        canExport: !selectedPhotoURLs.isEmpty && !isPreparingPhotos,
                        isExporting: isExportingVideo,
                        exportProgress: exportProgress,
                        exportStatusText: exportStatusText,
                        onExportVideo: openExportSavePanel
                    )
                }

                TimelinePanel(
                    photoURLs: $selectedPhotoURLs,
                    previewImages: $previewImages,
                    musicURL: selectedMusicURL,
                    musicCount: selectedMusicTrackCount,
                    isPreparingPhotos: isPreparingPhotos,
                    onDropPhotos: importPhotoURLs,
                    onDropMusic: { urls in
                            importMusicURLs(urls)
                        },
                    onClearImages: clearImages,
                    activePhotoIndex: $activePhotoIndex
                )

                HStack {
                    Spacer()

                    Text("© 2026 RocketsBrief. All rights reserved.")
                        .font(.custom("Figtree", size: 10.5).weight(.regular))
                        .foregroundColor(AppColors.muted.opacity(0.62))
                        .lineLimit(1)

                    Spacer()
                }
                .padding(.top, -2)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .top)
            .overlayPreferenceValue(PreviewTooltipPreferenceKey.self) { items in
                // Reads the same preference key CenterPreviewPanel's buttons report into,
                // but attached at the window root so the bubble always paints above every
                // other view (header, panels) instead of being subject to VStack's
                // undefined paint order for siblings that overlap outside their own bounds.
                GeometryReader { proxy in
                    ForEach(items) { item in
                        let rect = proxy[item.anchor]
                        HoverTooltipBubble(
                            label: item.label,
                            textColor: AppColors.ink,
                            arrowEdge: item.placement == .above ? .bottom : .top
                        )
                        // Anchored by the arrow-tip edge (not the bubble's center) via a
                        // zero-height frame, so bubbles of different text length (e.g. the
                        // short 30/60fps labels vs. the longer 1080p one) all line up at the
                        // same distance from their button instead of drifting with height.
                        .frame(height: 0, alignment: item.placement == .above ? .bottom : .top)
                        .position(
                            x: rect.midX,
                            y: item.placement == .above ? rect.minY - 6 : rect.maxY + 6
                        )
                    }
                }
                .allowsHitTesting(false)
            }

            if isFullScreenPreviewPresented {
                FullScreenPreviewSheet(
                    activePreviewImage: activePreviewImage,
                    previousPreviewImage: previousPreviewImage,
                    activePhotoName: activePhotoName,
                    activePhotoIndex: activePhotoIndex,
                    photoCount: selectedPhotoURLs.count,
                    isPreparingPhotos: isPreparingPhotos,
                    previewImages: previewImages,
                    origamiSlotReplacementImages: origamiSlotReplacementImages,
                    origamiActiveSwapImages: origamiActiveSwapImages,
                    origamiActiveSwapStyles: origamiActiveSwapStyles,
                    origamiSwapProgress: origamiSwapProgress,
                    previousOrigamiPageImages: previousOrigamiPageImages,
                    previousOrigamiPageReplacements: previousOrigamiPageReplacements,
                    previousOrigamiPageAnimationVariant: previousOrigamiPageAnimationVariant,
                    origamiWholePageFoldProgress: origamiWholePageFoldProgress,
                    origamiBlackOverlayOpacity: origamiBlackOverlayOpacity,
                    magazineBlackOverlayOpacity: magazineBlackOverlayOpacity,
                    visualTheme: visualTheme,
                    timeCounterText: timeCounterText,
                    transitionStyle: transitionStyle,
                    transitionProgress: usesMagazineTheme ? magazineRevealProgress : transitionProgress,
                    magazineImageFadeSeconds: magazineImageFadeSeconds,
                    magazineImageDelaySeconds: magazineImageDelaySeconds,
                    magazineLayoutSeed: magazinePageIndex,
                    photoCropByImageIdentity: photoCropByImageIdentity,
                    magazinePageSlotCount: currentPreviewPageSlotCount,
                    origamiAnimationSeed: origamiPageIndex,
                    manualMagazineLayoutOverrides: manualMagazineLayoutOverrides,
                    manualOrigamiLayoutOverrides: manualOrigamiLayoutOverrides,
                    isPreviewPlaying: isPreviewPlaying,
                    imaginationPlaybackRestartToken:
                        imaginationPlaybackRestartToken,
                    imaginationIntroOutroOpacity:
                        imaginationIntroOutroOpacity,
                    previewProgress: totalPreviewDuration > 0 ? min(1, previewTotalElapsedSeconds / totalPreviewDuration) : 0,
                    onTogglePreview: togglePreview,
                    onStartFromBeginning: startPreviewFromBeginning,
                    onSeek: { fraction in
                        seekPreview(toFraction: fraction)
                    },
                    onClose: {
                        closeCinemaFullScreenPreview()
                    },
                    previewRenderMode: previewRenderMode,
                    previewVideoPlayer: previewVideoPlayer
                )
                .ignoresSafeArea()
                .zIndex(9999)
                .transition(.opacity)
            }

            if isCropEditorPresented {
                MagazineCropEditorSheet(
                    photoURLs: selectedPhotoURLs,
                    previewImages: previewImages,
                    visualTheme: visualTheme,
                    pageRanges:
                        usesOrigamiTheme
                        ? origamiReviewPagePlans.map { $0.consumedRange }
                        : magazineReviewPageRanges,
                    origamiPagePlans:
                        usesOrigamiTheme
                        ? origamiReviewPagePlans
                        : [],
                    cropTransforms: $photoCropTransforms,
                    manualMagazineLayoutOverrides: $manualMagazineLayoutOverrides,
                    manualOrigamiLayoutOverrides: $manualOrigamiLayoutOverrides,
                    onClose: {
                        isCropEditorPresented = false
                    }
                )
                .ignoresSafeArea()
                .zIndex(15000)
                .transition(.opacity)
            }

            if remoteStatus.isUpdateAvailable {
                UpdateRequiredOverlay(
                    latestVersion: remoteStatus.config?.latestVersion ?? remoteStatus.currentVersion,
                    downloadURL: remoteStatus.config?.downloadUrl,
                    releaseNotes: remoteStatus.config?.releaseNotes
                )
                .ignoresSafeArea()
                .zIndex(20000)
                .transition(.opacity)
            } else if remoteStatus.isLocked && !accountManager.isSignedIn {
                LockedAccessOverlay(lockMessage: remoteStatus.config?.lockMessage)
                    .ignoresSafeArea()
                    .zIndex(19000)
                    .transition(.opacity)
            } else if isProfileModalPresented {
                ProfileSettingsModal(onClose: {
                    isProfileModalPresented = false
                })
                .ignoresSafeArea()
                .zIndex(18000)
                .transition(.opacity)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(
            minWidth: 980,
            idealWidth: 1180,
            maxWidth: .infinity,
            alignment: .top
        )
        // Our custom themes only recolor our own SwiftUI views — native
        // AppKit controls (like the Stepper below) still render using
        // whatever system light/dark appearance macOS reports, which is
        // why the Stepper's chevrons stayed near-black (a light-appearance
        // control) on our custom Dark theme's near-black background. This
        // tells SwiftUI which appearance to hand those native controls.
        .preferredColorScheme(themeManager.current == .dark ? .dark : .light)
        .onAppear {
            if selectedPhotoURLs.isEmpty, !initialPhotoURLs.isEmpty {
                importPhotoURLs(initialPhotoURLs)
            }
        }
        .onChange(of: selectedPhotoURLs) { newValue in
            updateMagazinePhotoSeed(for: newValue)
        }
        .onReceive(Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()) { _ in
            switch previewRenderMode {
            case .renderedVideo, .renderedVideo4K:
                // Playback is driven by previewVideoPlayer (AVPlayer) itself,
                // not by this tick-based animation state.
                previewTickLastTimestamp = nil
            case .liveFPS60:
                advancePreviewIfNeeded(delta: measuredPreviewTickDelta())
            case .liveFPS30:
                previewTickCounter += 1
                guard previewTickCounter % 2 == 0 else {
                    break
                }
                advancePreviewIfNeeded(delta: measuredPreviewTickDelta())
            }
        }
        .onReceive(Timer.publish(every: 600, on: .main, in: .common).autoconnect()) { _ in
            Task { await DeviceCheckIn.checkIn() }
        }
        .task {
            await remoteStatus.refresh()
            await ExportCounter.flushAll()
            await DeviceCheckIn.checkIn()
        }
    }

    private func openCinemaFullScreenPreview() {
        guard !selectedPhotoURLs.isEmpty, !isPreparingPhotos else {
            return
        }

        savedPresentationOptions = NSApp.presentationOptions

        if let window = NSApp.keyWindow ?? NSApp.windows.first, let screen = window.screen ?? NSScreen.main {
            savedWindowFrame = window.frame
            savedTitlebarAppearsTransparent = window.titlebarAppearsTransparent
            savedTitleVisibility = window.titleVisibility
            savedWindowStyleMask = window.styleMask
            savedWindowLevel = window.level
            savedCollectionBehavior = window.collectionBehavior

            NSApp.activate(ignoringOtherApps: true)

            window.level = .screenSaver
            window.collectionBehavior.insert(.canJoinAllSpaces)
            window.collectionBehavior.insert(.fullScreenAuxiliary)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
            window.styleMask.remove(.resizable)
            window.standardWindowButton(.closeButton)?.isHidden = true
            window.standardWindowButton(.miniaturizeButton)?.isHidden = true
            window.standardWindowButton(.zoomButton)?.isHidden = true
            window.makeKeyAndOrderFront(nil)

            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                window.animator().setFrame(screen.frame, display: true)
            }
        }

        NSApp.presentationOptions.insert(.hideDock)
        NSApp.presentationOptions.insert(.hideMenuBar)

        withAnimation(.easeInOut(duration: 0.16)) {
            isFullScreenPreviewPresented = true
        }
    }

    private func closeCinemaFullScreenPreview() {
        guard isFullScreenPreviewPresented || savedWindowFrame != nil else {
            return
        }

        if isPreviewPlaying {
            isPreviewPlaying = false
            audioPlayer?.pause()
        }

        isFullScreenPreviewPresented = false
        NSApp.presentationOptions = savedPresentationOptions

        let frameToRestore = savedWindowFrame
        let levelToRestore = savedWindowLevel
        let behaviorToRestore = savedCollectionBehavior
        let styleMaskToRestore = savedWindowStyleMask
        let titlebarToRestore = savedTitlebarAppearsTransparent
        let titleVisibilityToRestore = savedTitleVisibility

        savedWindowFrame = nil

        DispatchQueue.main.async {
            guard let window = NSApp.keyWindow ?? NSApp.windows.first else {
                return
            }

            window.level = levelToRestore
            window.collectionBehavior = behaviorToRestore
            window.styleMask = styleMaskToRestore
            window.titlebarAppearsTransparent = titlebarToRestore
            window.titleVisibility = titleVisibilityToRestore
            window.standardWindowButton(.closeButton)?.isHidden = false
            window.standardWindowButton(.miniaturizeButton)?.isHidden = false
            window.standardWindowButton(.zoomButton)?.isHidden = false

            if let frameToRestore {
                window.setFrame(frameToRestore, display: true, animate: true)
            }

            window.makeKeyAndOrderFront(nil)
        }
    }

    private var usesMagazineTheme: Bool {
        visualTheme == .magazine || visualTheme == .magazine43 || visualTheme == .magazineFamily || visualTheme == .magazineCouples
    }

    private var usesOrigamiTheme: Bool {
        visualTheme == .origami || visualTheme == .origami43
    }

    private var usesPagedTheme: Bool {
        usesMagazineTheme || usesOrigamiTheme
    }

    // Lets Kousei preview tiles look up a manual crop for the exact NSImage
    // instance they were handed, without threading photo URLs through the
    // whole preview view hierarchy (previewImages/selectedPhotoURLs already
    // share NSImage instances everywhere they're sliced or passed down).
    private var photoCropByImageIdentity: [ObjectIdentifier: MagazinePhotoCrop] {
        guard !photoCropTransforms.isEmpty else {
            return [:]
        }

        var result: [ObjectIdentifier: MagazinePhotoCrop] = [:]

        for (index, url) in selectedPhotoURLs.enumerated()
        where previewImages.indices.contains(index) {
            if let crop = photoCropTransforms[url] {
                result[ObjectIdentifier(previewImages[index])] = crop
            }
        }

        return result
    }

    // Groups previewImages into the same page sizes Kousei actually uses,
    // so the Crop editor can show real page layouts to review before going
    // to full preview. Uses the same slot-count decision the live preview
    // uses, so the grouping matches what will actually be shown.
    private var magazineReviewPageRanges: [Range<Int>] {
        var ranges: [Range<Int>] = []
        var consumed = 0
        var pageIndex = 0
        var previousSlotCount: Int? = nil
        let total = previewImages.count
        // Both themes can now reach 6 (magazine43's all-landscape 4->6 bump
        // in rawAdaptiveMagazineSlotCount needs the extra headroom here).
        let maxSlotCount = 6

        while consumed < total {
            let remaining = total - consumed

            let count = max(
                1,
                min(
                    maxSlotCount,
                    adaptiveMagazineSlotCount(
                        pageIndex: pageIndex,
                        startIndex: consumed,
                        remainingPhotos: remaining,
                        previousSlotCount: previousSlotCount
                    )
                )
            )

            let end = min(total, consumed + count)

            guard end > consumed else {
                break
            }

            ranges.append(consumed..<end)
            consumed = end
            pageIndex += 1
            previousSlotCount = count
        }

        return ranges
    }

    // Same idea for Kirigami, but reconstructed with buildOrigamiPagePlans
    // so a review "page" spans exactly the photos a real Kirigami page
    // consumes — its base slots plus whichever later photos fold into them
    // as swap-in replacements — instead of pretending every photo lands in
    // its own fresh, ideally-shaped slot.
    private var origamiReviewPagePlans: [OrigamiPagePlan] {
        buildOrigamiPagePlans(
            previewImages: previewImages,
            imagesBeforePageChange: origamiImagesBeforePageChange,
            isStrict43: visualTheme == .origami43
        )
    }

    private var magazinePageDuration: Double {
        let fadeSeconds = max(0.05, magazineImageFadeSeconds)
        let delaySeconds = max(0, magazineImageDelaySeconds)
        let fillSeconds = fadeSeconds + (delaySeconds * 5)

        if timingMode == .followMusic,
           let audioPlayer,
           selectedPhotoURLs.count > 0 {
            let pageCount = max(1, magazinePreviewPageCount)
            let musicPageDuration = audioPlayer.duration / Double(pageCount)

            // Images still fill in at the normal Fade / Start Delay speed;
            // whatever music time is left over becomes the page hold, so
            // all pages together add up to exactly the music duration.
            return max(fillSeconds, musicPageDuration)
        }

        let pageHoldSeconds = timingMode == .customSpeed ? max(0, secondsPerPhoto) : 0

        // 6 image slots on one magazine page:
        // image 1 starts at 0, each next image starts after Start Delay.
        // Seconds / Page is extra hold time after all images are visible.
        return max(1, fillSeconds + pageHoldSeconds)
    }

    private var magazineLayoutVariant: Int {
        magazinePageIndex % 2
    }

    private func plannedMagazineSlotCount(pageIndex: Int, remainingPhotos: Int) -> Int {
        guard remainingPhotos > 0 else {
            return 0
        }

        let safeSeed = abs(magazinePhotoSeed)

        // Each cycle is a rotation of 2/3/4/6 repeated twice, so all four
        // page sizes get an equal, straightforward 1-in-4 chance every
        // time — no orientation- or position-based logic decides which
        // sizes show up, so every size is a real, equally-likely option
        // throughout the whole slideshow, not just near the end. The
        // rotation puts the first "4" (and "6") at a different early
        // position per cycle, so even short slideshows are likely to reach
        // one of each.
        if visualTheme == .magazine43 {
            let strict43Cycles = [
                [2, 3, 4, 6, 2, 3, 4, 6],
                [3, 4, 6, 2, 3, 4, 6, 2],
                [4, 6, 2, 3, 4, 6, 2, 3],
                [6, 2, 3, 4, 6, 2, 3, 4],
                [2, 4, 6, 3, 2, 4, 6, 3],
                [4, 6, 3, 2, 4, 6, 3, 2],
                [6, 3, 2, 4, 6, 3, 2, 4],
                [3, 2, 4, 6, 3, 2, 4, 6]
            ]

            let cycle = strict43Cycles[safeSeed % strict43Cycles.count]
            let plannedCount = cycle[pageIndex % cycle.count]

            return min(plannedCount, remainingPhotos)
        }

        if pageIndex <= 0 {
            let firstPageChoices = [2, 3, 4]
            let firstPageCount = firstPageChoices[safeSeed % firstPageChoices.count]
            return min(firstPageCount, remainingPhotos)
        }

        // After the first page, use a stable shuffled cycle that includes every
        // Magazine page size: 2, 3, 4, 5, and 6. This keeps the slideshow varied
        // while still letting every template style appear over enough photos.
        let templateCycles = [
            [3, 5, 6, 4, 2],
            [4, 6, 5, 3, 2],
            [5, 3, 6, 2, 4],
            [6, 5, 4, 3, 2],
            [2, 4, 5, 6, 3]
        ]

        let cycle = templateCycles[safeSeed % templateCycles.count]
        let plannedCount = cycle[(pageIndex - 1) % cycle.count]

        return min(plannedCount, remainingPhotos)
    }

    private func adaptiveMagazineSlotCount(
        pageIndex: Int,
        startIndex: Int,
        remainingPhotos: Int,
        previousSlotCount: Int? = nil
    ) -> Int {
        let rawCount = rawAdaptiveMagazineSlotCount(
            pageIndex: pageIndex,
            startIndex: startIndex,
            remainingPhotos: remainingPhotos
        )

        guard visualTheme != .magazine43 else {
            return rawCount
        }

        // Two consecutive Kousei pages with the same photo count read as
        // repetitive (e.g. two back-to-back 2-photo spreads), so nudge this
        // page to the next size in line instead when that happens.
        guard let previousSlotCount, rawCount == previousSlotCount, remainingPhotos > rawCount else {
            return rawCount
        }

        let alternative = rawCount >= 6 ? 5 : rawCount + 1
        return min(alternative, remainingPhotos)
    }

    private func rawAdaptiveMagazineSlotCount(pageIndex: Int, startIndex: Int, remainingPhotos: Int) -> Int {
        let plannedCount = plannedMagazineSlotCount(pageIndex: pageIndex, remainingPhotos: remainingPhotos)

        // These guards steer photos away from the classic wide/tall/flex
        // collage's awkward shape pairings — irrelevant for the strict 4:3
        // grid, which handles any orientation mix by construction.
        guard visualTheme != .magazine43 else {
            // plannedMagazineSlotCount's cycle gives 2/3/4/6 an equal
            // chance, but a 4-photo grid (2x2 of 4:3 cells) only reads
            // right when all 4 are landscape — client-requested: a
            // portrait in the mix needs the extra room a 6-photo grid
            // gives instead, even though that means 4 no longer lands in
            // strictly equal proportion.
            guard plannedCount == 4, remainingPhotos >= 6 else {
                return plannedCount
            }

            let endIndexFour = min(previewImages.count, startIndex + 4)
            guard startIndex >= 0, endIndexFour - startIndex == 4 else {
                return plannedCount
            }

            // Match strict43MagazineTemplate's own isLandscape boolean
            // exactly (width >= height) — that's what actually decides each
            // cell's 4:3-vs-3:4 shape at render time.
            let allLandscape = previewImages[startIndex..<endIndexFour].allSatisfy { $0.size.width >= $0.size.height }

            return allLandscape ? plannedCount : 6
        }

        guard plannedCount > 0, !previewImages.isEmpty else {
            return plannedCount
        }

        let endIndex = min(previewImages.count, startIndex + plannedCount)
        guard startIndex >= 0, startIndex < endIndex else {
            return plannedCount
        }

        let pageImages = Array(previewImages[startIndex..<endIndex])

        let portraitCount = pageImages.filter { image in
            magazineImageAspectRatio(image) < 0.82
        }.count

        let landscapeCount = pageImages.filter { image in
            magazineImageAspectRatio(image) > 1.18
        }.count

        let veryWideCount = pageImages.filter { image in
            magazineImageAspectRatio(image) > 1.55
        }.count

        // Avoid layouts where one portrait is paired with three or more horizontal
        // strip slots. That is where faces and wide photos get cropped too hard.
        if plannedCount >= 4, portraitCount >= 1, landscapeCount >= 3 {
            return min(3, remainingPhotos)
        }

        // Very wide photos need larger slots. If several are coming together,
        // use a lighter page instead of forcing 4/5/6-image magazine pages.
        if plannedCount >= 5, veryWideCount >= 2 {
            return min(3, remainingPhotos)
        }

        if plannedCount >= 4, veryWideCount >= 3 {
            return min(2, remainingPhotos)
        }

        return plannedCount
    }

    private func magazineImageAspectRatio(_ image: NSImage) -> CGFloat {
        let size = image.size

        guard size.width > 0, size.height > 0 else {
            return 1
        }

        return size.width / size.height
    }

    private var currentMagazinePageSlotCount: Int {
        // Cheap O(1) approximation of the previous page's count (just the
        // seed-driven cycle value, skipping the aspect-ratio pass) so the
        // anti-repeat nudge in adaptiveMagazineSlotCount can kick in here too
        // without redoing a full magazineReviewPageRanges walk every frame.
        let previous: Int? = magazinePageIndex > 0
            ? plannedMagazineSlotCount(pageIndex: magazinePageIndex - 1, remainingPhotos: selectedPhotoURLs.count)
            : nil

        return adaptiveMagazineSlotCount(
            pageIndex: magazinePageIndex,
            startIndex: activePhotoIndex,
            remainingPhotos: selectedPhotoURLs.count - activePhotoIndex,
            previousSlotCount: previous
        )
    }

    private func plannedOrigamiSlotCount(
        pageIndex: Int,
        remainingPhotos: Int
    ) -> Int {
        guard remainingPhotos > 0 else {
            return 0
        }

        // The strict 4:3 grid caps out at 4 photos per page (never less
        // than 1), so it gets its own, smaller cycle instead of Kirigami's
        // 2-6 range.
        if visualTheme == .origami43 {
            let cycle = [2, 3, 2, 3, 4]
            let safePageIndex = max(0, pageIndex)
            var plannedCount = min(cycle[safePageIndex % cycle.count], remainingPhotos)

            if remainingPhotos - plannedCount == 1, plannedCount > 2 {
                plannedCount -= 1
            }

            return max(1, min(4, plannedCount))
        }

        // Origami page cycle:
        // page 1 = 3 photos
        // page 2 = 5 photos
        // page 3 = 6 photos
        // page 4 = 2 photos
        // page 5 = 4 photos
        let cycle = [3, 5, 6, 2, 4]

        let safePageIndex = max(0, pageIndex)
        var plannedCount = min(
            cycle[safePageIndex % cycle.count],
            remainingPhotos
        )

        // Avoid leaving a final page with only one photo when the
        // current page can safely give one photo to the next page.
        if remainingPhotos - plannedCount == 1,
           plannedCount > 2 {
            plannedCount -= 1
        }

        return max(1, min(6, plannedCount))
    }

    private var currentOrigamiPageSlotCount: Int {
        plannedOrigamiSlotCount(
            pageIndex: origamiPageIndex,
            remainingPhotos:
                selectedPhotoURLs.count - activePhotoIndex
        )
    }

    private func plannedOrigamiReplacementCount(
        baseSlotCount: Int,
        remainingPhotos: Int
    ) -> Int {
        let requestedReplacementCount = max(
            0,
            min(
                6,
                origamiImagesBeforePageChange
            )
        )

        var replacementCount = min(
            requestedReplacementCount,
            baseSlotCount,
            max(
                0,
                remainingPhotos - baseSlotCount
            )
        )

        // Do not consume so many replacement photos
        // that only one image remains for the next page.
        if remainingPhotos
            - baseSlotCount
            - replacementCount == 1,
           replacementCount > 0 {
            replacementCount -= 1
        }

        return replacementCount
    }

    private var currentOrigamiReplacementCount: Int {
        plannedOrigamiReplacementCount(
            baseSlotCount:
                currentOrigamiPageSlotCount,
            remainingPhotos:
                selectedPhotoURLs.count
                - activePhotoIndex
        )
    }

    private var currentOrigamiConsumedCount: Int {
        currentOrigamiPageSlotCount
            + currentOrigamiReplacementCount
    }

    private var origamiBaseHoldDuration: Double {
        max(
            1.0,
            min(
                15.0,
                origamiInternalHoldSeconds
            )
        )
    }

    private var origamiInternalHoldDuration: Double {
        guard timingMode == .followMusic,
              let audioPlayer,
              selectedPhotoURLs.count > 0
        else {
            return origamiBaseHoldDuration
        }

        let metrics = origamiPlanMetrics

        guard metrics.holds > 0 else {
            return origamiBaseHoldDuration
        }

        let initialRevealDuration =
            metrics.pages > 0 ? origamiTransitionDuration : 0

        let wholePageFoldDuration =
            Double(max(0, metrics.pages - 1)) * 1.30

        let nonHoldDuration =
            Double(metrics.swaps) * origamiInternalSwapDuration
            + initialRevealDuration
            + wholePageFoldDuration

        let remainingDuration = audioPlayer.duration - nonHoldDuration

        // Swaps and fold transitions keep their normal pace; whatever
        // music time is left over is spread across the holds, so the
        // whole slideshow adds up to exactly the music duration.
        return max(0.5, remainingDuration / Double(metrics.holds))
    }

    private var origamiInternalSwapDuration: Double {
        1.05
    }

    private var currentPreviewPageSlotCount: Int {
        if usesOrigamiTheme {
            return currentOrigamiPageSlotCount
        }

        return currentMagazinePageSlotCount
    }

    private var magazinePreviewPageCount: Int {
        guard selectedPhotoURLs.count > 0 else {
            return 0
        }

        var pageIndex = 0
        var consumedPhotos = 0
        var previousSlotCount: Int? = nil

        while consumedPhotos < selectedPhotoURLs.count {
            let remainingPhotos = selectedPhotoURLs.count - consumedPhotos
            let slotCount = max(
                1,
                adaptiveMagazineSlotCount(
                    pageIndex: pageIndex,
                    startIndex: consumedPhotos,
                    remainingPhotos: remainingPhotos,
                    previousSlotCount: previousSlotCount
                )
            )

            consumedPhotos += slotCount
            pageIndex += 1
            previousSlotCount = slotCount
        }

        return pageIndex
    }


    private var origamiPlanMetrics: (
        pages: Int,
        swaps: Int,
        holds: Int
    ) {
        guard !selectedPhotoURLs.isEmpty else {
            return (0, 0, 0)
        }

        var pageIndex = 0
        var consumedPhotos = 0
        var totalSwaps = 0
        var totalHolds = 0

        while consumedPhotos
                < selectedPhotoURLs.count {

            let remainingPhotos =
                selectedPhotoURLs.count
                - consumedPhotos

            let baseSlotCount = max(
                1,
                plannedOrigamiSlotCount(
                    pageIndex: pageIndex,
                    remainingPhotos:
                        remainingPhotos
                )
            )

            let replacementCount =
                plannedOrigamiReplacementCount(
                    baseSlotCount:
                        baseSlotCount,
                    remainingPhotos:
                        remainingPhotos
                )

            // Timer must count the exact number of
            // replacement batches that playback performs.
            //
            // Example:
            // replacementCount = 2
            // simultaneousSwapCount = 1
            // result = 2 separate swap animations.
            let simultaneousCount = max(
                1,
                origamiSimultaneousSwapCount
            )

            let replacementBatchCount: Int

            if replacementCount > 0 {
                replacementBatchCount =
                    (
                        replacementCount
                        + simultaneousCount
                        - 1
                    )
                    / simultaneousCount
            } else {
                replacementBatchCount = 0
            }

            totalSwaps +=
                replacementBatchCount

            // Playback waits once before every batch,
            // and once more before changing the full page.
            totalHolds +=
                replacementBatchCount + 1

            consumedPhotos +=
                baseSlotCount
                + replacementCount

            pageIndex += 1
        }

        return (
            pages: pageIndex,
            swaps: totalSwaps,
            holds: totalHolds
        )
    }

    private var origamiPreviewPageCount: Int {
        origamiPlanMetrics.pages
    }


    private var magazineRevealProgress: Double {
        let revealOnlySeconds = max(
            0.05,
            magazineImageFadeSeconds + (magazineImageDelaySeconds * 5)
        )

        return min(1, max(0, magazineRevealElapsedSeconds / revealOnlySeconds))
    }

    private var activePreviewImage: NSImage? {
        guard previewImages.indices.contains(activePhotoIndex) else {
            return previewImages.first
        }

        return previewImages[activePhotoIndex]
    }

    private var previousPreviewImage: NSImage? {
        guard let previousPhotoIndex, previewImages.indices.contains(previousPhotoIndex) else {
            return nil
        }

        return previewImages[previousPhotoIndex]
    }

    private var activePhotoName: String {
        guard selectedPhotoURLs.indices.contains(activePhotoIndex) else {
            return selectedPhotoURLs.first?.lastPathComponent ?? "Photo"
        }

        return selectedPhotoURLs[activePhotoIndex].lastPathComponent
    }

    private var origamiTransitionDuration: Double {
        min(
            1.20,
            max(
                0.78,
                origamiBaseHoldDuration * 0.30
            )
        )
    }

    private var imaginationPreviewSceneCount: Int {
        let photoCount = selectedPhotoURLs.count

        guard photoCount > 0 else {
            return 0
        }

        // Imagination redosled:
        // single troši 1 fotografiju,
        // twin troši naredne 2 fotografije.
        //
        // Svake 3 fotografije zato čine 2 scene:
        // single + twin.
        let completeGroups = photoCount / 3
        let remainingPhotos = photoCount % 3

        return completeGroups * 2
            + remainingPhotos
    }

    private var currentPhotoDuration: Double {
        if usesMagazineTheme {
            return magazinePageDuration
        }

        if usesOrigamiTheme {
            return origamiInternalHoldDuration
        }

        switch timingMode {
        case .followMusic:
            guard selectedPhotoURLs.count > 0, let audioPlayer else {
                return max(1, secondsPerPhoto)
            }

            if visualTheme == .imagination {
                return max(
                    0.5,
                    audioPlayer.duration
                        / Double(
                            max(
                                1,
                                imaginationPreviewSceneCount
                            )
                        )
                )
            }

            return max(
                0.5,
                audioPlayer.duration
                    / Double(selectedPhotoURLs.count)
            )
        case .customSpeed:
            return max(1, secondsPerPhoto)
        }
    }

    private var totalPreviewDuration: Double {
        guard !selectedPhotoURLs.isEmpty else {
            return 0
        }

        if usesMagazineTheme {
            return magazinePageDuration * Double(max(1, magazinePreviewPageCount))
        }

        if usesOrigamiTheme {
            let metrics = origamiPlanMetrics

            let initialRevealDuration =
                metrics.pages > 0
                ? origamiTransitionDuration
                : 0

            let wholePageFoldDuration =
                Double(
                    max(
                        0,
                        metrics.pages - 1
                    )
                )
                * 1.30

            return
                Double(metrics.holds)
                    * origamiInternalHoldDuration
                + Double(metrics.swaps)
                    * origamiInternalSwapDuration
                + initialRevealDuration
                + wholePageFoldDuration
        }

        if timingMode == .followMusic, let audioPlayer {
            return max(0, audioPlayer.duration)
        }

        if visualTheme == .imagination {
            return currentPhotoDuration
                * Double(
                    max(
                        1,
                        imaginationPreviewSceneCount
                    )
                )
        }

        return currentPhotoDuration
            * Double(selectedPhotoURLs.count)
    }

    private var isOrigamiOnFinalSettledPage: Bool {
        guard usesOrigamiTheme,
              !selectedPhotoURLs.isEmpty
        else {
            return false
        }

        let nextIndex =
            activePhotoIndex
            + currentOrigamiConsumedCount

        return nextIndex >= selectedPhotoURLs.count
            && origamiCompletedSwapCount
                >= currentOrigamiReplacementCount
            && !isOrigamiSwapAnimating
            && !isOrigamiWholePageFoldAnimating
            && previousOrigamiPageImages.isEmpty
            && transitionProgress >= 0.999
    }

    private var origamiBlackOverlayOpacity: Double {
        guard usesOrigamiTheme,
              totalPreviewDuration > 0
        else {
            return 0
        }

        // Keep the normal preview visible before playback.
        if previewTotalElapsedSeconds <= 0,
           !isPreviewPlaying {
            return 0
        }

        let fadeDuration = min(
            1.0,
            totalPreviewDuration * 0.5
        )

        guard fadeDuration > 0 else {
            return 0
        }

        let elapsed = min(
            max(
                0,
                previewTotalElapsedSeconds
            ),
            totalPreviewDuration
        )

        // Initial black reveal remains unchanged.
        let fadeInAlpha = max(
            0,
            1 - elapsed / fadeDuration
        )

        // Never allow the ending fade to cover:
        // - an internal image swap
        // - a whole-page fold
        // - any intermediate Origami page
        guard isOrigamiOnFinalSettledPage else {
            return fadeInAlpha
        }

        let fadeOutStart = max(
            0,
            totalPreviewDuration
                - fadeDuration
        )

        let fadeOutAlpha: Double

        if elapsed >= fadeOutStart {
            let linearProgress = min(
                1,
                max(
                    0,
                    (
                        elapsed
                        - fadeOutStart
                    )
                    / fadeDuration
                )
            )

            fadeOutAlpha =
                linearProgress
                * linearProgress
                * (
                    3.0
                    - 2.0 * linearProgress
                )
        } else {
            fadeOutAlpha = 0
        }

        return min(
            1,
            max(
                fadeInAlpha,
                fadeOutAlpha
            )
        )
    }

    private var magazineBlackOverlayOpacity: Double {
        guard usesMagazineTheme,
              totalPreviewDuration > 0
        else {
            return 0
        }

        let fadeDuration = min(
            3.0,
            totalPreviewDuration
        )

        guard fadeDuration > 0 else {
            return 0
        }

        let fadeStart = max(
            0,
            totalPreviewDuration - fadeDuration
        )

        let linearProgress = min(
            1,
            max(
                0,
                (
                    previewTotalElapsedSeconds
                    - fadeStart
                ) / fadeDuration
            )
        )

        return linearProgress
            * linearProgress
            * (3.0 - 2.0 * linearProgress)
    }

    private var timeCounterText: String {
        guard !selectedPhotoURLs.isEmpty else {
            return "00:00 / 00:00"
        }

        let elapsed = min(previewTotalElapsedSeconds, totalPreviewDuration)

        if usesMagazineTheme {
            let delaySeconds = max(0, magazineImageDelaySeconds)
            let visibleOnPage: Int

            if delaySeconds <= 0 {
                visibleOnPage = currentMagazinePageSlotCount
            } else {
                visibleOnPage = min(
                    currentMagazinePageSlotCount,
                    max(1, Int(floor(magazineRevealElapsedSeconds / delaySeconds)) + 1)
                )
            }

            let visiblePhotoNumber = min(selectedPhotoURLs.count, activePhotoIndex + visibleOnPage)
            return "\(formatTime(elapsed)) / \(formatTime(totalPreviewDuration)) · Photo \(visiblePhotoNumber) / \(selectedPhotoURLs.count)"
        }

        if usesOrigamiTheme {
            let visiblePhotoNumber = min(
                selectedPhotoURLs.count,
                activePhotoIndex + currentOrigamiPageSlotCount
            )

            return "\(formatTime(elapsed)) / \(formatTime(totalPreviewDuration)) · Photo \(visiblePhotoNumber) / \(selectedPhotoURLs.count)"
        }

        return "\(formatTime(elapsed)) / \(formatTime(totalPreviewDuration)) · Photo \(activePhotoIndex + 1) / \(selectedPhotoURLs.count)"
    }

    private func formatTime(_ seconds: Double) -> String {
        let safeSeconds = max(0, Int(seconds.rounded()))
        let minutes = safeSeconds / 60
        let remainingSeconds = safeSeconds % 60

        return String(format: "%02d:%02d", minutes, remainingSeconds)
    }

    private func togglePreview() {
        guard !selectedPhotoURLs.isEmpty,
              !isPreparingPhotos,
              !previewImages.isEmpty
        else {
            return
        }

        isPreviewPlaying.toggle()
        previewElapsedSeconds = 0

        if isPreviewPlaying {
            let fadeInDuration = max(
                musicFadeInSeconds,
                0.1
            )

            audioPlayer?.volume = Float(
                min(
                    previewTotalElapsedSeconds
                        / fadeInDuration,
                    1
                )
            )

            audioPlayer?.play()

            if usesMagazineTheme {
                transitionProgress = 1
                magazineRevealElapsedSeconds = 0
            } else if visualTheme == .imagination,
                      activePhotoIndex == 0,
                      previewTotalElapsedSeconds == 0 {

                beginImaginationIntroSequence()
            }
        } else {
            audioPlayer?.pause()
        }
    }

    // Crni overlay glatko ide sa 1 na 0 tokom 3 sekunde na početku.
    // Reveal animacija prve fotografije kreće normalno, odmah,
    // ispod ovog overlaya (isto kao muzika).
    private func beginImaginationIntroSequence() {
        var setupTransaction = Transaction()
        setupTransaction.animation = nil

        withTransaction(setupTransaction) {
            imaginationIntroOutroOpacity = 1
        }

        withAnimation(.easeInOut(duration: 3.0)) {
            imaginationIntroOutroOpacity = 0
        }
    }

    private func resetOrigamiInternalSwapState() {
        origamiSlotReplacementImages = [:]
        origamiCompletedSwapCount = 0
        origamiActiveSwapImages = [:]
        origamiActiveSwapStyles = [:]
        origamiSwapProgress = 1
        isOrigamiSwapAnimating = false
        origamiUsedReplacementSlots = []
    }

    private func origamiAspectRatio(
        of image: NSImage
    ) -> Double {
        guard image.size.height > 0 else {
            return 1
        }

        return Double(
            image.size.width / image.size.height
        )
    }

    private func origamiOrientationClass(
        of image: NSImage
    ) -> Int {
        let ratio =
            origamiAspectRatio(of: image)

        if ratio > 1.15 {
            return 1
        }

        if ratio < 0.85 {
            return -1
        }

        return 0
    }

    private func origamiReplacementTargetSlots(
        for incomingImages: [NSImage],
        slotCount: Int,
        excluding usedSlots: Set<Int> = []
    ) -> [Int] {
        guard slotCount > 0 else {
            return []
        }

        let currentImages =
            currentOrigamiPageImages()

        var availableSlots =
            Array(0..<slotCount).filter {
                !usedSlots.contains($0)
            }

        if availableSlots.isEmpty {
            availableSlots = Array(0..<slotCount)
        }

        var targets: [Int] = []

        for incomingImage in incomingImages {
            guard !availableSlots.isEmpty else {
                break
            }

            let incomingRatio =
                origamiAspectRatio(
                    of: incomingImage
                )

            let incomingOrientation =
                origamiOrientationClass(
                    of: incomingImage
                )

            let target =
                availableSlots.min {
                    leftSlot,
                    rightSlot in

                    func score(
                        for slot: Int
                    ) -> Double {
                        guard currentImages.indices.contains(
                            slot
                        ) else {
                            return 100
                        }

                        let currentImage =
                            origamiSlotReplacementImages[
                                slot
                            ]
                            ?? currentImages[slot]

                        let currentRatio =
                            origamiAspectRatio(
                                of: currentImage
                            )

                        let currentOrientation =
                            origamiOrientationClass(
                                of: currentImage
                            )

                        let orientationPenalty =
                            incomingOrientation
                                == currentOrientation
                            ? 0
                            : 8

                        let ratioPenalty = abs(
                            log(
                                max(
                                    0.05,
                                    incomingRatio
                                )
                                /
                                max(
                                    0.05,
                                    currentRatio
                                )
                            )
                        )

                        return
                            Double(
                                orientationPenalty
                            )
                            + ratioPenalty
                    }

                    return score(for: leftSlot)
                        < score(for: rightSlot)
                }!

            targets.append(target)

            availableSlots.removeAll {
                $0 == target
            }
        }

        return targets
    }

    private func startOrigamiInternalSwap() {
        guard usesOrigamiTheme,
              !isOrigamiSwapAnimating,
              origamiCompletedSwapCount
                < currentOrigamiReplacementCount,
              currentOrigamiPageSlotCount > 0
        else {
            return
        }

        let batchCount = min(
            max(1, origamiSimultaneousSwapCount),
            currentOrigamiReplacementCount
                - origamiCompletedSwapCount
        )

        let replacementStart =
            activePhotoIndex
            + currentOrigamiPageSlotCount
            + origamiCompletedSwapCount

        let replacementEnd = min(
            previewImages.count,
            replacementStart
                + batchCount
        )

        guard replacementStart
                < replacementEnd
        else {
            return
        }

        let incomingImages = Array(
            previewImages[
                replacementStart..<replacementEnd
            ]
        )

        let targetSlots =
            origamiReplacementTargetSlots(
                for: incomingImages,
                slotCount:
                    currentOrigamiPageSlotCount,
                excluding:
                    origamiUsedReplacementSlots
            )

        guard targetSlots.count
                == incomingImages.count
        else {
            return
        }

        var batchImages:
            [Int: NSImage] = [:]

        var batchStyles:
            [Int: Int] = [:]

        // Every selected image uses one shared fold
        // style and starts at exactly the same time.
        let batchStyle =
            origamiPageIndex.isMultiple(of: 2)
            ? 0
            : 1

        for (
            offset,
            incomingImage
        ) in incomingImages.enumerated() {
            let slot =
                targetSlots[offset]

            batchImages[slot] =
                incomingImage

            batchStyles[slot] =
                batchStyle
        }

        let pageStartIndex =
            activePhotoIndex

        origamiUsedReplacementSlots.formUnion(
            targetSlots
        )

        origamiActiveSwapImages =
            batchImages

        origamiActiveSwapStyles =
            batchStyles

        origamiSwapProgress = 0
        isOrigamiSwapAnimating = true

        let duration =
            origamiInternalSwapDuration

        DispatchQueue.main.async {
            withAnimation(
                .easeInOut(
                    duration: duration
                )
            ) {
                origamiSwapProgress = 1
            }
        }

        DispatchQueue.main.asyncAfter(
            deadline:
                .now()
                + duration
                + 0.03
        ) {
            guard activePhotoIndex
                    == pageStartIndex
            else {
                return
            }

            for (
                slot,
                incomingImage
            ) in batchImages {
                origamiSlotReplacementImages[
                    slot
                ] = incomingImage
            }

            origamiCompletedSwapCount +=
                incomingImages.count

            origamiActiveSwapImages = [:]
            origamiActiveSwapStyles = [:]
            origamiSwapProgress = 1
            isOrigamiSwapAnimating = false
        }
    }

    // The 1/60s tick timer only fires that often when the main thread keeps
    // up; under render load (heavy Kirigami fold animations, 4K live
    // preview) ticks arrive late or get coalesced. Advancing the preview
    // clock by a fixed 1/60s per tick regardless made it drift behind real
    // time — and behind the audio player, which keeps real hardware time
    // independent of tick timing — so in Follow Music the photos fell
    // further and further behind the music and the track finished (and,
    // for a single track, looped) before the preview had caught up.
    // Measuring the actual elapsed time keeps the preview clock locked to
    // real time regardless of dropped ticks.
    private func measuredPreviewTickDelta() -> Double {
        let now = CACurrentMediaTime()

        defer {
            previewTickLastTimestamp = now
        }

        guard let lastTimestamp = previewTickLastTimestamp else {
            return 1.0 / 60.0
        }

        return min(0.5, max(0, now - lastTimestamp))
    }

    private func advancePreviewIfNeeded(
        delta: Double
    ) {
        guard isPreviewPlaying,
              !selectedPhotoURLs.isEmpty
        else {
            return
        }

        previewTotalElapsedSeconds += delta

        updateMusicPlaylistPlayback(delta: delta)
        updateAudioFadeOut()

        if usesOrigamiTheme {
            // Do not count the 3.5 second hold while
            // the whole page or one slot is animating.
            guard transitionProgress >= 0.999,
                  !isOrigamiSwapAnimating,
                  !isOrigamiWholePageFoldAnimating
            else {
                return
            }

            previewElapsedSeconds += delta

            guard previewElapsedSeconds
                    >= origamiInternalHoldDuration
            else {
                return
            }

            previewElapsedSeconds = 0

            if origamiCompletedSwapCount
                < currentOrigamiReplacementCount {

                startOrigamiInternalSwap()
                return
            }

            let nextIndex =
                activePhotoIndex
                + currentOrigamiConsumedCount

            if nextIndex
                >= selectedPhotoURLs.count {

                if shouldLoopPreview {
                    startPreviewFromBeginning()
                } else {
                    // Keep the final Origami page visible
                    // while the timer and music fade-out
                    // finish their remaining duration.
                    let remainingDuration = max(
                        0,
                        totalPreviewDuration
                            - previewTotalElapsedSeconds
                    )

                    if remainingDuration > 0.02 {
                        // Keep checking the final state on
                        // every timer tick instead of waiting
                        // through another complete image delay.
                        previewElapsedSeconds =
                            origamiInternalHoldDuration

                        updateAudioFadeOut()
                        return
                    }

                    previewTotalElapsedSeconds =
                        totalPreviewDuration

                    // Guarantee the exact final fade value
                    // before pausing the player.
                    updateAudioFadeOut()
                    audioPlayer?.volume = 0
                    audioPlayer?.pause()

                    isPreviewPlaying = false
                    transitionProgress = 1
                    origamiSwapProgress = 1
                }

                return
            }

            moveToPhoto(at: nextIndex)
            return
        }

        previewElapsedSeconds += delta

        if usesMagazineTheme {
            magazineRevealElapsedSeconds =
                previewElapsedSeconds
        }

        guard previewElapsedSeconds
                >= currentPhotoDuration
        else {
            return
        }

        previewElapsedSeconds = 0

        if usesMagazineTheme {
            magazineRevealElapsedSeconds = 0
        }

        let imaginationConsumedPhotoCount: Int =
            visualTheme == .imagination
            && activePhotoIndex % 3 == 1
            && activePhotoIndex + 1
                < previewImages.count
            ? 2
            : 1

        let nextIndex =
            activePhotoIndex
            + (
                usesMagazineTheme
                ? currentMagazinePageSlotCount
                : imaginationConsumedPhotoCount
            )

        if nextIndex >= selectedPhotoURLs.count {
            if shouldLoopPreview {
                if visualTheme == .imagination {
                    startPreviewFromBeginning()
                } else {
                    previewTotalElapsedSeconds = 0
                    audioPlayer?.volume = 0
                    audioPlayer?.currentTime = 0
                    audioPlayer?.play()
                    moveToPhoto(at: 0)
                }
            } else if visualTheme == .imagination {
                // Imagination twin scena je već prikazala
                // i aktivnu i sledeću fotografiju.
                // Ne prebacuj ponovo na poslednju fotografiju.
                transitionProgress = 1
                previousPhotoIndex = nil
                isImaginationPageTransitionAnimating = false

                if !isImaginationOutroAnimating {
                    isImaginationOutroAnimating = true

                    withAnimation(
                        .easeInOut(duration: 4.0)
                    ) {
                        imaginationIntroOutroOpacity = 1
                    }

                    // Keep isPreviewPlaying (and thus the existing
                    // per-page black overlay) true for the full 4s
                    // outro fade so the drift/dust/flare animations
                    // keep running underneath while it fades to black.
                    DispatchQueue.main.asyncAfter(
                        deadline: .now() + 4.0
                    ) {
                        isPreviewPlaying = false

                        previewTotalElapsedSeconds =
                            totalPreviewDuration

                        audioPlayer?.pause()
                        isImaginationOutroAnimating = false
                    }
                }
            } else {
                isPreviewPlaying = false

                previewTotalElapsedSeconds =
                    totalPreviewDuration

                audioPlayer?.pause()

                if usesMagazineTheme {
                    transitionProgress = 1

                    magazineRevealElapsedSeconds = max(
                        0.05,
                        magazineImageFadeSeconds
                            + (
                                magazineImageDelaySeconds
                                * 5
                            )
                    )
                } else {
                    moveToPhoto(
                        at:
                            selectedPhotoURLs.count
                            - 1
                    )
                }
            }

            return
        }

        moveToPhoto(at: nextIndex)
    }

    private func startPreviewFromBeginning() {
        guard !selectedPhotoURLs.isEmpty,
              !isPreparingPhotos,
              !previewImages.isEmpty
        else {
            return
        }

        previousPhotoIndex = nil
        activePhotoIndex = 0
        magazinePageIndex = 0
        origamiPageIndex = 0

        resetOrigamiInternalSwapState()

        previousOrigamiPageImages = []
        previousOrigamiPageReplacements = [:]
        previousOrigamiPageAnimationVariant = 0
        origamiWholePageFoldProgress = 1

        previewElapsedSeconds = 0
        previewTotalElapsedSeconds = 0

        if visualTheme == .imagination {
            imaginationPlaybackRestartToken += 1
            isImaginationOutroAnimating = false
        }

        isPreviewPlaying = true
        currentMusicIndex = 0
        currentMusicElapsedSeconds = 0

        prepareAudioPlayer(
            for: activeMusicURL
        )

        audioPlayer?.volume = 0
        audioPlayer?.currentTime = 0
        audioPlayer?.play()

        if usesMagazineTheme {
            transitionProgress = 1
            magazineRevealElapsedSeconds = 0
        } else if usesOrigamiTheme {
            transitionProgress = 0

            let duration =
                origamiTransitionDuration

            DispatchQueue.main.async {
                withAnimation(
                    .easeInOut(
                        duration: duration
                    )
                ) {
                    transitionProgress = 1
                }
            }
        } else {
            transitionProgress = 1

            if visualTheme == .imagination {
                beginImaginationIntroSequence()
            }
        }
    }

    private func seekPreview(toFraction fraction: Double) {
        guard !selectedPhotoURLs.isEmpty,
              !isPreparingPhotos,
              !previewImages.isEmpty,
              totalPreviewDuration > 0
        else {
            return
        }

        let clampedFraction = min(1, max(0, fraction))
        let targetElapsed = clampedFraction * totalPreviewDuration
        let photoCount = selectedPhotoURLs.count

        // Snap to the nearest photo/page boundary instead of an exact mid-fade
        // frame - Origami/Imagination drive their in-between visuals through
        // async, animated state with no simple inverse, so landing on a
        // settled boundary is far safer than trying to reconstruct it.
        previousPhotoIndex = nil
        transitionProgress = 1
        previewElapsedSeconds = 0

        activePhotoIndex = min(
            photoCount - 1,
            Int((clampedFraction * Double(photoCount)).rounded(.down))
        )

        resetOrigamiInternalSwapState()
        previousOrigamiPageImages = []
        previousOrigamiPageReplacements = [:]
        previousOrigamiPageAnimationVariant = 0
        origamiWholePageFoldProgress = 1

        isImaginationPageTransitionAnimating = false
        isImaginationOutroAnimating = false
        imaginationIntroOutroOpacity = 0
        imaginationPlaybackRestartToken += 1

        if usesMagazineTheme {
            let pageCount = max(1, magazinePreviewPageCount)
            magazinePageIndex = min(
                pageCount - 1,
                Int((clampedFraction * Double(pageCount)).rounded(.down))
            )
            magazineRevealElapsedSeconds = 0
        }

        if usesOrigamiTheme {
            let pageCount = max(1, origamiPlanMetrics.pages)
            origamiPageIndex = min(
                pageCount - 1,
                Int((clampedFraction * Double(pageCount)).rounded(.down))
            )
        }

        previewTotalElapsedSeconds = targetElapsed

        if selectedMusicURLs.count == 1, let audioPlayer, audioPlayer.duration > 0 {
            audioPlayer.currentTime = targetElapsed.truncatingRemainder(dividingBy: audioPlayer.duration)
        }

        updateAudioFadeOut()
    }

    private func updateMusicPlaylistPlayback(delta: Double) {
        guard isPreviewPlaying, !selectedMusicURLs.isEmpty else {
            return
        }

        guard let player = audioPlayer else {
            currentMusicElapsedSeconds = 0
            prepareAudioPlayer(for: activeMusicURL)
            audioPlayer?.play()
            return
        }

        currentMusicElapsedSeconds += delta

        guard selectedMusicURLs.count > 1 else {
            return
        }

        let trackDuration = max(0.05, player.duration)

        if currentMusicElapsedSeconds >= trackDuration || !player.isPlaying {
            let currentVolume = player.volume
            currentMusicIndex = (currentMusicIndex + 1) % selectedMusicURLs.count
            currentMusicElapsedSeconds = 0
            prepareAudioPlayer(for: activeMusicURL)
            audioPlayer?.volume = currentVolume
            audioPlayer?.currentTime = 0
            audioPlayer?.play()
        }
    }

    private func updateAudioFadeOut() {
        guard let audioPlayer, isPreviewPlaying, totalPreviewDuration > 0 else {
            return
        }

        let fadeInDuration = min(max(musicFadeInSeconds, 0), max(totalPreviewDuration, 0))
        let fadeOutDuration = min(max(musicFadeOutSeconds, 0), max(totalPreviewDuration, 0))

        var fadeInVolume = 1.0
        if fadeInDuration > 0, previewTotalElapsedSeconds < fadeInDuration {
            fadeInVolume = min(1, max(0, previewTotalElapsedSeconds / fadeInDuration))
        }

        var fadeOutVolume = 1.0
        if fadeOutDuration > 0 {
            let fadeStart = max(0, totalPreviewDuration - fadeOutDuration)

            if previewTotalElapsedSeconds >= fadeStart {
                let fadeProgress = min(1, max(0, (previewTotalElapsedSeconds - fadeStart) / fadeOutDuration))
                fadeOutVolume = max(0, 1 - fadeProgress)
            }
        }

        audioPlayer.volume = Float(min(fadeInVolume, fadeOutVolume))
    }

    private func currentOrigamiPageImages()
        -> [NSImage] {

        guard usesOrigamiTheme,
              previewImages.indices.contains(
                activePhotoIndex
              )
        else {
            return []
        }

        let slotCount = max(
            1,
            min(
                currentOrigamiPageSlotCount,
                previewImages.count
                    - activePhotoIndex
            )
        )

        let endIndex = min(
            previewImages.count,
            activePhotoIndex + slotCount
        )

        return Array(
            previewImages[
                activePhotoIndex..<endIndex
            ]
        )
    }

    private func startImaginationPageTransition(
        to newIndex: Int
    ) {
        guard visualTheme == .imagination,
              selectedPhotoURLs.indices.contains(newIndex),
              newIndex != activePhotoIndex,
              !isImaginationPageTransitionAnimating
        else {
            return
        }

        isImaginationPageTransitionAnimating = true

        let totalDuration = min(
            max(fadeDuration, 0.36),
            max(
                0.36,
                currentPhotoDuration * 0.45
            )
        )

        let closingDuration =
            totalDuration * 0.48

        let openingDuration =
            totalDuration * 0.52

        var setupTransaction = Transaction()
        setupTransaction.animation = nil

        withTransaction(setupTransaction) {
            previousPhotoIndex = nil
            transitionProgress = 0
        }

        // Prva polovina:
        // samo glatko zatvaranje crnog overlaya.
        withAnimation(
            .easeInOut(
                duration: closingDuration
            )
        ) {
            transitionProgress = 0.5
        }

        DispatchQueue.main.asyncAfter(
            deadline:
                .now()
                + closingDuration
        ) {
            var swapTransaction = Transaction()
            swapTransaction.animation = nil

            // Fotografija se menja tek kada je kadar
            // potpuno prekriven crnim overlayem.
            withTransaction(swapTransaction) {
                transitionProgress = 0.5
                activePhotoIndex = newIndex
            }

            // Daj SwiftUI-ju jedan render frame da pripremi:
            // - novu fotografiju
            // - card size
            // - blur slojeve
            // - dust
            // - novu reveal animaciju
            //
            // Tek nakon toga otvaramo kadar.
            DispatchQueue.main.asyncAfter(
                deadline:
                    .now()
                    + (1.0 / 30.0)
            ) {
                withAnimation(
                    .easeInOut(
                        duration:
                            openingDuration
                    )
                ) {
                    transitionProgress = 1
                }

                DispatchQueue.main.asyncAfter(
                    deadline:
                        .now()
                        + openingDuration
                        + 0.02
                ) {
                    var completionTransaction =
                        Transaction()

                    completionTransaction.animation =
                        nil

                    withTransaction(
                        completionTransaction
                    ) {
                        transitionProgress = 1
                        previousPhotoIndex = nil

                        isImaginationPageTransitionAnimating =
                            false
                    }
                }
            }
        }
    }

    private func moveToPhoto(
        at newIndex: Int
    ) {
        guard selectedPhotoURLs.indices.contains(
                newIndex
              ),
              newIndex != activePhotoIndex
        else {
            return
        }

        if visualTheme == .imagination {
            startImaginationPageTransition(
                to: newIndex
            )
            return
        }

        if usesMagazineTheme {
            previousPhotoIndex = nil
            activePhotoIndex = newIndex

            magazinePageIndex =
                newIndex == 0
                ? 0
                : magazinePageIndex + 1

            transitionProgress = 1
            magazineRevealElapsedSeconds = 0
            return
        }

        if usesOrigamiTheme {
            let oldPageImages =
                currentOrigamiPageImages()

            let oldReplacements =
                origamiSlotReplacementImages

            let oldAnimationVariant =
                origamiPageIndex

            var setupTransaction =
                Transaction()

            setupTransaction.animation = nil

            withTransaction(
                setupTransaction
            ) {
                previousPhotoIndex =
                    activePhotoIndex

                previousOrigamiPageImages =
                    oldPageImages

                previousOrigamiPageReplacements =
                    oldReplacements

                previousOrigamiPageAnimationVariant =
                    oldAnimationVariant

                origamiWholePageFoldProgress = 0

                isOrigamiWholePageFoldAnimating = true

                origamiPageIndex =
                    newIndex == 0
                    ? 0
                    : origamiPageIndex + 1

                activePhotoIndex =
                    newIndex

                // New page stays flat and stationary
                // behind the previous folding page.
                transitionProgress = 1

                resetOrigamiInternalSwapState()
            }

            let duration = 1.30

            // Drive the whole-page fold with real frame-by-frame
            // state updates. This prevents SwiftUI from interrupting
            // the implicit animation when activePhotoIndex changes
            // and the parent Origami view is rebuilt.
            Task { @MainActor in
                let startTime =
                    Date.timeIntervalSinceReferenceDate

                while true {
                    guard activePhotoIndex == newIndex,
                          isOrigamiWholePageFoldAnimating
                    else {
                        return
                    }

                    let elapsed =
                        Date.timeIntervalSinceReferenceDate
                        - startTime

                    let linearProgress = min(
                        1,
                        max(
                            0,
                            elapsed / duration
                        )
                    )

                    // Smoothstep easing, equivalent to the previous
                    // ease-in-out animation but stored as real state.
                    let easedProgress =
                        linearProgress
                        * linearProgress
                        * (
                            3
                            - 2 * linearProgress
                        )

                    var frameTransaction =
                        Transaction()

                    frameTransaction.animation = nil

                    withTransaction(
                        frameTransaction
                    ) {
                        origamiWholePageFoldProgress =
                            easedProgress
                    }

                    if linearProgress >= 1 {
                        break
                    }

                    try? await Task.sleep(
                        nanoseconds: 16_666_667
                    )
                }

                try? await Task.sleep(
                    nanoseconds: 40_000_000
                )

                guard activePhotoIndex == newIndex else {
                    isOrigamiWholePageFoldAnimating = false
                    return
                }

                var cleanupTransaction =
                    Transaction()

                cleanupTransaction.animation = nil

                withTransaction(
                    cleanupTransaction
                ) {
                    origamiWholePageFoldProgress = 1
                    previousOrigamiPageImages = []
                    previousOrigamiPageReplacements = [:]
                    previousPhotoIndex = nil
                    isOrigamiWholePageFoldAnimating = false
                }
            }

            return
        }

        if transitionStyle == .fade {
            previousPhotoIndex =
                activePhotoIndex

            transitionProgress = 0
            activePhotoIndex = newIndex

            let safeFadeDuration = min(
                max(fadeDuration, 0.15),
                max(
                    0.15,
                    currentPhotoDuration * 0.45
                )
            )

            DispatchQueue.main.async {
                withAnimation(
                    .easeInOut(
                        duration:
                            safeFadeDuration
                    )
                ) {
                    transitionProgress = 1
                }
            }

            DispatchQueue.main.asyncAfter(
                deadline:
                    .now()
                    + safeFadeDuration
                    + 0.02
            ) {
                if activePhotoIndex
                    == newIndex {

                    previousPhotoIndex = nil
                    transitionProgress = 1
                }
            }
        } else {
            previousPhotoIndex = nil
            transitionProgress = 1
            activePhotoIndex = newIndex
        }
    }

    private func resetPreviewState() {
        activePhotoIndex = 0
        previousPhotoIndex = nil
        transitionProgress = 1
        magazineRevealElapsedSeconds = 0
        magazinePageIndex = 0
        origamiPageIndex = 0

        resetOrigamiInternalSwapState()

        previousOrigamiPageImages = []
        previousOrigamiPageReplacements = [:]
        previousOrigamiPageAnimationVariant = 0
        origamiWholePageFoldProgress = 1
        isOrigamiWholePageFoldAnimating = false

        previewElapsedSeconds = 0
        previewTotalElapsedSeconds = 0
        isImaginationPageTransitionAnimating = false
        imaginationIntroOutroOpacity = 0
        isImaginationOutroAnimating = false
        isPreviewPlaying = false

        audioPlayer?.pause()
        audioPlayer?.currentTime = 0
        audioPlayer?.volume = 1
    }

    private func clearImages() {
        selectedPhotoURLs = []
        previewImages = []
        preparedPhotoCount = 0
        isPreparingPhotos = false
        resetPreviewState()
        discardPreparedPreviewVideo()
    }

    private func discardPreparedPreviewVideo() {
        previewVideoPlayer?.pause()
        previewVideoPlayer = nil

        if let staleURL = preparedPreviewVideoURL {
            try? FileManager.default.removeItem(at: staleURL)
        }

        preparedPreviewVideoURL = nil
        preparedPreviewVideoSignature = nil
        isPreparingPreviewVideo = false
        previewVideoPrepareProgress = 0
        previewVideoPrepareError = nil
    }

    private func selectPreviewRenderMode(_ mode: PreviewRenderMode) {
        guard mode != previewRenderMode else {
            if mode.isRenderedVideo {
                prepareRenderedPreviewVideo(thenPlay: false)
            }
            return
        }

        if previewRenderMode.isRenderedVideo {
            previewVideoPlayer?.pause()
        }

        previewRenderMode = mode

        if mode.isRenderedVideo {
            isPreviewPlaying = false
            audioPlayer?.pause()
            prepareRenderedPreviewVideo(thenPlay: false)
        }
    }

    // A cheap fingerprint of everything that affects the rendered pixels of
    // the preview video (photos, crops, theme, and all its timing knobs).
    // Compared against the signature the currently-prepared video was built
    // from, so switching a setting after preparing automatically triggers a
    // fresh render instead of silently playing a stale preview.
    private func currentPreviewVideoSignature() -> String {
        var pieces: [String] = [
            previewRenderMode.videoResolutionName,
            visualTheme.rawValue,
            transitionStyle.rawValue,
            String(format: "%.3f", fadeDuration),
            String(format: "%.3f", magazineImageFadeSeconds),
            String(format: "%.3f", magazineImageDelaySeconds),
            String(format: "%.3f", origamiInternalHoldSeconds),
            String(origamiImagesBeforePageChange),
            String(origamiSimultaneousSwapCount),
            String(format: "%.3f", currentPhotoDuration),
            String(format: "%.3f", musicFadeInSeconds),
            String(format: "%.3f", musicFadeOutSeconds)
        ]

        pieces.append(contentsOf: selectedPhotoURLs.map { $0.path })
        pieces.append(contentsOf: selectedMusicURLs.map { $0.path })

        for url in selectedPhotoURLs {
            if let crop = photoCropTransforms[url] {
                pieces.append("\(url.path)=\(crop.focusX)-\(crop.focusY)-\(crop.zoom)")
            }
        }

        return pieces.joined(separator: "|")
    }

    // Renders the current slideshow to a small 1080p video file, reusing the
    // exact same per-theme renderers the real export uses, then plays it
    // back with AVPlayer instead of the live timer-driven animation. Video
    // playback can't stutter the way real-time SwiftUI compositing can on
    // weak hardware, at the cost of a short one-time render before playback
    // starts. Opt-in via the FPS/Video toggle in the Preview card.
    private func prepareRenderedPreviewVideo(thenPlay: Bool) {
        guard !selectedPhotoURLs.isEmpty, !isPreparingPhotos else {
            return
        }

        let signature = currentPreviewVideoSignature()

        if signature == preparedPreviewVideoSignature,
           let existingURL = preparedPreviewVideoURL,
           FileManager.default.fileExists(atPath: existingURL.path) {
            if previewVideoPlayer == nil {
                previewVideoPlayer = AVPlayer(url: existingURL)
            }

            if thenPlay {
                previewVideoPlayer?.seek(to: .zero)
                previewVideoPlayer?.play()
            }

            return
        }

        guard !isPreparingPreviewVideo else {
            return
        }

        isPreparingPreviewVideo = true
        previewVideoPrepareProgress = 0
        previewVideoPrepareError = nil
        isPreviewPlaying = false
        audioPlayer?.pause()
        previewVideoPlayer?.pause()

        // Clear the stale player immediately rather than only on completion —
        // otherwise the UI sees previewVideoPlayer != nil the whole time this
        // re-render is in flight and keeps showing the previous render's
        // frozen last frame (e.g. a leftover Kousei video) instead of the
        // black "preparing…" state below.
        previewVideoPlayer = nil

        let previousURL = preparedPreviewVideoURL
        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BriefShow-preview-\(UUID().uuidString).mp4")

        let selectedResolutionName = previewRenderMode.videoResolutionName
        let photoURLs = selectedPhotoURLs
        let musicURLs = selectedMusicURLs
        let durationPerPhoto = max(0.25, currentPhotoDuration)
        let selectedTransitionStyle = transitionStyle
        let selectedFadeDuration = fadeDuration
        let selectedVisualTheme = visualTheme
        let selectedMagazineImageFade = magazineImageFadeSeconds
        let selectedMagazineImageDelay = magazineImageDelaySeconds
        let selectedPhotoCropTransforms = photoCropTransforms
        let selectedManualMagazineLayoutOverrides = manualMagazineLayoutOverrides
        let selectedManualOrigamiLayoutOverrides = manualOrigamiLayoutOverrides
        let selectedOrigamiHoldSeconds = origamiInternalHoldSeconds
        let selectedOrigamiImagesBeforePageChange = origamiImagesBeforePageChange
        let selectedOrigamiSimultaneousSwapCount = origamiSimultaneousSwapCount
        let selectedMusicFadeIn = musicFadeInSeconds
        let selectedMusicFadeOut = musicFadeOutSeconds

        let reportProgress: @Sendable (Double) -> Void = { rawProgress in
            let clamped = max(0, min(1, rawProgress))

            DispatchQueue.main.async {
                previewVideoPrepareProgress = clamped * (musicURLs.isEmpty ? 1 : 0.9)
            }
        }

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let videoOnlyURL = musicURLs.isEmpty ? cacheURL : temporaryVideoURL(for: cacheURL)

                if selectedVisualTheme == .magazine
                    || selectedVisualTheme == .magazine43
                    || selectedVisualTheme == .magazineFamily
                    || selectedVisualTheme == .magazineCouples {

                    try renderMagazineSlideshowVideo(
                        photoURLs: photoURLs,
                        outputURL: videoOnlyURL,
                        resolutionName: selectedResolutionName,
                        pageDuration: durationPerPhoto,
                        imageFadeSeconds: selectedMagazineImageFade,
                        imageDelaySeconds: selectedMagazineImageDelay,
                        revealStyle: selectedTransitionStyle,
                        cropTransforms: selectedPhotoCropTransforms,
                        manualLayoutOverrides: selectedManualMagazineLayoutOverrides,
                        isStrict43: selectedVisualTheme == .magazine43,
                        fileType: .mp4,
                        progressHandler: reportProgress
                    )
                } else if selectedVisualTheme == .origami || selectedVisualTheme == .origami43 {
                    try renderOrigamiSlideshowVideo(
                        photoURLs: photoURLs,
                        outputURL: videoOnlyURL,
                        resolutionName: selectedResolutionName,
                        pageDuration: selectedOrigamiHoldSeconds,
                        imagesBeforePageChange: selectedOrigamiImagesBeforePageChange,
                        simultaneousSwapCount: selectedOrigamiSimultaneousSwapCount,
                        cropTransforms: selectedPhotoCropTransforms,
                        manualLayoutOverrides: selectedManualOrigamiLayoutOverrides,
                        theme: selectedVisualTheme,
                        fileType: .mp4,
                        progressHandler: reportProgress
                    )
                } else if selectedVisualTheme == .imagination {
                    try renderImaginationSlideshowVideo(
                        photoURLs: photoURLs,
                        outputURL: videoOnlyURL,
                        resolutionName: selectedResolutionName,
                        pageDuration: durationPerPhoto,
                        fadeDuration: selectedFadeDuration,
                        fileType: .mp4,
                        progressHandler: reportProgress
                    )
                } else {
                    try renderSlideshowVideo(
                        photoURLs: photoURLs,
                        outputURL: videoOnlyURL,
                        resolutionName: selectedResolutionName,
                        secondsPerPhoto: durationPerPhoto,
                        transitionStyle: selectedTransitionStyle,
                        fadeDuration: selectedFadeDuration,
                        fileType: .mp4,
                        progressHandler: reportProgress
                    )
                }

                if !musicURLs.isEmpty {
                    DispatchQueue.main.async {
                        previewVideoPrepareProgress = 0.92
                    }

                    try muxVideoWithMusic(
                        videoURL: videoOnlyURL,
                        musicURLs: musicURLs,
                        outputURL: cacheURL,
                        outputFileType: .mp4,
                        fadeInSeconds: selectedMusicFadeIn,
                        fadeOutSeconds: selectedMusicFadeOut,
                        preferHEVC: false
                    )

                    try? FileManager.default.removeItem(at: videoOnlyURL)
                }

                DispatchQueue.main.async {
                    if let previousURL, previousURL != cacheURL {
                        try? FileManager.default.removeItem(at: previousURL)
                    }

                    previewVideoPrepareProgress = 1
                    isPreparingPreviewVideo = false
                    preparedPreviewVideoURL = cacheURL
                    preparedPreviewVideoSignature = signature
                    previewVideoPlayer = AVPlayer(url: cacheURL)

                    if thenPlay {
                        previewVideoPlayer?.play()
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    isPreparingPreviewVideo = false
                    previewVideoPrepareError = error.localizedDescription
                }
            }
        }
    }

    private func updateMagazinePhotoSeed(for urls: [URL]) {
        magazinePhotoSeed = urls.enumerated().reduce(0) { total, item in
            let nameScore = item.element.lastPathComponent.unicodeScalars.reduce(0) { partial, scalar in
                partial + Int(scalar.value)
            }

            return total + ((item.offset + 1) * nameScore)
        }
    }

    private func openPhotoPicker() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.resolvesAliases = true

        if panel.runModal() == .OK {
            importPhotoURLs(panel.urls)
        }
    }

    private func importPhotoURLs(_ urls: [URL]) {
        let sortedURLs = urls
            .filter { url in
                UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
            }
            .sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
            }

        guard !sortedURLs.isEmpty else {
            return
        }

        selectedPhotoURLs = sortedURLs
        previewImages = []
        preparedPhotoCount = 0
        isPreparingPhotos = true
        resetPreviewState()

        let preparationStartedAt = Date()

        DispatchQueue.global(qos: .userInitiated).async {
            var preparedURLs: [URL] = []
            var preparedImages: [NSImage] = []

            for url in sortedURLs {
                if let image = makePreviewImage(from: url) {
                    preparedURLs.append(url)
                    preparedImages.append(image)
                }

                let currentCount = preparedImages.count
                DispatchQueue.main.async {
                    preparedPhotoCount = currentCount
                }
            }

            DispatchQueue.main.async {
                let elapsed = Date().timeIntervalSince(preparationStartedAt)
                let remainingLoadingTime = max(0, 0.7 - elapsed)

                DispatchQueue.main.asyncAfter(deadline: .now() + remainingLoadingTime) {
                    // Keep selectedPhotoURLs and previewImages perfectly
                    // aligned by index — the rest of the app (crop lookup,
                    // drag reorder, active-photo tracking) assumes it.
                    selectedPhotoURLs = preparedURLs
                    previewImages = preparedImages
                    preparedPhotoCount = preparedImages.count
                    isPreparingPhotos = false
                    resetPreviewState()
                }
            }
        }
    }

    private func openMusicPicker(for slotIndex: Int) {
        pendingMusicSlotIndex = max(0, min(2, slotIndex))

        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.resolvesAliases = true

        if panel.runModal() == .OK {
            importMusicURLs(panel.urls, targetSlot: pendingMusicSlotIndex)
        }

        pendingMusicSlotIndex = nil
    }

    private func importMusicURLs(_ urls: [URL], targetSlot: Int? = nil) {
        let musicURLs = urls.filter { url in
            UTType(filenameExtension: url.pathExtension)?.conforms(to: .audio) == true
        }

        guard !musicURLs.isEmpty else {
            return
        }

        if let targetSlot {
            var updatedMusicURLs = selectedMusicURLs
            let safeStartIndex = min(max(0, targetSlot), updatedMusicURLs.count)

            for (offset, musicURL) in musicURLs.enumerated() {
                let slotIndex = safeStartIndex + offset

                guard slotIndex < 3 else {
                    break
                }

                if updatedMusicURLs.indices.contains(slotIndex) {
                    updatedMusicURLs[slotIndex] = musicURL
                } else {
                    updatedMusicURLs.append(musicURL)
                }
            }

            selectedMusicURLs = Array(updatedMusicURLs.prefix(3))
        } else {
            var updatedMusicURLs = selectedMusicURLs

            for musicURL in musicURLs where updatedMusicURLs.count < 3 {
                updatedMusicURLs.append(musicURL)
            }

            selectedMusicURLs = updatedMusicURLs
        }

        currentMusicIndex = 0
        currentMusicElapsedSeconds = 0
        prepareAudioPlayer(for: activeMusicURL)
        resetPreviewState()
    }

    private func openExportSavePanel() {
        guard !selectedPhotoURLs.isEmpty, !isPreparingPhotos else {
            exportStatusText = "Add photos before exporting."
            return
        }

        let isMOVExport = selectedExportFormat == "MOV"

        let panel = NSSavePanel()
        panel.allowedContentTypes = [isMOVExport ? .quickTimeMovie : .mpeg4Movie]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = "BriefShow-\(selectedExportResolution).\(isMOVExport ? "mov" : "mp4")"

        if panel.runModal() == .OK, let outputURL = panel.url {
            startVideoExport(to: outputURL)
        }
    }

    private func startVideoExport(to outputURL: URL) {
        guard !selectedPhotoURLs.isEmpty else {
            exportStatusText = "Add photos before exporting."
            return
        }

        isExportingVideo = true
        exportProgress = 0
        exportStatusText = "Rendering video… 0% · estimating time"
        isPreviewPlaying = false
        audioPlayer?.pause()

        let photoURLs = selectedPhotoURLs
        let musicURLs = selectedMusicURLs
        let resolution = selectedExportResolution
        let exportFileType: AVFileType = selectedExportFormat == "MOV" ? .mov : .mp4
        let durationPerPhoto = max(0.25, currentPhotoDuration)
        let selectedTransitionStyle = transitionStyle
        let selectedFadeDuration = fadeDuration
        let selectedVisualTheme = visualTheme
        let selectedMagazineImageFade =
            magazineImageFadeSeconds
        let selectedMagazineImageDelay =
            magazineImageDelaySeconds
        let selectedPhotoCropTransforms =
            photoCropTransforms
        let selectedManualMagazineLayoutOverrides =
            manualMagazineLayoutOverrides
        let selectedManualOrigamiLayoutOverrides =
            manualOrigamiLayoutOverrides
        let selectedOrigamiHoldSeconds =
            origamiInternalHoldSeconds

        let selectedOrigamiImagesBeforePageChange =
            origamiImagesBeforePageChange

        let selectedOrigamiSimultaneousSwapCount =
            origamiSimultaneousSwapCount
        let selectedMusicFadeIn = musicFadeInSeconds
        let selectedMusicFadeOut = musicFadeOutSeconds


        let exportStartedAt = Date()

        let reportRenderProgress:
            @Sendable (Double) -> Void = {
                rawProgress in

                let renderProgress = max(
                    0,
                    min(1, rawProgress)
                )

                DispatchQueue.main.async {
                    let overallProgress =
                        renderProgress
                        * (musicURLs.isEmpty ? 0.99 : 0.90)

                    exportProgress = overallProgress

                    let percent = Int(
                        round(overallProgress * 100)
                    )

                    let elapsed =
                        Date().timeIntervalSince(
                            exportStartedAt
                        )

                    if renderProgress > 0.025 {
                        let estimatedRenderTotal =
                            elapsed / renderProgress

                        let remainingRender =
                            max(
                                0,
                                estimatedRenderTotal - elapsed
                            )

                        exportStatusText =
                            "Rendering video… \(percent)% · about "
                            + formattedExportTime(
                                remainingRender
                            )
                            + " remaining"
                    } else {
                        exportStatusText =
                            "Rendering video… \(percent)% · estimating time"
                    }
                }
            }

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let videoOnlyURL = musicURLs.isEmpty ? outputURL : temporaryVideoURL(for: outputURL)

                if selectedVisualTheme == .magazine
                    || selectedVisualTheme == .magazine43
                    || selectedVisualTheme == .magazineFamily
                    || selectedVisualTheme == .magazineCouples {

                    try renderMagazineSlideshowVideo(
                        photoURLs: photoURLs,
                        outputURL: videoOnlyURL,
                        resolutionName: resolution,
                        pageDuration: durationPerPhoto,
                        imageFadeSeconds:
                            selectedMagazineImageFade,
                        imageDelaySeconds:
                            selectedMagazineImageDelay,
                        revealStyle:
                            selectedTransitionStyle,
                        cropTransforms:
                            selectedPhotoCropTransforms,
                        manualLayoutOverrides:
                            selectedManualMagazineLayoutOverrides,
                        isStrict43: selectedVisualTheme == .magazine43,
                        fileType: exportFileType,
                        progressHandler:
                            reportRenderProgress
                    )
                } else if selectedVisualTheme == .origami || selectedVisualTheme == .origami43 {
                    try renderOrigamiSlideshowVideo(
                        photoURLs: photoURLs,
                        outputURL: videoOnlyURL,
                        resolutionName: resolution,
                        pageDuration:
                            selectedOrigamiHoldSeconds,
                        imagesBeforePageChange:
                            selectedOrigamiImagesBeforePageChange,
                        simultaneousSwapCount:
                            selectedOrigamiSimultaneousSwapCount,
                        cropTransforms:
                            selectedPhotoCropTransforms,
                        manualLayoutOverrides:
                            selectedManualOrigamiLayoutOverrides,
                        theme: selectedVisualTheme,
                        fileType: exportFileType,
                        progressHandler:
                            reportRenderProgress
                    )
                } else if selectedVisualTheme == .imagination {
                    try renderImaginationSlideshowVideo(
                        photoURLs: photoURLs,
                        outputURL: videoOnlyURL,
                        resolutionName: resolution,
                        pageDuration: durationPerPhoto,
                        fadeDuration: selectedFadeDuration,
                        fileType: exportFileType,
                        progressHandler: reportRenderProgress
                    )
                } else {
                    try renderSlideshowVideo(
                        photoURLs: photoURLs,
                        outputURL: videoOnlyURL,
                        resolutionName: resolution,
                        secondsPerPhoto: durationPerPhoto,
                        transitionStyle:
                            selectedTransitionStyle,
                        fadeDuration:
                            selectedFadeDuration,
                        fileType: exportFileType,
                        progressHandler:
                            reportRenderProgress
                    )
                }

                if !musicURLs.isEmpty {
                    DispatchQueue.main.async {
                        exportProgress = 0.92
                        exportStatusText =
                            "Adding music… 92%"
                    }

                    let isOrigamiVideo =
                        selectedVisualTheme
                            == .origami

                    let shouldUseOrigamiHEVC =
                        isOrigamiVideo
                        && (
                            resolution == "Original"
                            || resolution == "4K"
                        )

                    try muxVideoWithMusic(
                        videoURL: videoOnlyURL,
                        musicURLs: musicURLs,
                        outputURL: outputURL,
                        outputFileType: exportFileType,
                        fadeInSeconds:
                            selectedMusicFadeIn,
                        fadeOutSeconds:
                            selectedMusicFadeOut,
                        preferHEVC:
                            shouldUseOrigamiHEVC
                            || (
                                !isOrigamiVideo
                                && resolution
                                    == "Original"
                            ),
                        forcedFrameRate:
                            isOrigamiVideo
                            ? 30
                            : nil,
                        forcedRenderSize:
                            isOrigamiVideo
                            ? origamiExportRenderSize(
                                for:
                                    resolution
                            )
                            : nil
                    )

                    try? FileManager.default.removeItem(at: videoOnlyURL)
                }

                DispatchQueue.main.async {
                    exportProgress = 0.99
                    exportStatusText = "Finalizing… 99%"
                }

                DispatchQueue.main.async {
                    exportProgress = 1
                    isExportingVideo = false
                    exportStatusText =
                        "Export complete · 100%: \(outputURL.lastPathComponent)"
                    ExportCounter.recordExport()
                }
            } catch {
                DispatchQueue.main.async {
                    exportProgress = 0
                    isExportingVideo = false
                    exportStatusText =
                        "Export failed: \(error.localizedDescription)"
                }
            }
        }
    }







    private func formattedExportTime(
        _ seconds: Double
    ) -> String {
        let roundedSeconds =
            max(
                1,
                Int(ceil(seconds))
            )

        if roundedSeconds < 60 {
            return "\(roundedSeconds) sec"
        }

        let minutes =
            roundedSeconds / 60

        let remainingSeconds =
            roundedSeconds % 60

        if remainingSeconds == 0 {
            return "\(minutes) min"
        }

        return "\(minutes) min \(remainingSeconds) sec"
    }

    private func prepareAudioPlayer(for url: URL?) {
        audioPlayer?.stop()

        guard let url else {
            audioPlayer = nil
            return
        }

        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.volume = 1
            player.numberOfLoops = selectedMusicURLs.count > 1 ? 0 : -1
            player.prepareToPlay()
            audioPlayer = player
        } catch {
            audioPlayer = nil
            print("Could not load audio file:", error.localizedDescription)
        }
    }
}



private enum MagazineExportPhotoShape {
    case landscape
    case portrait
    case square
}

private enum MagazineExportSlotShape {
    case wide
    case tall
    case flex
}

private struct MagazineExportPhoto {
    let url: URL
    let image: CGImage

    var aspectRatio: CGFloat {
        guard image.height > 0 else {
            return 1
        }

        return CGFloat(image.width)
            / CGFloat(image.height)
    }

    var shape: MagazineExportPhotoShape {
        if aspectRatio > 1.18 {
            return .landscape
        }

        if aspectRatio < 0.82 {
            return .portrait
        }

        return .square
    }
}

private struct MagazineExportPage {
    let photos: [MagazineExportPhoto]
    let layoutVariant: Int
    // Only meaningful for isStrict43 pages — layoutVariant above is resolved
    // via the non-strict magazine variant scheme (different shape/count of
    // choices), so a strict-4:3 page needs its own raw manual-override value
    // to feed into strict43GridLayout's own row-arrangement candidates.
    var strict43ManualVariant: Int?
}

private func magazineExportPhotoSeed(
    _ photos: [MagazineExportPhoto]
) -> Int {
    let value = photos.enumerated().reduce(0) {
        total,
        item in

        let nameScore =
            item.element.url.lastPathComponent
                .unicodeScalars
                .reduce(0) {
                    partial,
                    scalar in

                    partial + Int(scalar.value)
                }

        return total
            + (
                item.offset + 1
            )
            * nameScore
    }

    return abs(value)
}

private func plannedMagazineExportSlotCount(
    pageIndex: Int,
    remainingPhotos: Int,
    seed: Int,
    isStrict43: Bool = false
) -> Int {
    guard remainingPhotos > 0 else {
        return 0
    }

    if isStrict43 {
        // Mirrors plannedMagazineSlotCount's preview-side cycle — see its
        // comment. 2/3/4/6 each get an equal, straightforward 1-in-4 chance.
        let strict43Cycles = [
            [2, 3, 4, 6, 2, 3, 4, 6],
            [3, 4, 6, 2, 3, 4, 6, 2],
            [4, 6, 2, 3, 4, 6, 2, 3],
            [6, 2, 3, 4, 6, 2, 3, 4],
            [2, 4, 6, 3, 2, 4, 6, 3],
            [4, 6, 3, 2, 4, 6, 3, 2],
            [6, 3, 2, 4, 6, 3, 2, 4],
            [3, 2, 4, 6, 3, 2, 4, 6]
        ]

        let cycle = strict43Cycles[seed % strict43Cycles.count]
        let plannedCount = cycle[pageIndex % cycle.count]

        return min(plannedCount, remainingPhotos)
    }

    if pageIndex <= 0 {
        let choices = [2, 3, 4]

        return min(
            choices[
                seed % choices.count
            ],
            remainingPhotos
        )
    }

    let cycles = [
        [3, 5, 6, 4, 2],
        [4, 6, 5, 3, 2],
        [5, 3, 6, 2, 4],
        [6, 5, 4, 3, 2],
        [2, 4, 5, 6, 3],
    ]

    let cycle =
        cycles[
            seed % cycles.count
        ]

    let planned =
        cycle[
            (pageIndex - 1)
                % cycle.count
        ]

    return min(
        planned,
        remainingPhotos
    )
}

private func adaptiveMagazineExportSlotCount(
    plannedCount: Int,
    photos: [MagazineExportPhoto],
    remainingPhotos: Int,
    previousSlotCount: Int? = nil,
    isStrict43: Bool = false
) -> Int {
    let rawCount = rawAdaptiveMagazineExportSlotCount(
        plannedCount: plannedCount,
        photos: photos,
        remainingPhotos: remainingPhotos,
        isStrict43: isStrict43
    )

    guard !isStrict43 else {
        return rawCount
    }

    // Mirrors the anti-repeat nudge in adaptiveMagazineSlotCount (preview
    // side) so exported video never disagrees with what was previewed.
    guard let previousSlotCount, rawCount == previousSlotCount, remainingPhotos > rawCount else {
        return rawCount
    }

    let alternative = rawCount >= 6 ? 5 : rawCount + 1
    return min(alternative, remainingPhotos)
}

private func rawAdaptiveMagazineExportSlotCount(
    plannedCount: Int,
    photos: [MagazineExportPhoto],
    remainingPhotos: Int,
    isStrict43: Bool = false
) -> Int {
    guard plannedCount > 0 else {
        return 0
    }

    guard !isStrict43 else {
        // Mirrors rawAdaptiveMagazineSlotCount's preview-side check — see
        // its comment. A 4-photo grid only stays 4 when all 4 are
        // landscape; otherwise it needs the extra room a 6-photo grid gives.
        guard plannedCount == 4, remainingPhotos >= 6 else {
            return plannedCount
        }

        let candidateFourPhotos = Array(photos.prefix(4))
        guard candidateFourPhotos.count == 4 else {
            return plannedCount
        }

        // Match the strict43 export grid's own isLandscape boolean exactly
        // (aspectRatio >= 1, i.e. width >= height) — see line 5786.
        let allLandscape = candidateFourPhotos.allSatisfy { $0.aspectRatio >= 1 }

        return allLandscape ? plannedCount : 6
    }

    let candidatePhotos =
        Array(
            photos.prefix(
                plannedCount
            )
        )

    let portraitCount =
        candidatePhotos.filter {
            $0.aspectRatio < 0.82
        }.count

    let landscapeCount =
        candidatePhotos.filter {
            $0.aspectRatio > 1.18
        }.count

    let veryWideCount =
        candidatePhotos.filter {
            $0.aspectRatio > 1.55
        }.count

    if plannedCount >= 4,
       portraitCount >= 1,
       landscapeCount >= 3 {

        return min(
            3,
            remainingPhotos
        )
    }

    if plannedCount >= 5,
       veryWideCount >= 2 {

        return min(
            3,
            remainingPhotos
        )
    }

    if plannedCount >= 4,
       veryWideCount >= 3 {

        return min(
            2,
            remainingPhotos
        )
    }

    return plannedCount
}


private let magazineExportSRGBColorSpace =
    CGColorSpace(
        name: CGColorSpace.sRGB
    )
    ?? CGColorSpaceCreateDeviceRGB()

private let magazineExportCIContext =
    CIContext(
        options: [
            .workingColorSpace:
                magazineExportSRGBColorSpace,
            .outputColorSpace:
                magazineExportSRGBColorSpace,
            .cacheIntermediates:
                false,
        ]
    )

private func makeSDRExportCGImage(
    from url: URL
) -> CGImage? {
    var options:
        [CIImageOption: Any] = [
            .applyOrientationProperty:
                true,
        ]

    // Do not expand Apple gain-map photographs
    // into HDR. Use the normal SDR base image.
    if #available(macOS 14.0, *) {
        options[
            .expandToHDR
        ] = false
    }

    guard let image =
        CIImage(
            contentsOf: url,
            options: options
        )
    else {
        print(
            "BriefShow Core Image decode failed:",
            url.lastPathComponent
        )

        return nil
    }

    let extent =
        image.extent.integral

    guard extent.width > 0,
          extent.height > 0,
          extent.width.isFinite,
          extent.height.isFinite
    else {
        print(
            "BriefShow invalid image extent:",
            url.lastPathComponent,
            image.extent
        )

        return nil
    }

    guard let normalizedImage =
        magazineExportCIContext
            .createCGImage(
                image,
                from: extent,
                format: .RGBA8,
                colorSpace:
                    magazineExportSRGBColorSpace
            )
    else {
        print(
            "BriefShow SDR RGBA8 conversion failed:",
            url.lastPathComponent
        )

        return nil
    }

    print(
        "BriefShow SDR image:",
        url.lastPathComponent,
        normalizedImage.width,
        "x",
        normalizedImage.height,
        "bpc:",
        normalizedImage.bitsPerComponent,
        "bpp:",
        normalizedImage.bitsPerPixel
    )

    return normalizedImage
}


private func buildMagazineExportPages(
    photoURLs: [URL],
    manualLayoutOverrides: [Int: Int],
    isStrict43: Bool = false
) -> [MagazineExportPage] {
    let photos =
        photoURLs.compactMap {
            url -> MagazineExportPhoto? in

            guard let image =
                    makeSDRExportCGImage(
                        from: url
                    )
            else {
                return nil
            }

            return MagazineExportPhoto(
                url: url,
                image: image
            )
        }

    guard !photos.isEmpty else {
        return []
    }

    let seed =
        magazineExportPhotoSeed(
            photos
        )

    var pages: [MagazineExportPage] = []
    var pageIndex = 0
    var consumed = 0
    var previousSlotCount: Int? = nil

    while consumed < photos.count {
        let remaining =
            photos.count - consumed

        let planned =
            plannedMagazineExportSlotCount(
                pageIndex: pageIndex,
                remainingPhotos:
                    remaining,
                seed: seed,
                isStrict43: isStrict43
            )

        let availablePhotos =
            Array(
                photos[consumed...]
            )

        let slotCount = max(
            1,
            adaptiveMagazineExportSlotCount(
                plannedCount:
                    planned,
                photos:
                    availablePhotos,
                remainingPhotos:
                    remaining,
                previousSlotCount:
                    previousSlotCount,
                isStrict43: isStrict43
            )
        )

        let endIndex = min(
            photos.count,
            consumed + slotCount
        )

        guard consumed < endIndex else {
            break
        }

        let pagePhotos =
            Array(
                photos[
                    consumed..<endIndex
                ]
            )

        let portraitCount =
            pagePhotos.filter {
                $0.shape == .portrait
            }.count

        let landscapeCount =
            pagePhotos.filter {
                $0.shape == .landscape
            }.count

        let resolved =
            resolvedMagazineLayoutVariant(
                photoCount: pagePhotos.count,
                portraitCount: portraitCount,
                landscapeCount: landscapeCount,
                uniformTieBreakSeed: pageIndex,
                manualOverride: manualLayoutOverrides[pageIndex]
            )

        pages.append(
            MagazineExportPage(
                photos: pagePhotos,
                layoutVariant: resolved,
                strict43ManualVariant: manualLayoutOverrides[pageIndex]
            )
        )

        consumed = endIndex
        pageIndex += 1
        previousSlotCount = slotCount
    }

    return pages
}

private func magazineExportSlotShapes(
    for photos: [MagazineExportPhoto],
    resolvedVariant: Int
) -> [MagazineExportSlotShape] {
    switch (photos.count, resolvedVariant) {
    case (2, 0):
        return [.wide, .tall]
    case (2, _):
        return [.flex, .flex]

    case (3, 0):
        return [
            .tall,
            .tall,
            .flex,
        ]
    case (3, 1):
        return [
            .wide,
            .wide,
            .tall,
        ]
    case (3, _):
        return [
            .wide,
            .flex,
            .flex,
        ]

    case (4, 0):
        return [
            .tall,
            .tall,
            .wide,
            .wide,
        ]
    case (4, 1):
        return [
            .tall,
            .wide,
            .wide,
            .wide,
        ]
    case (4, _):
        return Array(
            repeating: .wide,
            count: 4
        )

    case (5, 0):
        return [
            .tall,
            .tall,
            .wide,
            .wide,
            .wide,
        ]
    case (5, 1):
        return [
            .tall,
            .wide,
            .wide,
            .wide,
            .wide,
        ]
    case (5, _):
        return Array(
            repeating: .wide,
            count: 5
        )

    default:
        switch resolvedVariant {
        case 0:
            return [
                .tall,
                .tall,
                .tall,
                .wide,
                .wide,
                .wide,
            ]

        case 1:
            return [
                .wide,
                .wide,
                .wide,
                .tall,
                .wide,
                .tall,
            ]

        case 2:
            return [
                .tall,
                .wide,
                .wide,
                .wide,
                .wide,
                .wide,
            ]

        default:
            return Array(
                repeating: .wide,
                count:
                    max(
                        1,
                        photos.count
                    )
            )
        }
    }
}

private func orderedMagazineExportPhotos(
    _ photos: [MagazineExportPhoto],
    resolvedVariant: Int
) -> [MagazineExportPhoto] {
    let portraitIndexes =
        photos.indices.filter {
            photos[$0].shape
                == .portrait
        }

    let landscapeIndexes =
        photos.indices.filter {
            photos[$0].shape
                == .landscape
        }

    let squareIndexes =
        photos.indices.filter {
            photos[$0].shape
                == .square
        }

    let allIndexes =
        Array(photos.indices)

    var used = Set<Int>()
    var result: [Int] = []

    func candidates(
        for shape:
            MagazineExportSlotShape
    ) -> [Int] {
        switch shape {
        case .wide:
            return landscapeIndexes
                + squareIndexes
                + portraitIndexes

        case .tall:
            return portraitIndexes
                + squareIndexes
                + landscapeIndexes

        case .flex:
            return allIndexes
        }
    }

    for slotShape in
        magazineExportSlotShapes(
            for: photos,
            resolvedVariant: resolvedVariant
        )
        .prefix(photos.count) {

        if let next =
            candidates(
                for: slotShape
            )
            .first(
                where: {
                    !used.contains($0)
                }
            ) {

            used.insert(next)
            result.append(next)
        }
    }

    for index in allIndexes
    where !used.contains(index) {
        result.append(index)
    }

    return result.map {
        photos[$0]
    }
}

private func magazineExportLayoutRects(
    page: MagazineExportPage,
    contentRect: CGRect,
    gap: CGFloat
) -> [CGRect] {
    let photos = page.photos

    guard !photos.isEmpty else {
        return []
    }

    let width =
        contentRect.width

    let height =
        contentRect.height

    func topRect(
        x: CGFloat,
        y: CGFloat,
        width: CGFloat,
        height: CGFloat
    ) -> CGRect {
        CGRect(
            x:
                contentRect.minX + x,
            y:
                contentRect.maxY
                - y
                - height,
            width:
                max(1, width),
            height:
                max(1, height)
        )
    }

    switch photos.count {
    case 1:
        return [
            contentRect,
        ]

    case 2:
        if page.layoutVariant == 0 {
            let leftWidth =
                (
                    width - gap
                ) * 0.64

            return [
                topRect(
                    x: 0,
                    y: 0,
                    width:
                        leftWidth,
                    height:
                        height
                ),
                topRect(
                    x:
                        leftWidth + gap,
                    y: 0,
                    width:
                        width
                        - leftWidth
                        - gap,
                    height:
                        height
                ),
            ]
        }

        let columnWidth =
            (
                width - gap
            ) / 2

        return [
            topRect(
                x: 0,
                y: 0,
                width:
                    columnWidth,
                height:
                    height
            ),
            topRect(
                x:
                    columnWidth + gap,
                y: 0,
                width:
                    columnWidth,
                height:
                    height
            ),
        ]

    case 3:
        if page.layoutVariant == 0 {
            let columnWidth =
                (
                    width
                    - gap * 2
                ) / 3

            return (0..<3).map {
                index in

                topRect(
                    x:
                        CGFloat(index)
                        * (
                            columnWidth
                            + gap
                        ),
                    y: 0,
                    width:
                        columnWidth,
                    height:
                        height
                )
            }
        }

        let largeWidth =
            (
                width - gap
            ) * 0.62

        let smallWidth =
            width
            - largeWidth
            - gap

        let halfHeight =
            (
                height - gap
            ) / 2

        if page.layoutVariant == 1 {
            return [
                topRect(
                    x: 0,
                    y: 0,
                    width:
                        largeWidth,
                    height:
                        halfHeight
                ),
                topRect(
                    x: 0,
                    y:
                        halfHeight + gap,
                    width:
                        largeWidth,
                    height:
                        halfHeight
                ),
                topRect(
                    x:
                        largeWidth + gap,
                    y: 0,
                    width:
                        smallWidth,
                    height:
                        height
                ),
            ]
        }

        return [
            topRect(
                x: 0,
                y: 0,
                width:
                    largeWidth,
                height:
                    height
            ),
            topRect(
                x:
                    largeWidth + gap,
                y: 0,
                width:
                    smallWidth,
                height:
                    halfHeight
            ),
            topRect(
                x:
                    largeWidth + gap,
                y:
                    halfHeight + gap,
                width:
                    smallWidth,
                height:
                    halfHeight
            ),
        ]

    case 4:
        if page.layoutVariant == 0 {
            let rightWidth =
                (
                    width
                    - gap * 2
                ) * 0.44

            let flexibleWidth =
                (
                    width
                    - gap * 2
                    - rightWidth
                ) / 2

            let halfHeight =
                (
                    height - gap
                ) / 2

            return [
                topRect(
                    x: 0,
                    y: 0,
                    width:
                        flexibleWidth,
                    height:
                        height
                ),
                topRect(
                    x:
                        flexibleWidth
                        + gap,
                    y: 0,
                    width:
                        flexibleWidth,
                    height:
                        height
                ),
                topRect(
                    x:
                        flexibleWidth
                        * 2
                        + gap * 2,
                    y: 0,
                    width:
                        rightWidth,
                    height:
                        halfHeight
                ),
                topRect(
                    x:
                        flexibleWidth
                        * 2
                        + gap * 2,
                    y:
                        halfHeight
                        + gap,
                    width:
                        rightWidth,
                    height:
                        halfHeight
                ),
            ]
        }

        if page.layoutVariant == 1 {
            let leftWidth =
                (
                    width - gap
                ) * 0.34

            let rightWidth =
                width
                - leftWidth
                - gap

            let rowHeight =
                (
                    height
                    - gap * 2
                ) / 3

            return [
                topRect(
                    x: 0,
                    y: 0,
                    width:
                        leftWidth,
                    height:
                        height
                ),
                topRect(
                    x:
                        leftWidth + gap,
                    y: 0,
                    width:
                        rightWidth,
                    height:
                        rowHeight
                ),
                topRect(
                    x:
                        leftWidth + gap,
                    y:
                        rowHeight + gap,
                    width:
                        rightWidth,
                    height:
                        rowHeight
                ),
                topRect(
                    x:
                        leftWidth + gap,
                    y:
                        (
                            rowHeight
                            + gap
                        ) * 2,
                    width:
                        rightWidth,
                    height:
                        rowHeight
                ),
            ]
        }

        if page.layoutVariant == 2 {
            let leftWidth =
                (
                    width - gap
                ) * 0.62

            let rightWidth =
                width
                - leftWidth
                - gap

            let rowHeight =
                (
                    height
                    - gap * 2
                ) / 3

            return [
                topRect(
                    x: 0,
                    y: 0,
                    width:
                        leftWidth,
                    height:
                        height
                ),
                topRect(
                    x:
                        leftWidth + gap,
                    y: 0,
                    width:
                        rightWidth,
                    height:
                        rowHeight
                ),
                topRect(
                    x:
                        leftWidth + gap,
                    y:
                        rowHeight + gap,
                    width:
                        rightWidth,
                    height:
                        rowHeight
                ),
                topRect(
                    x:
                        leftWidth + gap,
                    y:
                        (
                            rowHeight
                            + gap
                        ) * 2,
                    width:
                        rightWidth,
                    height:
                        rowHeight
                ),
            ]
        }

        let columnWidth =
            (
                width - gap
            ) / 2

        let rowHeight =
            (
                height - gap
            ) / 2

        return [
            topRect(
                x: 0,
                y: 0,
                width:
                    columnWidth,
                height:
                    rowHeight
            ),
            topRect(
                x:
                    columnWidth + gap,
                y: 0,
                width:
                    columnWidth,
                height:
                    rowHeight
            ),
            topRect(
                x: 0,
                y:
                    rowHeight + gap,
                width:
                    columnWidth,
                height:
                    rowHeight
            ),
            topRect(
                x:
                    columnWidth + gap,
                y:
                    rowHeight + gap,
                width:
                    columnWidth,
                height:
                    rowHeight
            ),
        ]

    case 5:
        if page.layoutVariant == 0 {
            let fixedWidth =
                (
                    width
                    - gap * 2
                ) * 0.26

            let rightWidth =
                width
                - gap * 2
                - fixedWidth * 2

            let halfHeight =
                (
                    height - gap
                ) / 2

            let rightHalfWidth =
                (
                    rightWidth - gap
                ) / 2

            let rightX =
                fixedWidth * 2
                + gap * 2

            return [
                topRect(
                    x: 0,
                    y: 0,
                    width:
                        fixedWidth,
                    height:
                        height
                ),
                topRect(
                    x:
                        fixedWidth + gap,
                    y: 0,
                    width:
                        fixedWidth,
                    height:
                        height
                ),
                topRect(
                    x:
                        rightX,
                    y: 0,
                    width:
                        rightWidth,
                    height:
                        halfHeight
                ),
                topRect(
                    x:
                        rightX,
                    y:
                        halfHeight + gap,
                    width:
                        rightHalfWidth,
                    height:
                        halfHeight
                ),
                topRect(
                    x:
                        rightX
                        + rightHalfWidth
                        + gap,
                    y:
                        halfHeight + gap,
                    width:
                        rightHalfWidth,
                    height:
                        halfHeight
                ),
            ]
        }

        if page.layoutVariant == 1 {
            let leftWidth =
                (
                    width - gap
                ) * 0.34

            let rightWidth =
                width
                - leftWidth
                - gap

            let columnWidth =
                (
                    rightWidth - gap
                ) / 2

            let rowHeight =
                (
                    height - gap
                ) / 2

            return [
                topRect(
                    x: 0,
                    y: 0,
                    width:
                        leftWidth,
                    height:
                        height
                ),
                topRect(
                    x:
                        leftWidth + gap,
                    y: 0,
                    width:
                        columnWidth,
                    height:
                        rowHeight
                ),
                topRect(
                    x:
                        leftWidth
                        + gap
                        + columnWidth
                        + gap,
                    y: 0,
                    width:
                        columnWidth,
                    height:
                        rowHeight
                ),
                topRect(
                    x:
                        leftWidth + gap,
                    y:
                        rowHeight + gap,
                    width:
                        columnWidth,
                    height:
                        rowHeight
                ),
                topRect(
                    x:
                        leftWidth
                        + gap
                        + columnWidth
                        + gap,
                    y:
                        rowHeight + gap,
                    width:
                        columnWidth,
                    height:
                        rowHeight
                ),
            ]
        }

        let topHeight =
            (
                height - gap
            ) * 0.48

        let bottomHeight =
            height
            - topHeight
            - gap

        let topWidth =
            (
                width
                - gap * 2
            ) / 3

        let bottomWidth =
            (
                width - gap
            ) / 2

        return [
            topRect(
                x: 0,
                y: 0,
                width:
                    topWidth,
                height:
                    topHeight
            ),
            topRect(
                x:
                    topWidth + gap,
                y: 0,
                width:
                    topWidth,
                height:
                    topHeight
            ),
            topRect(
                x:
                    (
                        topWidth
                        + gap
                    ) * 2,
                y: 0,
                width:
                    topWidth,
                height:
                    topHeight
            ),
            topRect(
                x: 0,
                y:
                    topHeight + gap,
                width:
                    bottomWidth,
                height:
                    bottomHeight
            ),
            topRect(
                x:
                    bottomWidth + gap,
                y:
                    topHeight + gap,
                width:
                    bottomWidth,
                height:
                    bottomHeight
            ),
        ]

    default:
        if page.layoutVariant == 0 {
            let rightWidth =
                (
                    width
                    - gap * 3
                ) * 0.34

            let columnWidth =
                (
                    width
                    - gap * 3
                    - rightWidth
                ) / 3

            let rightX =
                columnWidth * 3
                + gap * 3

            let rowHeight =
                (
                    height
                    - gap * 2
                ) / 3

            return [
                topRect(
                    x: 0,
                    y: 0,
                    width:
                        columnWidth,
                    height:
                        height
                ),
                topRect(
                    x:
                        columnWidth + gap,
                    y: 0,
                    width:
                        columnWidth,
                    height:
                        height
                ),
                topRect(
                    x:
                        (
                            columnWidth
                            + gap
                        ) * 2,
                    y: 0,
                    width:
                        columnWidth,
                    height:
                        height
                ),
                topRect(
                    x:
                        rightX,
                    y: 0,
                    width:
                        rightWidth,
                    height:
                        rowHeight
                ),
                topRect(
                    x:
                        rightX,
                    y:
                        rowHeight + gap,
                    width:
                        rightWidth,
                    height:
                        rowHeight
                ),
                topRect(
                    x:
                        rightX,
                    y:
                        (
                            rowHeight
                            + gap
                        ) * 2,
                    width:
                        rightWidth,
                    height:
                        rowHeight
                ),
            ]
        }

        if page.layoutVariant == 1 {
            let topHeight =
                (
                    height - gap
                ) * 0.48

            let bottomHeight =
                height
                - topHeight
                - gap

            let topWidth =
                (
                    width
                    - gap * 2
                ) / 3

            let fixedBottomWidth =
                (
                    width
                    - gap * 2
                ) * 0.25

            let centerBottomWidth =
                width
                - gap * 2
                - fixedBottomWidth * 2

            return [
                topRect(
                    x: 0,
                    y: 0,
                    width:
                        topWidth,
                    height:
                        topHeight
                ),
                topRect(
                    x:
                        topWidth + gap,
                    y: 0,
                    width:
                        topWidth,
                    height:
                        topHeight
                ),
                topRect(
                    x:
                        (
                            topWidth
                            + gap
                        ) * 2,
                    y: 0,
                    width:
                        topWidth,
                    height:
                        topHeight
                ),
                topRect(
                    x: 0,
                    y:
                        topHeight + gap,
                    width:
                        fixedBottomWidth,
                    height:
                        bottomHeight
                ),
                topRect(
                    x:
                        fixedBottomWidth
                        + gap,
                    y:
                        topHeight + gap,
                    width:
                        centerBottomWidth,
                    height:
                        bottomHeight
                ),
                topRect(
                    x:
                        fixedBottomWidth
                        + gap
                        + centerBottomWidth
                        + gap,
                    y:
                        topHeight + gap,
                    width:
                        fixedBottomWidth,
                    height:
                        bottomHeight
                ),
            ]
        }

        if page.layoutVariant == 2 {
            let leftWidth =
                (
                    width - gap
                ) * 0.28

            let rightWidth =
                width
                - leftWidth
                - gap

            let halfHeight =
                (
                    height - gap
                ) / 2

            let topWidth =
                (
                    rightWidth - gap
                ) / 2

            let bottomWidth =
                (
                    rightWidth
                    - gap * 2
                ) / 3

            let rightX =
                leftWidth + gap

            return [
                topRect(
                    x: 0,
                    y: 0,
                    width:
                        leftWidth,
                    height:
                        height
                ),
                topRect(
                    x:
                        rightX,
                    y: 0,
                    width:
                        topWidth,
                    height:
                        halfHeight
                ),
                topRect(
                    x:
                        rightX
                        + topWidth
                        + gap,
                    y: 0,
                    width:
                        topWidth,
                    height:
                        halfHeight
                ),
                topRect(
                    x:
                        rightX,
                    y:
                        halfHeight + gap,
                    width:
                        bottomWidth,
                    height:
                        halfHeight
                ),
                topRect(
                    x:
                        rightX
                        + bottomWidth
                        + gap,
                    y:
                        halfHeight + gap,
                    width:
                        bottomWidth,
                    height:
                        halfHeight
                ),
                topRect(
                    x:
                        rightX
                        + (
                            bottomWidth
                            + gap
                        ) * 2,
                    y:
                        halfHeight + gap,
                    width:
                        bottomWidth,
                    height:
                        halfHeight
                ),
            ]
        }

        if page.layoutVariant == 3 {
            let topHeight =
                (
                    height - gap
                ) * 0.35

            let bottomHeight =
                height
                - topHeight
                - gap

            let topWidth =
                (
                    width
                    - gap * 3
                ) / 4

            let bottomWidth =
                (
                    width - gap
                ) / 2

            return [
                topRect(
                    x: 0,
                    y: 0,
                    width:
                        topWidth,
                    height:
                        topHeight
                ),
                topRect(
                    x:
                        topWidth + gap,
                    y: 0,
                    width:
                        topWidth,
                    height:
                        topHeight
                ),
                topRect(
                    x:
                        (
                            topWidth
                            + gap
                        ) * 2,
                    y: 0,
                    width:
                        topWidth,
                    height:
                        topHeight
                ),
                topRect(
                    x:
                        (
                            topWidth
                            + gap
                        ) * 3,
                    y: 0,
                    width:
                        topWidth,
                    height:
                        topHeight
                ),
                topRect(
                    x: 0,
                    y:
                        topHeight + gap,
                    width:
                        bottomWidth,
                    height:
                        bottomHeight
                ),
                topRect(
                    x:
                        bottomWidth + gap,
                    y:
                        topHeight + gap,
                    width:
                        bottomWidth,
                    height:
                        bottomHeight
                ),
            ]
        }

        let leftWidth =
            (
                width - gap
            ) * 0.58

        let rightWidth =
            width
            - leftWidth
            - gap

        let rowHeight =
            (
                height
                - gap * 2
            ) / 3

        let halfRightWidth =
            (
                rightWidth - gap
            ) / 2

        let rightX =
            leftWidth + gap

        return [
            topRect(
                x: 0,
                y: 0,
                width:
                    leftWidth,
                height:
                    height
            ),
            topRect(
                x:
                    rightX,
                y: 0,
                width:
                    rightWidth,
                height:
                    rowHeight
            ),
            topRect(
                x:
                    rightX,
                y:
                    rowHeight + gap,
                width:
                    halfRightWidth,
                height:
                    rowHeight
            ),
            topRect(
                x:
                    rightX
                    + halfRightWidth
                    + gap,
                y:
                    rowHeight + gap,
                width:
                    halfRightWidth,
                height:
                    rowHeight
            ),
            topRect(
                x:
                    rightX,
                y:
                    (
                        rowHeight
                        + gap
                    ) * 2,
                width:
                    halfRightWidth,
                height:
                    rowHeight
            ),
            topRect(
                x:
                    rightX
                    + halfRightWidth
                    + gap,
                y:
                    (
                        rowHeight
                        + gap
                    ) * 2,
                width:
                    halfRightWidth,
                height:
                    rowHeight
            ),
        ]
    }
}

// Returns the vertical offset (SwiftUI-style: y increases downward) that a
// `.scaledToFill()` image should be shifted by so a person's head is not
// cropped away. Only applies when the crop trims top/bottom (a portrait
// photo placed in a wider slot) - left/right crops are left centered since
// they rarely cut through a face the same way.
private func headroomPreservingCropOffset(
    imageSize: CGSize,
    frameSize: CGSize,
    topCropFraction: CGFloat = 0.15
) -> CGFloat {
    guard imageSize.width > 0, imageSize.height > 0,
          frameSize.width > 0, frameSize.height > 0
    else {
        return 0
    }

    let imageAspect = imageSize.width / imageSize.height
    let frameAspect = frameSize.width / frameSize.height

    guard imageAspect <= frameAspect else {
        return 0
    }

    let drawHeight = frameSize.width / imageAspect
    let overflow = drawHeight - frameSize.height

    guard overflow > 0 else {
        return 0
    }

    return overflow * (0.5 - topCropFraction)
}

private func drawMagazineExportImage(
    _ image: CGImage,
    in rect: CGRect,
    alpha: CGFloat,
    shadowScale: CGFloat,
    crop: MagazinePhotoCrop,
    context: CGContext
) {
    guard rect.width > 0,
          rect.height > 0,
          alpha > 0
    else {
        return
    }

    let safeAlpha = max(
        0,
        min(1, alpha)
    )

    let imageWidth =
        CGFloat(image.width)

    let imageHeight =
        CGFloat(image.height)

    guard imageWidth > 0,
          imageHeight > 0
    else {
        return
    }

    let renderedSize =
        magazineCropRenderSize(
            imageSize: CGSize(width: imageWidth, height: imageHeight),
            frameSize: rect.size,
            zoom: CGFloat(crop.zoom)
        )

    // magazineCropOffset returns SwiftUI-convention offsets (y grows
    // downward), matching MagazineImageTile. CGContext's Y axis increases
    // upward, so the height component is negated here.
    let cropOffset =
        magazineCropOffset(
            imageSize: CGSize(width: imageWidth, height: imageHeight),
            frameSize: rect.size,
            crop: crop
        )

    let drawRect = CGRect(
        x:
            rect.midX
            - renderedSize.width / 2
            + cropOffset.width,
        y:
            rect.midY
            - renderedSize.height / 2
            - cropOffset.height,
        width:
            renderedSize.width,
        height:
            renderedSize.height
    )

    // Match MagazineImageTile Preview shadow.
    let hiddenAmount =
        1 - safeAlpha

    let revealShadowOpacity =
        0.085
        + hiddenAmount * 0.34

    let revealShadowRadius =
        1.4
        + hiddenAmount * 3.0

    let revealShadowXOffset =
        -2.2
        - hiddenAmount * 8.5

    let revealShadowYOffset =
        -0.8
        - hiddenAmount * 2.4

    let safeShadowScale =
        max(
            0.5,
            shadowScale
        )

    // Draw the rectangular tile shadow before clipping.
    // CGContext uses an inverted Y direction compared with SwiftUI.
    context.saveGState()

    context.setAlpha(
        safeAlpha
    )

    context.setShadow(
        offset: CGSize(
            width:
                revealShadowXOffset
                * safeShadowScale,
            height:
                -revealShadowYOffset
                * safeShadowScale
        ),
        blur:
            revealShadowRadius
            * safeShadowScale,
        color:
            NSColor.black
                .withAlphaComponent(
                    revealShadowOpacity
                )
                .cgColor
    )

    context.setFillColor(
        NSColor.black.cgColor
    )

    context.fill(rect)
    context.restoreGState()

    // Draw the photograph separately, clipped to its slot.
    context.saveGState()
    context.clip(to: rect)
    context.setAlpha(safeAlpha)
    context.interpolationQuality = .high

    context.draw(
        image,
        in: drawRect
    )

    context.restoreGState()
}

private func makeMagazineExportPixelBuffer(
    page: MagazineExportPage,
    localTime: Double,
    imageFadeSeconds: Double,
    imageDelaySeconds: Double,
    revealStyle: SlideshowTransitionStyle,
    cropTransforms: [URL: MagazinePhotoCrop],
    isStrict43: Bool = false,
    renderSize: CGSize,
    pixelBufferPool: CVPixelBufferPool?
) -> CVPixelBuffer? {
    guard let pixelBufferPool else {
        return nil
    }

    var pixelBuffer:
        CVPixelBuffer?

    let status =
        CVPixelBufferPoolCreatePixelBuffer(
            nil,
            pixelBufferPool,
            &pixelBuffer
        )

    guard status
            == kCVReturnSuccess,
          let pixelBuffer
    else {
        return nil
    }

    CVPixelBufferLockBaseAddress(
        pixelBuffer,
        []
    )

    defer {
        CVPixelBufferUnlockBaseAddress(
            pixelBuffer,
            []
        )
    }

    guard let context = CGContext(
        data:
            CVPixelBufferGetBaseAddress(
                pixelBuffer
            ),
        width:
            Int(renderSize.width),
        height:
            Int(renderSize.height),
        bitsPerComponent: 8,
        bytesPerRow:
            CVPixelBufferGetBytesPerRow(
                pixelBuffer
            ),
        space:
            CGColorSpaceCreateDeviceRGB(),
        bitmapInfo:
            CGImageAlphaInfo
                .premultipliedFirst
                .rawValue
            | CGBitmapInfo
                .byteOrder32Little
                .rawValue
    ) else {
        return nil
    }

    let canvasRect = CGRect(
        origin: .zero,
        size: renderSize
    )

    context.setFillColor(
        NSColor.black.cgColor
    )

    context.fill(canvasRect)

    let pageWidth = min(
        renderSize.width,
        renderSize.height * 16 / 9
    )

    let pageHeight =
        pageWidth * 9 / 16

    let pageRect = CGRect(
        x:
            (
                renderSize.width
                - pageWidth
            ) / 2,
        y:
            (
                renderSize.height
                - pageHeight
            ) / 2,
        width:
            pageWidth,
        height:
            pageHeight
    )

    context.setFillColor(
        NSColor.black.cgColor
    )

    context.fill(pageRect)

    let gap = max(
        10,
        min(
            20,
            pageWidth * 0.012
        )
    )

    let contentRect =
        pageRect.insetBy(
            dx: gap,
            dy: gap
        )

    let orderedPhotos: [MagazineExportPhoto]
    let rects: [CGRect]

    if isStrict43 {
        orderedPhotos = page.photos

        let strict43Rects = strict43GridLayout(
            isLandscape: page.photos.map { $0.aspectRatio >= 1 },
            pageWidth: contentRect.width,
            pageHeight: contentRect.height,
            gap: gap,
            manualVariant: page.strict43ManualVariant
        )

        rects = strict43Rects.map { rect in
            CGRect(
                x: contentRect.minX + rect.minX,
                y: contentRect.maxY - rect.minY - rect.height,
                width: rect.width,
                height: rect.height
            )
        }
    } else {
        orderedPhotos =
            orderedMagazineExportPhotos(
                page.photos,
                resolvedVariant: page.layoutVariant
            )

        rects =
            magazineExportLayoutRects(
                page: page,
                contentRect:
                    contentRect,
                gap: gap
            )
    }

    let fadeSeconds = max(
        0.05,
        imageFadeSeconds
    )

    let delaySeconds = max(
        0,
        imageDelaySeconds
    )

    // The strict-4:3 grid is scaled to cover the page (rather than fit
    // inside it), so it can slightly overflow contentRect on one axis —
    // clip so that overflow doesn't paint past the page edges.
    if isStrict43 {
        context.saveGState()
        context.clip(to: contentRect)
    }

    for index in
        0..<min(
            orderedPhotos.count,
            rects.count
        ) {

        let startTime =
            Double(index)
            * delaySeconds

        let elapsed =
            localTime
            - startTime

        let alpha: CGFloat

        if revealStyle == .blink {
            alpha = elapsed >= 0 ? 1 : 0
        } else {
            let rawAlpha = elapsed / fadeSeconds

            alpha = CGFloat(
                min(
                    1,
                    max(
                        0,
                        rawAlpha
                    )
                )
            )
        }

        drawMagazineExportImage(
            orderedPhotos[index].image,
            in: rects[index],
            alpha: alpha,
            shadowScale: max(
                0.5,
                pageWidth / 780
            ),
            crop: cropTransforms[orderedPhotos[index].url] ?? .default,
            context: context
        )
    }

    if isStrict43 {
        context.restoreGState()
    }

    return pixelBuffer
}

private func renderMagazineSlideshowVideo(
    photoURLs: [URL],
    outputURL: URL,
    resolutionName: String,
    pageDuration: Double,
    imageFadeSeconds: Double,
    imageDelaySeconds: Double,
    revealStyle: SlideshowTransitionStyle,
    cropTransforms: [URL: MagazinePhotoCrop],
    manualLayoutOverrides: [Int: Int],
    isStrict43: Bool = false,
    fileType: AVFileType = .mp4,
    progressHandler: @escaping @Sendable (Double) -> Void
) throws {
    if FileManager.default
        .fileExists(
            atPath:
                outputURL.path
        ) {

        try FileManager.default
            .removeItem(
                at: outputURL
            )
    }

    let pages =
        buildMagazineExportPages(
            photoURLs: photoURLs,
            manualLayoutOverrides: manualLayoutOverrides,
            isStrict43: isStrict43
        )

    guard !pages.isEmpty else {
        throw BriefShowExportError
            .couldNotCreatePixelBuffer
    }

    let requestedRenderSize =
        exportRenderSize(
            for:
                resolutionName,
            photoURLs:
                photoURLs
        )

    let renderSize: CGSize

    if resolutionName
        .trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        == "Original" {

        // Magazine Original is always full-screen UHD 4K.
        // Resolution is never reduced below 4K.
        renderSize = CGSize(
            width: 3840,
            height: 2160
        )
    } else {
        renderSize = requestedRenderSize
    }

    let fps: Int32 = 30

    let frameDuration =
        CMTime(
            value: 1,
            timescale: fps
        )

    let safePageDuration = max(
        0.25,
        pageDuration
    )

    let framesPerPage = max(
        1,
        Int(
            round(
                safePageDuration
                * Double(fps)
            )
        )
    )

    let writer =
        try AVAssetWriter(
            outputURL:
                outputURL,
            fileType:
                fileType
        )

    // H.264 is used for the Magazine renderer because
    // the macOS HEVC path can fail when source photos
    // contain HDR gain maps. Resolution remains 4K.
    let selectedCodec: AVVideoCodecType = .hevc

    let compressionProperties:
        [String: Any]

    if selectedCodec == .hevc {
        compressionProperties = [
            AVVideoAverageBitRateKey:
                exportBitrate(
                    for:
                        renderSize
                ),
            AVVideoMaxKeyFrameIntervalKey:
                30,
            AVVideoExpectedSourceFrameRateKey:
                30,
        ]
    } else {
        compressionProperties = [
            AVVideoAverageBitRateKey:
                exportBitrate(
                    for:
                        renderSize
                ),
            AVVideoProfileLevelKey:
                AVVideoProfileLevelH264HighAutoLevel,
            AVVideoMaxKeyFrameIntervalKey:
                30,
            AVVideoExpectedSourceFrameRateKey:
                30,
        ]
    }

    let videoSettings:
        [String: Any] = [
            AVVideoCodecKey:
                selectedCodec,
            AVVideoWidthKey:
                Int(
                    renderSize.width
                ),
            AVVideoHeightKey:
                Int(
                    renderSize.height
                ),
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey:
                    AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey:
                    AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey:
                    AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey:
                compressionProperties,
        ]

    print(
        "BriefShow Magazine export codec:",
        selectedCodec.rawValue,
        "resolution:",
        resolutionName,
        "pages:",
        pages.count
    )

    guard writer.canApply(
        outputSettings:
            videoSettings,
        forMediaType:
            .video
    ) else {
        throw BriefShowExportError
            .cannotAddVideoInput
    }

    let input =
        AVAssetWriterInput(
            mediaType:
                .video,
            outputSettings:
                videoSettings
        )

    input.expectsMediaDataInRealTime =
        false

    let pixelBufferAttributes:
        [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey
                as String:
                kCVPixelFormatType_32BGRA,

            kCVPixelBufferWidthKey
                as String:
                Int(
                    renderSize.width
                ),

            kCVPixelBufferHeightKey
                as String:
                Int(
                    renderSize.height
                ),

            kCVPixelBufferCGImageCompatibilityKey
                as String:
                true,

            kCVPixelBufferCGBitmapContextCompatibilityKey
                as String:
                true,

            kCVPixelBufferIOSurfacePropertiesKey
                as String:
                [String: Any](),

            kCVPixelBufferMetalCompatibilityKey
                as String:
                true,
        ]

    let adaptor =
        AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput:
                input,
            sourcePixelBufferAttributes:
                pixelBufferAttributes
        )

    guard writer.canAdd(input) else {
        throw BriefShowExportError
            .cannotAddVideoInput
    }

    writer.add(input)

    guard writer.startWriting() else {
        throw writer.error
            ?? BriefShowExportError
                .couldNotStartWriter
    }

    writer.startSession(
        atSourceTime: .zero
    )

    let totalMagazineFrameCount =
        max(
            1,
            pages.count * framesPerPage
        )

    var frameNumber: Int64 = 0

    for (pageIndex, page) in pages.enumerated() {
        for frameIndex
        in 0..<framesPerPage {

            while !input
                .isReadyForMoreMediaData {

                Thread.sleep(
                    forTimeInterval:
                        0.01
                )
            }

            let localTime =
                Double(frameIndex)
                / Double(fps)

            guard let pixelBuffer =
                makeMagazineExportPixelBuffer(
                    page: page,
                    localTime:
                        localTime,
                    imageFadeSeconds:
                        imageFadeSeconds,
                    imageDelaySeconds:
                        imageDelaySeconds,
                    revealStyle:
                        revealStyle,
                    cropTransforms:
                        cropTransforms,
                    isStrict43:
                        isStrict43,
                    renderSize:
                        renderSize,
                    pixelBufferPool:
                        adaptor.pixelBufferPool
                )
            else {
                throw BriefShowExportError
                    .couldNotCreatePixelBuffer
            }

            // Magazine export only: final 3-second black alpha fade.
            // This does not change FPS, page duration or frame count.
            if pageIndex == pages.count - 1 {
                let requestedFadeFrames = max(
                    1,
                    Int(round(3.0 * Double(fps)))
                )
            
                let exportFadeFrames = min(
                    framesPerPage,
                    requestedFadeFrames
                )
            
                let exportFadeStartFrame = max(
                    0,
                    framesPerPage - exportFadeFrames
                )
            
                if frameIndex >= exportFadeStartFrame {
                    let fadeFrameIndex =
                        frameIndex - exportFadeStartFrame
            
                    let linearProgress = Double(fadeFrameIndex)
                        / Double(max(1, exportFadeFrames - 1))
            
                    let clampedProgress = max(
                        0.0,
                        min(1.0, linearProgress)
                    )
            
                    let smoothAlpha =
                        clampedProgress
                        * clampedProgress
                        * (3.0 - 2.0 * clampedProgress)
            
                    let brightness = Float(1.0 - smoothAlpha)
            
                    let pixelFormat =
                        CVPixelBufferGetPixelFormatType(
                            pixelBuffer
                        )
            
                    if pixelFormat == kCVPixelFormatType_32BGRA {
                        CVPixelBufferLockBaseAddress(
                            pixelBuffer,
                            []
                        )
            
                        if let baseAddress =
                            CVPixelBufferGetBaseAddress(
                                pixelBuffer
                            ) {
                            let width =
                                CVPixelBufferGetWidth(
                                    pixelBuffer
                                )
                            let height =
                                CVPixelBufferGetHeight(
                                    pixelBuffer
                                )
                            let bytesPerRow =
                                CVPixelBufferGetBytesPerRow(
                                    pixelBuffer
                                )
                            let pixels =
                                baseAddress.assumingMemoryBound(
                                    to: UInt8.self
                                )
            
                            for row in 0..<height {
                                let rowAddress =
                                    pixels.advanced(
                                        by: row * bytesPerRow
                                    )
            
                                for column in 0..<width {
                                    let pixel =
                                        rowAddress.advanced(
                                            by: column * 4
                                        )
            
                                    pixel[0] = UInt8(
                                        Float(pixel[0]) * brightness
                                    )
                                    pixel[1] = UInt8(
                                        Float(pixel[1]) * brightness
                                    )
                                    pixel[2] = UInt8(
                                        Float(pixel[2]) * brightness
                                    )
                                }
                            }
                        }
            
                        CVPixelBufferUnlockBaseAddress(
                            pixelBuffer,
                            []
                        )
            
                        if fadeFrameIndex == 0 {
                            print(
                                "BriefShow Magazine export inline fade started.",
                                "frames:",
                                exportFadeFrames
                            )
                        }
            
                        if fadeFrameIndex == exportFadeFrames - 1 {
                            print(
                                "BriefShow Magazine export inline fade reached black."
                            )
                        }
                    } else if fadeFrameIndex == 0 {
                        print(
                            "BriefShow Magazine export fade unsupported format:",
                            pixelFormat
                        )
                    }
                }
            }
            
            let presentationTime =
                CMTimeMultiply(
                    frameDuration,
                    multiplier:
                        Int32(
                            frameNumber
                        )
                )

            guard adaptor.append(
                pixelBuffer,
                withPresentationTime:
                    presentationTime
            ) else {
                print(
                    "BriefShow Magazine append failed.",
                    "frame:",
                    frameNumber,
                    "page frame:",
                    frameIndex,
                    "writer status:",
                    writer.status.rawValue,
                    "writer error:",
                    writer.error?.localizedDescription
                        ?? "nil",
                    "underlying:",
                    String(
                        describing:
                            writer.error
                    )
                )

                throw writer.error
                    ?? BriefShowExportError
                        .couldNotAppendFrame
            }

            frameNumber += 1

            progressHandler(
                min(
                    1,
                    Double(frameNumber)
                    / Double(totalMagazineFrameCount)
                )
            )
        }
    }

    input.markAsFinished()

    let semaphore =
        DispatchSemaphore(
            value: 0
        )

    writer.finishWriting {
        semaphore.signal()
    }

    semaphore.wait()

    if writer.status == .failed {
        print(
            "BriefShow Magazine finish failed.",
            "status:",
            writer.status.rawValue,
            "error:",
            writer.error?.localizedDescription
                ?? "nil",
            "underlying:",
            String(
                describing:
                    writer.error
            )
        )

        throw writer.error
            ?? BriefShowExportError
                .writerFailed
    }

    print(
        "BriefShow Magazine video completed.",
        Int(renderSize.width),
        "x",
        Int(renderSize.height),
        "frames:",
        frameNumber
    )
}



private struct OrigamiExportPhoto {
    let image: CGImage

    var aspectRatio: CGFloat {
        guard image.height > 0 else {
            return 1
        }

        return CGFloat(image.width)
            / CGFloat(image.height)
    }

    var isPortrait: Bool {
        aspectRatio < 0.90
    }

    var isLandscape: Bool {
        aspectRatio > 1.15
    }
}

private struct OrigamiExportPage {
    let photos: [OrigamiExportPhoto]
    let pageIndex: Int
}

private func buildOrigamiExportPages(
    photoURLs: [URL]
) -> [OrigamiExportPage] {
    let loadedPhotos =
        photoURLs.compactMap { url in
            makeCGImage(from: url).map {
                OrigamiExportPhoto(image: $0)
            }
        }

    guard !loadedPhotos.isEmpty else {
        return []
    }

    let cycle = [3, 5, 6, 2, 4]

    var pages: [OrigamiExportPage] = []
    var photoIndex = 0
    var pageIndex = 0

    while photoIndex < loadedPhotos.count {
        let remaining =
            loadedPhotos.count - photoIndex

        var slotCount = min(
            cycle[pageIndex % cycle.count],
            remaining
        )

        // Match the Preview planning rule:
        // avoid leaving one photo alone on the next page.
        if remaining - slotCount == 1,
           slotCount > 2 {
            slotCount -= 1
        }

        slotCount = max(
            1,
            min(6, slotCount)
        )

        let endIndex = min(
            loadedPhotos.count,
            photoIndex + slotCount
        )

        pages.append(
            OrigamiExportPage(
                photos: Array(
                    loadedPhotos[
                        photoIndex..<endIndex
                    ]
                ),
                pageIndex: pageIndex
            )
        )

        photoIndex = endIndex
        pageIndex += 1
    }

    return pages
}

private func origamiExportMismatchScore(
    imageAspect: CGFloat,
    slotAspect: CGFloat
) -> CGFloat {
    let safeImageAspect =
        max(0.01, imageAspect)

    let safeSlotAspect =
        max(0.01, slotAspect)

    var score = max(
        safeImageAspect / safeSlotAspect,
        safeSlotAspect / safeImageAspect
    ) - 1

    let imageIsPortrait =
        safeImageAspect < 0.90

    let imageIsLandscape =
        safeImageAspect > 1.15

    let slotIsPortrait =
        safeSlotAspect < 0.90

    let slotIsLandscape =
        safeSlotAspect > 1.15

    if imageIsPortrait && slotIsLandscape {
        score += 2.4
    }

    if imageIsLandscape && slotIsPortrait {
        score += 2.4
    }

    if safeImageAspect > 2.0
        && safeSlotAspect < 1.25 {
        score += 1.4
    }

    if safeImageAspect < 0.65
        && safeSlotAspect > 1.0 {
        score += 1.4
    }

    return score
}

private func bestOrigamiExportPhotoOrder(
    photos: [OrigamiExportPhoto],
    rects: [CGRect]
) -> [OrigamiExportPhoto] {
    let count = min(
        photos.count,
        rects.count
    )

    guard count > 1 else {
        return photos
    }

    var bestOrder =
        Array(0..<count)

    var bestScore =
        CGFloat.greatestFiniteMagnitude

    var currentOrder: [Int] = []

    var used = Array(
        repeating: false,
        count: count
    )

    func search(
        slotIndex: Int,
        runningScore: CGFloat
    ) {
        if runningScore >= bestScore {
            return
        }

        if slotIndex == count {
            bestScore = runningScore
            bestOrder = currentOrder
            return
        }

        let rect = rects[slotIndex]

        let targetAspect =
            max(
                0.01,
                rect.width
                    / max(1, rect.height)
            )

        for imageIndex in 0..<count {
            guard !used[imageIndex] else {
                continue
            }

            var score =
                origamiExportMismatchScore(
                    imageAspect:
                        photos[imageIndex]
                            .aspectRatio,
                    slotAspect:
                        targetAspect
                )

            score += CGFloat(
                abs(imageIndex - slotIndex)
            ) * 0.001

            used[imageIndex] = true
            currentOrder.append(imageIndex)

            search(
                slotIndex: slotIndex + 1,
                runningScore:
                    runningScore + score
            )

            currentOrder.removeLast()
            used[imageIndex] = false
        }
    }

    search(
        slotIndex: 0,
        runningScore: 0
    )

    return bestOrder.map {
        photos[$0]
    }
}

private func origamiExportTopRect(
    pageRect: CGRect,
    x: CGFloat,
    y: CGFloat,
    width: CGFloat,
    height: CGFloat
) -> CGRect {
    CGRect(
        x: pageRect.minX + x,
        y:
            pageRect.maxY
            - y
            - height,
        width: width,
        height: height
    )
}

private func origamiExportLayoutRects(
    photos: [OrigamiExportPhoto],
    pageRect: CGRect
) -> [CGRect] {
    let count = photos.count

    guard count > 0 else {
        return []
    }

    let width = pageRect.width
    let height = pageRect.height

    let portraitCount =
        photos.filter {
            $0.isPortrait
        }.count

    let landscapeCount =
        photos.filter {
            $0.isLandscape
        }.count

    switch count {
    case 1:
        return [pageRect]

    case 2:
        if portraitCount == 2 {
            return [
                origamiExportTopRect(
                    pageRect: pageRect,
                    x: 0,
                    y: 0,
                    width: width * 0.5,
                    height: height
                ),
                origamiExportTopRect(
                    pageRect: pageRect,
                    x: width * 0.5,
                    y: 0,
                    width: width * 0.5,
                    height: height
                ),
            ]
        }

        if landscapeCount == 2 {
            return [
                origamiExportTopRect(
                    pageRect: pageRect,
                    x: 0,
                    y: 0,
                    width: width,
                    height: height * 0.5
                ),
                origamiExportTopRect(
                    pageRect: pageRect,
                    x: 0,
                    y: height * 0.5,
                    width: width,
                    height: height * 0.5
                ),
            ]
        }

        return [
            origamiExportTopRect(
                pageRect: pageRect,
                x: 0,
                y: 0,
                width: width * 0.38,
                height: height
            ),
            origamiExportTopRect(
                pageRect: pageRect,
                x: width * 0.38,
                y: 0,
                width: width * 0.62,
                height: height
            ),
        ]

    case 3:
        if portraitCount == 3 {
            return [
                origamiExportTopRect(
                    pageRect: pageRect,
                    x: 0,
                    y: 0,
                    width: width / 3,
                    height: height
                ),
                origamiExportTopRect(
                    pageRect: pageRect,
                    x: width / 3,
                    y: 0,
                    width: width / 3,
                    height: height
                ),
                origamiExportTopRect(
                    pageRect: pageRect,
                    x: width * 2 / 3,
                    y: 0,
                    width: width / 3,
                    height: height
                ),
            ]
        }

        if landscapeCount == 3 {
            return [
                origamiExportTopRect(
                    pageRect: pageRect,
                    x: 0,
                    y: 0,
                    width: width * 0.60,
                    height: height
                ),
                origamiExportTopRect(
                    pageRect: pageRect,
                    x: width * 0.60,
                    y: 0,
                    width: width * 0.40,
                    height: height * 0.5
                ),
                origamiExportTopRect(
                    pageRect: pageRect,
                    x: width * 0.60,
                    y: height * 0.5,
                    width: width * 0.40,
                    height: height * 0.5
                ),
            ]
        }

        return [
            origamiExportTopRect(
                pageRect: pageRect,
                x: 0,
                y: 0,
                width: width * 0.34,
                height: height
            ),
            origamiExportTopRect(
                pageRect: pageRect,
                x: width * 0.34,
                y: 0,
                width: width * 0.66,
                height: height * 0.5
            ),
            origamiExportTopRect(
                pageRect: pageRect,
                x: width * 0.34,
                y: height * 0.5,
                width: width * 0.66,
                height: height * 0.5
            ),
        ]

    case 4:
        if portraitCount >= 2 {
            return [
                origamiExportTopRect(
                    pageRect: pageRect,
                    x: 0,
                    y: 0,
                    width: width * 0.24,
                    height: height
                ),
                origamiExportTopRect(
                    pageRect: pageRect,
                    x: width * 0.24,
                    y: 0,
                    width: width * 0.52,
                    height: height * 0.5
                ),
                origamiExportTopRect(
                    pageRect: pageRect,
                    x: width * 0.24,
                    y: height * 0.5,
                    width: width * 0.52,
                    height: height * 0.5
                ),
                origamiExportTopRect(
                    pageRect: pageRect,
                    x: width * 0.76,
                    y: 0,
                    width: width * 0.24,
                    height: height
                ),
            ]
        }

        return [
            origamiExportTopRect(
                pageRect: pageRect,
                x: 0,
                y: 0,
                width: width * 0.5,
                height: height * 0.5
            ),
            origamiExportTopRect(
                pageRect: pageRect,
                x: width * 0.5,
                y: 0,
                width: width * 0.5,
                height: height * 0.5
            ),
            origamiExportTopRect(
                pageRect: pageRect,
                x: 0,
                y: height * 0.5,
                width: width * 0.5,
                height: height * 0.5
            ),
            origamiExportTopRect(
                pageRect: pageRect,
                x: width * 0.5,
                y: height * 0.5,
                width: width * 0.5,
                height: height * 0.5
            ),
        ]

    case 5:
        if portraitCount >= 1 {
            return [
                origamiExportTopRect(
                    pageRect: pageRect,
                    x: 0,
                    y: 0,
                    width: width * 0.28,
                    height: height
                ),
                origamiExportTopRect(
                    pageRect: pageRect,
                    x: width * 0.28,
                    y: 0,
                    width: width * 0.36,
                    height: height * 0.5
                ),
                origamiExportTopRect(
                    pageRect: pageRect,
                    x: width * 0.64,
                    y: 0,
                    width: width * 0.36,
                    height: height * 0.5
                ),
                origamiExportTopRect(
                    pageRect: pageRect,
                    x: width * 0.28,
                    y: height * 0.5,
                    width: width * 0.36,
                    height: height * 0.5
                ),
                origamiExportTopRect(
                    pageRect: pageRect,
                    x: width * 0.64,
                    y: height * 0.5,
                    width: width * 0.36,
                    height: height * 0.5
                ),
            ]
        }

        return [
            origamiExportTopRect(
                pageRect: pageRect,
                x: 0,
                y: 0,
                width: width * 0.5,
                height: height * 0.62
            ),
            origamiExportTopRect(
                pageRect: pageRect,
                x: width * 0.5,
                y: 0,
                width: width * 0.5,
                height: height * 0.62
            ),
            origamiExportTopRect(
                pageRect: pageRect,
                x: 0,
                y: height * 0.62,
                width: width / 3,
                height: height * 0.38
            ),
            origamiExportTopRect(
                pageRect: pageRect,
                x: width / 3,
                y: height * 0.62,
                width: width / 3,
                height: height * 0.38
            ),
            origamiExportTopRect(
                pageRect: pageRect,
                x: width * 2 / 3,
                y: height * 0.62,
                width: width / 3,
                height: height * 0.38
            ),
        ]

    default:
        if portraitCount >= 2 {
            return [
                origamiExportTopRect(
                    pageRect: pageRect,
                    x: 0,
                    y: 0,
                    width: width * 0.22,
                    height: height
                ),
                origamiExportTopRect(
                    pageRect: pageRect,
                    x: width * 0.22,
                    y: 0,
                    width: width * 0.28,
                    height: height * 0.5
                ),
                origamiExportTopRect(
                    pageRect: pageRect,
                    x: width * 0.50,
                    y: 0,
                    width: width * 0.28,
                    height: height * 0.5
                ),
                origamiExportTopRect(
                    pageRect: pageRect,
                    x: width * 0.22,
                    y: height * 0.5,
                    width: width * 0.28,
                    height: height * 0.5
                ),
                origamiExportTopRect(
                    pageRect: pageRect,
                    x: width * 0.50,
                    y: height * 0.5,
                    width: width * 0.28,
                    height: height * 0.5
                ),
                origamiExportTopRect(
                    pageRect: pageRect,
                    x: width * 0.78,
                    y: 0,
                    width: width * 0.22,
                    height: height
                ),
            ]
        }

        if portraitCount == 1 {
            return [
                origamiExportTopRect(
                    pageRect: pageRect,
                    x: 0,
                    y: 0,
                    width: width * 0.26,
                    height: height
                ),
                origamiExportTopRect(
                    pageRect: pageRect,
                    x: width * 0.26,
                    y: 0,
                    width: width * 0.37,
                    height: height * 0.5
                ),
                origamiExportTopRect(
                    pageRect: pageRect,
                    x: width * 0.63,
                    y: 0,
                    width: width * 0.37,
                    height: height * 0.5
                ),
                origamiExportTopRect(
                    pageRect: pageRect,
                    x: width * 0.26,
                    y: height * 0.5,
                    width: width * 0.2466667,
                    height: height * 0.5
                ),
                origamiExportTopRect(
                    pageRect: pageRect,
                    x: width * 0.5066667,
                    y: height * 0.5,
                    width: width * 0.2466667,
                    height: height * 0.5
                ),
                origamiExportTopRect(
                    pageRect: pageRect,
                    x: width * 0.7533334,
                    y: height * 0.5,
                    width: width * 0.2466666,
                    height: height * 0.5
                ),
            ]
        }

        return [
            origamiExportTopRect(
                pageRect: pageRect,
                x: 0,
                y: 0,
                width: width / 3,
                height: height * 0.5
            ),
            origamiExportTopRect(
                pageRect: pageRect,
                x: width / 3,
                y: 0,
                width: width / 3,
                height: height * 0.5
            ),
            origamiExportTopRect(
                pageRect: pageRect,
                x: width * 2 / 3,
                y: 0,
                width: width / 3,
                height: height * 0.5
            ),
            origamiExportTopRect(
                pageRect: pageRect,
                x: 0,
                y: height * 0.5,
                width: width / 3,
                height: height * 0.5
            ),
            origamiExportTopRect(
                pageRect: pageRect,
                x: width / 3,
                y: height * 0.5,
                width: width / 3,
                height: height * 0.5
            ),
            origamiExportTopRect(
                pageRect: pageRect,
                x: width * 2 / 3,
                y: height * 0.5,
                width: width / 3,
                height: height * 0.5
            ),
        ]
    }
}

private func drawOrigamiExportImage(
    _ image: CGImage,
    in rect: CGRect,
    context: CGContext
) {
    guard rect.width > 0,
          rect.height > 0,
          image.width > 0,
          image.height > 0
    else {
        return
    }

    let imageAspect =
        CGFloat(image.width)
        / CGFloat(image.height)

    let rectAspect =
        rect.width / rect.height

    let drawRect: CGRect

    if imageAspect > rectAspect {
        let drawHeight = rect.height
        let drawWidth =
            drawHeight * imageAspect

        drawRect = CGRect(
            x:
                rect.midX
                - drawWidth / 2,
            y: rect.minY,
            width: drawWidth,
            height: drawHeight
        )
    } else {
        let drawWidth = rect.width
        let drawHeight =
            drawWidth / imageAspect

        // CGContext's Y axis increases upward, so subtracting the
        // headroom offset shifts the drawn image down, preserving
        // more of its top (where a head usually is) from being clipped.
        let headroomOffset =
            headroomPreservingCropOffset(
                imageSize: CGSize(width: CGFloat(image.width), height: CGFloat(image.height)),
                frameSize: rect.size
            )

        drawRect = CGRect(
            x: rect.minX,
            y:
                rect.midY
                - drawHeight / 2
                - headroomOffset,
            width: drawWidth,
            height: drawHeight
        )
    }

    context.saveGState()
    context.clip(to: rect)
    context.interpolationQuality = .high

    context.draw(
        image,
        in: drawRect
    )

    context.restoreGState()
}


private struct OrigamiSwiftUIExportSwapBatch {
    let images: [Int: NSImage]
    let styles: [Int: Int]
}

private struct OrigamiSwiftUIExportPage {
    let baseImages: [NSImage]
    var theme: SlideshowVisualTheme = .origami
    let swapBatches:
        [OrigamiSwiftUIExportSwapBatch]
    let finalReplacements:
        [Int: NSImage]
    let pageIndex: Int
    let manualLayoutVariant: Int?
}

private enum OrigamiSwiftUIExportSegmentKind {
    case initialReveal
    case hold
    case swap(Int)
    case pageFold
}

private struct OrigamiSwiftUIExportSegment {
    let kind:
        OrigamiSwiftUIExportSegmentKind
    let pageIndex: Int
    let completedBatchCount: Int
    let duration: Double
}

private func origamiSwiftUIExportAspectRatio(
    of image: NSImage
) -> Double {
    guard image.size.height > 0 else {
        return 1
    }

    return Double(
        image.size.width
        / image.size.height
    )
}

private func origamiSwiftUIExportOrientation(
    of image: NSImage
) -> Int {
    let ratio =
        origamiSwiftUIExportAspectRatio(
            of: image
        )

    if ratio > 1.15 {
        return 1
    }

    if ratio < 0.85 {
        return -1
    }

    return 0
}

private func origamiSwiftUIExportTargetSlots(
    incomingImages: [NSImage],
    baseImages: [NSImage],
    replacements: [Int: NSImage],
    usedSlots: Set<Int>
) -> [Int] {
    guard !baseImages.isEmpty else {
        return []
    }

    var availableSlots =
        Array(
            baseImages.indices
        )
        .filter {
            !usedSlots.contains($0)
        }

    if availableSlots.isEmpty {
        availableSlots =
            Array(baseImages.indices)
    }

    var targets: [Int] = []

    for incomingImage in incomingImages {
        guard !availableSlots.isEmpty else {
            break
        }

        let incomingRatio =
            origamiSwiftUIExportAspectRatio(
                of: incomingImage
            )

        let incomingOrientation =
            origamiSwiftUIExportOrientation(
                of: incomingImage
            )

        let target =
            availableSlots.min {
                leftSlot,
                rightSlot in

                func score(
                    slot: Int
                ) -> Double {
                    guard baseImages.indices
                            .contains(slot)
                    else {
                        return 100
                    }

                    let currentImage =
                        replacements[slot]
                        ?? baseImages[slot]

                    let currentRatio =
                        origamiSwiftUIExportAspectRatio(
                            of: currentImage
                        )

                    let currentOrientation =
                        origamiSwiftUIExportOrientation(
                            of: currentImage
                        )

                    let orientationPenalty =
                        incomingOrientation
                            == currentOrientation
                        ? 0.0
                        : 8.0

                    let ratioPenalty = abs(
                        log(
                            max(
                                0.05,
                                incomingRatio
                            )
                            /
                            max(
                                0.05,
                                currentRatio
                            )
                        )
                    )

                    return orientationPenalty
                        + ratioPenalty
                }

                return score(slot: leftSlot)
                    < score(slot: rightSlot)
            }!

        targets.append(target)

        availableSlots.removeAll {
            $0 == target
        }
    }

    return targets
}

// Wraps makeSDRExportCGImage's HDR-gain-map-suppressed, sRGB-normalized
// decode back into an NSImage, for callers (like the Origami/Kirigami
// SwiftUI export path) that need an NSImage rather than a raw CGImage.
private func makeSDRExportNSImage(from url: URL) -> NSImage? {
    guard let cgImage = makeSDRExportCGImage(from: url) else {
        return nil
    }

    return NSImage(
        cgImage: cgImage,
        size: NSSize(width: cgImage.width, height: cgImage.height)
    )
}

private func buildOrigamiSwiftUIExportPages(
    photoURLs: [URL],
    imagesBeforePageChange: Int,
    simultaneousSwapCount: Int,
    cropTransforms: [URL: MagazinePhotoCrop],
    manualLayoutOverrides: [Int: Int],
    theme: SlideshowVisualTheme = .origami
) -> (pages: [OrigamiSwiftUIExportPage], cropByImageIdentity: [ObjectIdentifier: MagazinePhotoCrop]) {
    // Plain NSImage(contentsOf:) doesn't suppress Apple's HDR gain-map
    // photos (very common in bright outdoor shots), so those specific
    // photos could get interpreted inconsistently once baked into the SDR
    // video frame while non-HDR photos looked fine — reusing the same
    // normalized decode Magazine's export already uses fixes that.
    let loadedPhotoPairs: [(url: URL, image: NSImage)] =
        photoURLs.compactMap { url in
            makeSDRExportNSImage(from: url).map { (url: url, image: $0) }
        }

    var cropByImageIdentity: [ObjectIdentifier: MagazinePhotoCrop] = [:]

    for pair in loadedPhotoPairs {
        if let crop = cropTransforms[pair.url] {
            cropByImageIdentity[ObjectIdentifier(pair.image)] = crop
        }
    }

    let loadedImages = loadedPhotoPairs.map(\.image)

    guard !loadedImages.isEmpty else {
        return ([], cropByImageIdentity)
    }

    let isStrict43 = theme == .origami43
    let cycle = isStrict43 ? [2, 3, 2, 3, 4] : [3, 5, 6, 2, 4]
    let maxSlotCount = isStrict43 ? 4 : 6

    let requestedReplacementCount =
        max(
            0,
            min(
                6,
                imagesBeforePageChange
            )
        )

    let safeSimultaneousCount =
        max(
            1,
            simultaneousSwapCount
        )

    var pages:
        [OrigamiSwiftUIExportPage] = []

    var photoIndex = 0
    var pageIndex = 0

    while photoIndex < loadedImages.count {
        let remainingPhotos =
            loadedImages.count
            - photoIndex

        var baseSlotCount = min(
            cycle[
                pageIndex
                % cycle.count
            ],
            remainingPhotos
        )

        if remainingPhotos
            - baseSlotCount == 1,
           baseSlotCount > 2 {

            baseSlotCount -= 1
        }

        baseSlotCount = max(
            1,
            min(
                maxSlotCount,
                baseSlotCount
            )
        )

        var replacementCount = min(
            requestedReplacementCount,
            baseSlotCount,
            max(
                0,
                remainingPhotos
                    - baseSlotCount
            )
        )

        if remainingPhotos
            - baseSlotCount
            - replacementCount == 1,
           replacementCount > 0 {

            replacementCount -= 1
        }

        let baseEnd = min(
            loadedImages.count,
            photoIndex
                + baseSlotCount
        )

        let baseImages = Array(
            loadedImages[
                photoIndex..<baseEnd
            ]
        )

        let replacementStart =
            baseEnd

        let replacementEnd = min(
            loadedImages.count,
            replacementStart
                + replacementCount
        )

        let replacementImages =
            replacementStart
                < replacementEnd
            ? Array(
                loadedImages[
                    replacementStart
                    ..< replacementEnd
                ]
            )
            : []

        var swapBatches:
            [OrigamiSwiftUIExportSwapBatch] = []

        var currentReplacements:
            [Int: NSImage] = [:]

        var usedSlots:
            Set<Int> = []

        var replacementOffset = 0

        while replacementOffset
                < replacementImages.count {

            let batchEnd = min(
                replacementImages.count,
                replacementOffset
                    + safeSimultaneousCount
            )

            let incomingImages = Array(
                replacementImages[
                    replacementOffset
                    ..< batchEnd
                ]
            )

            let targetSlots =
                origamiSwiftUIExportTargetSlots(
                    incomingImages:
                        incomingImages,
                    baseImages:
                        baseImages,
                    replacements:
                        currentReplacements,
                    usedSlots:
                        usedSlots
                )

            guard targetSlots.count
                    == incomingImages.count
            else {
                break
            }

            var batchImages:
                [Int: NSImage] = [:]

            var batchStyles:
                [Int: Int] = [:]

            let batchStyle =
                pageIndex.isMultiple(of: 2)
                ? 0
                : 1

            for (
                offset,
                incomingImage
            ) in incomingImages.enumerated() {

                let slot =
                    targetSlots[offset]

                batchImages[slot] =
                    incomingImage

                batchStyles[slot] =
                    batchStyle

                currentReplacements[slot] =
                    incomingImage

                usedSlots.insert(slot)
            }

            swapBatches.append(
                OrigamiSwiftUIExportSwapBatch(
                    images:
                        batchImages,
                    styles:
                        batchStyles
                )
            )

            replacementOffset =
                batchEnd
        }

        pages.append(
            OrigamiSwiftUIExportPage(
                baseImages:
                    baseImages,
                theme: theme,
                swapBatches:
                    swapBatches,
                finalReplacements:
                    currentReplacements,
                pageIndex:
                    pageIndex,
                manualLayoutVariant:
                    manualLayoutOverrides[pageIndex]
            )
        )

        photoIndex +=
            baseSlotCount
            + replacementCount

        pageIndex += 1
    }

    return (pages, cropByImageIdentity)
}

private func origamiSwiftUIExportSmoothstep(
    _ value: Double
) -> Double {
    let clamped = min(
        1,
        max(
            0,
            value
        )
    )

    return clamped
        * clamped
        * (
            3
            - 2 * clamped
        )
}

// SwiftUI .easeInOut uses a cubic timing curve.
// This converts linear export time to the same curve.
private func origamiSwiftUIExportEaseInOut(
    _ value: Double
) -> Double {
    let targetX = min(
        1,
        max(
            0,
            value
        )
    )

    let x1 = 0.42
    let y1 = 0.0
    let x2 = 0.58
    let y2 = 1.0

    func sample(
        _ t: Double,
        _ first: Double,
        _ second: Double
    ) -> Double {
        let inverse = 1 - t

        return
            3
            * inverse
            * inverse
            * t
            * first
            + 3
            * inverse
            * t
            * t
            * second
            + t
            * t
            * t
    }

    var low = 0.0
    var high = 1.0

    for _ in 0..<14 {
        let middle =
            (low + high) * 0.5

        if sample(
            middle,
            x1,
            x2
        ) < targetX {
            low = middle
        } else {
            high = middle
        }
    }

    return sample(
        (low + high) * 0.5,
        y1,
        y2
    )
}

private func origamiSwiftUIExportReplacements(
    page: OrigamiSwiftUIExportPage,
    completedBatchCount: Int
) -> [Int: NSImage] {
    var replacements:
        [Int: NSImage] = [:]

    let safeCount = min(
        max(
            0,
            completedBatchCount
        ),
        page.swapBatches.count
    )

    for batch in
        page.swapBatches.prefix(
            safeCount
        ) {

        for (
            slot,
            image
        ) in batch.images {

            replacements[slot] =
                image
        }
    }

    return replacements
}

private struct OrigamiSwiftUIExportFrameView:
    View {

    let page:
        OrigamiSwiftUIExportPage

    let replacements:
        [Int: NSImage]

    let activeSwapImages:
        [Int: NSImage]

    let activeSwapStyles:
        [Int: Int]

    let swapProgress: Double
    let transitionProgress: Double

    let previousPage:
        OrigamiSwiftUIExportPage?

    let wholePageFoldProgress:
        Double

    let blackOverlayOpacity:
        Double

    let cropByImageIdentity:
        [ObjectIdentifier: MagazinePhotoCrop]

    var body: some View {
        ZStack {
            Color.black

            OrigamiPreviewPage(
                images:
                    page.baseImages,
                theme: page.theme,
                slotReplacementImages:
                    replacements,
                activeSwapImages:
                    activeSwapImages,
                activeSwapStyles:
                    activeSwapStyles,
                swapProgress:
                    swapProgress,
                activePhotoName: "",
                showsPhotoName: false,
                transitionProgress:
                    transitionProgress,
                animationVariant:
                    page.pageIndex,
                cropByImageIdentity:
                    cropByImageIdentity,
                manualLayoutVariant:
                    page.manualLayoutVariant
            )

            if let previousPage {
                OrigamiWholePageHalfFoldOverlay(
                    images:
                        previousPage
                            .baseImages,
                    theme: previousPage.theme,
                    slotReplacementImages:
                        previousPage
                            .finalReplacements,
                    animationVariant:
                        previousPage
                            .pageIndex,
                    progress:
                        wholePageFoldProgress,
                    cropByImageIdentity:
                        cropByImageIdentity,
                    manualLayoutVariant:
                        previousPage
                            .manualLayoutVariant
                )
                .allowsHitTesting(false)
                .zIndex(100)
            }

            Color.black
                .opacity(
                    min(
                        1,
                        max(
                            0,
                            blackOverlayOpacity
                        )
                    )
                )
                .allowsHitTesting(false)
                .zIndex(500)
        }
        .background(Color.black)
    }
}

private func makeOrigamiSwiftUIExportCGImage(
    page:
        OrigamiSwiftUIExportPage,
    replacements:
        [Int: NSImage],
    activeSwapImages:
        [Int: NSImage],
    activeSwapStyles:
        [Int: Int],
    swapProgress: Double,
    transitionProgress: Double,
    previousPage:
        OrigamiSwiftUIExportPage?,
    wholePageFoldProgress: Double,
    blackOverlayOpacity: Double,
    cropByImageIdentity: [ObjectIdentifier: MagazinePhotoCrop],
    renderSize: CGSize
) -> CGImage? {
    var renderedImage: CGImage?

    let renderBlock = {
        let frameView =
            OrigamiSwiftUIExportFrameView(
                page:
                    page,
                replacements:
                    replacements,
                activeSwapImages:
                    activeSwapImages,
                activeSwapStyles:
                    activeSwapStyles,
                swapProgress:
                    swapProgress,
                transitionProgress:
                    transitionProgress,
                previousPage:
                    previousPage,
                wholePageFoldProgress:
                    wholePageFoldProgress,
                blackOverlayOpacity:
                    blackOverlayOpacity,
                cropByImageIdentity:
                    cropByImageIdentity
            )
            .frame(
                width:
                    renderSize.width,
                height:
                    renderSize.height
            )
            .background(Color.black)

        let renderer =
            ImageRenderer(
                content:
                    frameView
            )

        renderer.proposedSize =
            ProposedViewSize(
                width:
                    renderSize.width,
                height:
                    renderSize.height
            )

        renderer.scale = 1

        renderedImage =
            renderer.cgImage
    }

    if Thread.isMainThread {
        renderBlock()
    } else {
        DispatchQueue.main.sync(
            execute:
                renderBlock
        )
    }

    return renderedImage
}

private func makeOrigamiSwiftUIExportPixelBuffer(
    page:
        OrigamiSwiftUIExportPage,
    replacements:
        [Int: NSImage],
    activeSwapImages:
        [Int: NSImage],
    activeSwapStyles:
        [Int: Int],
    swapProgress: Double,
    transitionProgress: Double,
    previousPage:
        OrigamiSwiftUIExportPage?,
    wholePageFoldProgress: Double,
    blackOverlayOpacity: Double,
    cropByImageIdentity: [ObjectIdentifier: MagazinePhotoCrop],
    renderSize: CGSize,
    pixelBufferPool:
        CVPixelBufferPool?
) -> CVPixelBuffer? {
    guard let pixelBufferPool,
          let frameImage =
            makeOrigamiSwiftUIExportCGImage(
                page:
                    page,
                replacements:
                    replacements,
                activeSwapImages:
                    activeSwapImages,
                activeSwapStyles:
                    activeSwapStyles,
                swapProgress:
                    swapProgress,
                transitionProgress:
                    transitionProgress,
                previousPage:
                    previousPage,
                wholePageFoldProgress:
                    wholePageFoldProgress,
                blackOverlayOpacity:
                    blackOverlayOpacity,
                cropByImageIdentity:
                    cropByImageIdentity,
                renderSize:
                    renderSize
            )
    else {
        return nil
    }

    var pixelBuffer:
        CVPixelBuffer?

    let status =
        CVPixelBufferPoolCreatePixelBuffer(
            nil,
            pixelBufferPool,
            &pixelBuffer
        )

    guard status
            == kCVReturnSuccess,
          let pixelBuffer
    else {
        return nil
    }

    CVPixelBufferLockBaseAddress(
        pixelBuffer,
        []
    )

    defer {
        CVPixelBufferUnlockBaseAddress(
            pixelBuffer,
            []
        )
    }

    guard let context = CGContext(
        data:
            CVPixelBufferGetBaseAddress(
                pixelBuffer
            ),
        width:
            Int(renderSize.width),
        height:
            Int(renderSize.height),
        bitsPerComponent: 8,
        bytesPerRow:
            CVPixelBufferGetBytesPerRow(
                pixelBuffer
            ),
        space:
            // Device RGB is uncalibrated — drawing a wide-gamut (Display P3)
            // source frame into it lets CoreGraphics reinterpret those pixel
            // values arbitrarily, which is why some photos came out darker
            // than others depending on their embedded color profile, while
            // the live SwiftUI preview (properly color-managed by AppKit)
            // never showed the mismatch. sRGB is a real calibrated space, so
            // the conversion from the source profile is well-defined.
            magazineExportSRGBColorSpace,
        bitmapInfo:
            CGImageAlphaInfo
                .premultipliedFirst
                .rawValue
            | CGBitmapInfo
                .byteOrder32Little
                .rawValue
    ) else {
        return nil
    }

    let canvasRect = CGRect(
        origin: .zero,
        size: renderSize
    )

    context.setFillColor(
        NSColor.black.cgColor
    )

    context.fill(canvasRect)

    context.interpolationQuality =
        .high

    context.draw(
        frameImage,
        in: canvasRect
    )

    return pixelBuffer
}

private enum OrigamiExportAnimationPhase {
    case initialReveal
    case hold
    case pageFold
}

private func origamiExportSmoothstep(
    _ value: Double
) -> Double {
    let clamped = min(
        1,
        max(0, value)
    )

    return clamped
        * clamped
        * (
            3
            - 2 * clamped
        )
}

private func origamiExportPageRect(
    renderSize: CGSize
) -> CGRect {
    let pageWidth = min(
        renderSize.width,
        renderSize.height * 16 / 9
    )

    let pageHeight =
        pageWidth * 9 / 16

    return CGRect(
        x:
            (
                renderSize.width
                - pageWidth
            ) / 2,
        y:
            (
                renderSize.height
                - pageHeight
            ) / 2,
        width: pageWidth,
        height: pageHeight
    )
}

private func drawOrigamiExportPage(
    _ page: OrigamiExportPage,
    in pageRect: CGRect,
    context: CGContext,
    revealProgress: Double = 1,
    animationVariant: Int = 0
) {
    let rects =
        origamiExportLayoutRects(
            photos: page.photos,
            pageRect: pageRect
        )

    let orderedPhotos =
        bestOrigamiExportPhotoOrder(
            photos: page.photos,
            rects: rects
        )

    let count = min(
        orderedPhotos.count,
        rects.count
    )

    guard count > 0 else {
        return
    }

    let safeGlobalProgress = min(
        1,
        max(0, revealProgress)
    )

    for index in 0..<count {
        let delay =
            Double(index)
            * 0.065

        let rawTileProgress =
            (
                safeGlobalProgress
                - delay
            )
            / 0.72

        let tileProgress =
            origamiExportSmoothstep(
                rawTileProgress
            )

        guard tileProgress > 0.001 else {
            continue
        }

        let tileRect =
            rects[index]

        let revealRect: CGRect

        let mode =
            (
                animationVariant
                + index
            ) % 2

        if mode == 0 {
            let revealedWidth =
                tileRect.width
                * CGFloat(tileProgress)

            if index.isMultiple(of: 2) {
                revealRect = CGRect(
                    x: tileRect.minX,
                    y: tileRect.minY,
                    width: revealedWidth,
                    height: tileRect.height
                )
            } else {
                revealRect = CGRect(
                    x:
                        tileRect.maxX
                        - revealedWidth,
                    y: tileRect.minY,
                    width: revealedWidth,
                    height: tileRect.height
                )
            }
        } else {
            let revealedHeight =
                tileRect.height
                * CGFloat(tileProgress)

            if index.isMultiple(of: 2) {
                revealRect = CGRect(
                    x: tileRect.minX,
                    y: tileRect.minY,
                    width: tileRect.width,
                    height: revealedHeight
                )
            } else {
                revealRect = CGRect(
                    x: tileRect.minX,
                    y:
                        tileRect.maxY
                        - revealedHeight,
                    width: tileRect.width,
                    height: revealedHeight
                )
            }
        }

        context.saveGState()
        context.clip(to: revealRect)

        drawOrigamiExportImage(
            orderedPhotos[index].image,
            in: tileRect,
            context: context
        )

        let shadeOpacity =
            CGFloat(
                0.34
                * (
                    1
                    - tileProgress
                )
            )

        if shadeOpacity > 0.001 {
            context.setFillColor(
                NSColor.black
                    .withAlphaComponent(
                        shadeOpacity
                    )
                    .cgColor
            )

            context.fill(revealRect)
        }

        context.restoreGState()
    }
}

private func makeOrigamiExportPageImage(
    page: OrigamiExportPage,
    size: CGSize
) -> CGImage? {
    let width = max(
        1,
        Int(size.width.rounded())
    )

    let height = max(
        1,
        Int(size.height.rounded())
    )

    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space:
            CGColorSpaceCreateDeviceRGB(),
        bitmapInfo:
            CGImageAlphaInfo
                .premultipliedLast
                .rawValue
    ) else {
        return nil
    }

    let localRect = CGRect(
        x: 0,
        y: 0,
        width: CGFloat(width),
        height: CGFloat(height)
    )

    context.setFillColor(
        NSColor.black.cgColor
    )

    context.fill(localRect)

    drawOrigamiExportPage(
        page,
        in: localRect,
        context: context,
        revealProgress: 1
    )

    return context.makeImage()
}

private func drawOrigamiExportWholePageFold(
    previousPage: OrigamiExportPage,
    in pageRect: CGRect,
    context: CGContext,
    progress: Double,
    usesVerticalCenterFold: Bool
) {
    let safeProgress =
        origamiExportSmoothstep(
            progress
        )

    guard safeProgress < 0.999 else {
        return
    }

    guard let pageImage =
        makeOrigamiExportPageImage(
            page: previousPage,
            size: pageRect.size
        )
    else {
        return
    }

    let remaining =
        CGFloat(
            1
            - safeProgress
        )

    context.saveGState()
    context.interpolationQuality = .high

    if usesVerticalCenterFold {
        let halfWidth =
            pageRect.width * 0.5

        let foldedWidth =
            halfWidth * remaining

        let leftDestination = CGRect(
            x:
                pageRect.midX
                - foldedWidth,
            y: pageRect.minY,
            width: foldedWidth,
            height: pageRect.height
        )

        let rightDestination = CGRect(
            x: pageRect.midX,
            y: pageRect.minY,
            width: foldedWidth,
            height: pageRect.height
        )

        let imageWidth =
            CGFloat(pageImage.width)

        let imageHeight =
            CGFloat(pageImage.height)

        let leftCrop = CGRect(
            x: 0,
            y: 0,
            width: imageWidth * 0.5,
            height: imageHeight
        )

        let rightCrop = CGRect(
            x: imageWidth * 0.5,
            y: 0,
            width: imageWidth * 0.5,
            height: imageHeight
        )

        if let leftImage =
            pageImage.cropping(
                to: leftCrop
            ) {
            context.draw(
                leftImage,
                in: leftDestination
            )
        }

        if let rightImage =
            pageImage.cropping(
                to: rightCrop
            ) {
            context.draw(
                rightImage,
                in: rightDestination
            )
        }

        let shadowWidth =
            max(
                2,
                pageRect.width
                    * 0.018
                    * CGFloat(
                        sin(
                            safeProgress
                            * .pi
                        )
                    )
            )

        let shadowRect = CGRect(
            x:
                pageRect.midX
                - shadowWidth * 0.5,
            y: pageRect.minY,
            width: shadowWidth,
            height: pageRect.height
        )

        context.setFillColor(
            NSColor.black
                .withAlphaComponent(
                    CGFloat(
                        0.52
                        * sin(
                            safeProgress
                            * .pi
                        )
                    )
                )
                .cgColor
        )

        context.fill(shadowRect)
    } else {
        let halfHeight =
            pageRect.height * 0.5

        let foldedHeight =
            halfHeight * remaining

        let bottomDestination = CGRect(
            x: pageRect.minX,
            y:
                pageRect.midY
                - foldedHeight,
            width: pageRect.width,
            height: foldedHeight
        )

        let topDestination = CGRect(
            x: pageRect.minX,
            y: pageRect.midY,
            width: pageRect.width,
            height: foldedHeight
        )

        let imageWidth =
            CGFloat(pageImage.width)

        let imageHeight =
            CGFloat(pageImage.height)

        let bottomCrop = CGRect(
            x: 0,
            y: 0,
            width: imageWidth,
            height: imageHeight * 0.5
        )

        let topCrop = CGRect(
            x: 0,
            y: imageHeight * 0.5,
            width: imageWidth,
            height: imageHeight * 0.5
        )

        if let bottomImage =
            pageImage.cropping(
                to: bottomCrop
            ) {
            context.draw(
                bottomImage,
                in: bottomDestination
            )
        }

        if let topImage =
            pageImage.cropping(
                to: topCrop
            ) {
            context.draw(
                topImage,
                in: topDestination
            )
        }

        let shadowHeight =
            max(
                2,
                pageRect.height
                    * 0.026
                    * CGFloat(
                        sin(
                            safeProgress
                            * .pi
                        )
                    )
            )

        let shadowRect = CGRect(
            x: pageRect.minX,
            y:
                pageRect.midY
                - shadowHeight * 0.5,
            width: pageRect.width,
            height: shadowHeight
        )

        context.setFillColor(
            NSColor.black
                .withAlphaComponent(
                    CGFloat(
                        0.52
                        * sin(
                            safeProgress
                            * .pi
                        )
                    )
                )
                .cgColor
        )

        context.fill(shadowRect)
    }

    context.restoreGState()
}

private func makeOrigamiExportPixelBuffer(
    page: OrigamiExportPage,
    nextPage: OrigamiExportPage?,
    phase: OrigamiExportAnimationPhase,
    phaseProgress: Double,
    pageIndex: Int,
    blackOverlayOpacity: Double,
    renderSize: CGSize,
    pixelBufferPool: CVPixelBufferPool?
) -> CVPixelBuffer? {
    guard let pixelBufferPool else {
        return nil
    }

    var pixelBuffer: CVPixelBuffer?

    let status =
        CVPixelBufferPoolCreatePixelBuffer(
            nil,
            pixelBufferPool,
            &pixelBuffer
        )

    guard status == kCVReturnSuccess,
          let pixelBuffer
    else {
        return nil
    }

    CVPixelBufferLockBaseAddress(
        pixelBuffer,
        []
    )

    defer {
        CVPixelBufferUnlockBaseAddress(
            pixelBuffer,
            []
        )
    }

    guard let context = CGContext(
        data:
            CVPixelBufferGetBaseAddress(
                pixelBuffer
            ),
        width: Int(renderSize.width),
        height: Int(renderSize.height),
        bitsPerComponent: 8,
        bytesPerRow:
            CVPixelBufferGetBytesPerRow(
                pixelBuffer
            ),
        space:
            CGColorSpaceCreateDeviceRGB(),
        bitmapInfo:
            CGImageAlphaInfo
                .premultipliedFirst
                .rawValue
            | CGBitmapInfo
                .byteOrder32Little
                .rawValue
    ) else {
        return nil
    }

    let canvasRect = CGRect(
        origin: .zero,
        size: renderSize
    )

    context.setFillColor(
        NSColor.black.cgColor
    )

    context.fill(canvasRect)

    let pageRect =
        origamiExportPageRect(
            renderSize: renderSize
        )

    switch phase {
    case .initialReveal:
        drawOrigamiExportPage(
            page,
            in: pageRect,
            context: context,
            revealProgress:
                phaseProgress,
            animationVariant:
                pageIndex
        )

    case .hold:
        drawOrigamiExportPage(
            page,
            in: pageRect,
            context: context,
            revealProgress: 1,
            animationVariant:
                pageIndex
        )

    case .pageFold:
        if let nextPage {
            drawOrigamiExportPage(
                nextPage,
                in: pageRect,
                context: context,
                revealProgress: 1,
                animationVariant:
                    pageIndex + 1
            )
        }

        drawOrigamiExportWholePageFold(
            previousPage: page,
            in: pageRect,
            context: context,
            progress:
                phaseProgress,
            usesVerticalCenterFold:
                pageIndex
                    .isMultiple(of: 2)
                    == false
        )
    }

    let safeBlackOpacity = min(
        1,
        max(
            0,
            blackOverlayOpacity
        )
    )

    if safeBlackOpacity > 0.001 {
        context.setFillColor(
            NSColor.black
                .withAlphaComponent(
                    CGFloat(
                        safeBlackOpacity
                    )
                )
                .cgColor
        )

        context.fill(canvasRect)
    }

    return pixelBuffer
}

private func renderOrigamiSlideshowVideo(
    photoURLs: [URL],
    outputURL: URL,
    resolutionName: String,
    pageDuration: Double,
    imagesBeforePageChange: Int,
    simultaneousSwapCount: Int,
    cropTransforms: [URL: MagazinePhotoCrop],
    manualLayoutOverrides: [Int: Int],
    theme: SlideshowVisualTheme = .origami,
    fileType: AVFileType = .mp4,
    progressHandler:
        @escaping @Sendable (Double) -> Void
) throws {
    if FileManager.default.fileExists(
        atPath: outputURL.path
    ) {
        try FileManager.default.removeItem(
            at: outputURL
        )
    }

    let (pages, cropByImageIdentity) =
        buildOrigamiSwiftUIExportPages(
            photoURLs:
                photoURLs,
            imagesBeforePageChange:
                imagesBeforePageChange,
            simultaneousSwapCount:
                simultaneousSwapCount,
            cropTransforms:
                cropTransforms,
            manualLayoutOverrides:
                manualLayoutOverrides,
            theme: theme
        )

    guard !pages.isEmpty else {
        throw BriefShowExportError
            .couldNotCreatePixelBuffer
    }

    let renderSize =
        origamiExportRenderSize(
            for: resolutionName
        )

    let fps: Int32 = 30

    let safeHoldDuration =
        max(
            1.0,
            min(
                15.0,
                pageDuration
            )
        )

    let initialRevealDuration =
        min(
            1.20,
            max(
                0.78,
                safeHoldDuration * 0.30
            )
        )

    let internalSwapDuration =
        1.05

    let wholePageFoldDuration =
        1.30

    var segments:
        [OrigamiSwiftUIExportSegment] = []

    segments.append(
        OrigamiSwiftUIExportSegment(
            kind:
                .initialReveal,
            pageIndex: 0,
            completedBatchCount: 0,
            duration:
                initialRevealDuration
        )
    )

    for pageIndex in pages.indices {
        let page =
            pages[pageIndex]

        for batchIndex in
            page.swapBatches.indices {

            // Preview waits before every internal swap.
            segments.append(
                OrigamiSwiftUIExportSegment(
                    kind: .hold,
                    pageIndex:
                        pageIndex,
                    completedBatchCount:
                        batchIndex,
                    duration:
                        safeHoldDuration
                )
            )

            segments.append(
                OrigamiSwiftUIExportSegment(
                    kind:
                        .swap(
                            batchIndex
                        ),
                    pageIndex:
                        pageIndex,
                    completedBatchCount:
                        batchIndex,
                    duration:
                        internalSwapDuration
                )
            )
        }

        // Preview waits once more before changing page.
        segments.append(
            OrigamiSwiftUIExportSegment(
                kind: .hold,
                pageIndex:
                    pageIndex,
                completedBatchCount:
                    page.swapBatches.count,
                duration:
                    safeHoldDuration
            )
        )

        if pageIndex
            < pages.count - 1 {

            segments.append(
                OrigamiSwiftUIExportSegment(
                    kind:
                        .pageFold,
                    pageIndex:
                        pageIndex,
                    completedBatchCount:
                        page.swapBatches.count,
                    duration:
                        wholePageFoldDuration
                )
            )
        }
    }

    let totalDuration =
        segments.reduce(0) {
            $0 + $1.duration
        }

    let totalFrameCount = max(
        1,
        Int(
            ceil(
                totalDuration
                * Double(fps)
            )
        )
    )

    let writer =
        try AVAssetWriter(
            outputURL:
                outputURL,
            fileType: fileType
        )

    let pixelCount =
        renderSize.width
        * renderSize.height

    let shouldUseHEVC =
        resolutionName
            .trimmingCharacters(
                in:
                    .whitespacesAndNewlines
            ) == "Original"
        || pixelCount > 8_294_400

    let codec:
        AVVideoCodecType =
            shouldUseHEVC
            ? .hevc
            : .h264

    let compressionProperties:
        [String: Any] = [
            AVVideoAverageBitRateKey:
                exportBitrate(
                    for: renderSize
                ),
            AVVideoMaxKeyFrameIntervalKey:
                30,
            AVVideoExpectedSourceFrameRateKey:
                30,
        ]

    let videoSettings:
        [String: Any] = [
            AVVideoCodecKey:
                codec,
            AVVideoWidthKey:
                Int(renderSize.width),
            AVVideoHeightKey:
                Int(renderSize.height),
            AVVideoCompressionPropertiesKey:
                compressionProperties,
        ]

    guard writer.canApply(
        outputSettings:
            videoSettings,
        forMediaType:
            .video
    ) else {
        throw BriefShowExportError
            .cannotAddVideoInput
    }

    let input =
        AVAssetWriterInput(
            mediaType:
                .video,
            outputSettings:
                videoSettings
        )

    input.expectsMediaDataInRealTime =
        false

    let pixelBufferAttributes:
        [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey
                as String:
                    kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey
                as String:
                    Int(renderSize.width),
            kCVPixelBufferHeightKey
                as String:
                    Int(renderSize.height),
            kCVPixelBufferCGImageCompatibilityKey
                as String:
                    true,
            kCVPixelBufferCGBitmapContextCompatibilityKey
                as String:
                    true,
        ]

    let adaptor =
        AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput:
                input,
            sourcePixelBufferAttributes:
                pixelBufferAttributes
        )

    guard writer.canAdd(input) else {
        throw BriefShowExportError
            .cannotAddVideoInput
    }

    writer.add(input)

    guard writer.startWriting() else {
        throw writer.error
            ?? BriefShowExportError
                .writerFailed
    }

    writer.startSession(
        atSourceTime: .zero
    )

    let fadeDuration = min(
        1.0,
        totalDuration * 0.5
    )

    var frameNumber: Int64 = 0
    var cachedSegmentIndex = 0
    var cachedSegmentStart = 0.0

    for frameIndex in 0..<totalFrameCount {
        while !input
            .isReadyForMoreMediaData {

            Thread.sleep(
                forTimeInterval:
                    0.004
            )
        }

        let globalTime =
            Double(frameIndex)
            / Double(fps)

        while cachedSegmentIndex
                < segments.count - 1,
              globalTime
                >= cachedSegmentStart
                    + segments[
                        cachedSegmentIndex
                    ].duration {

            cachedSegmentStart +=
                segments[
                    cachedSegmentIndex
                ].duration

            cachedSegmentIndex += 1
        }

        let segment =
            segments[
                cachedSegmentIndex
            ]

        let localLinearProgress =
            segment.duration > 0
            ? min(
                1,
                max(
                    0,
                    (
                        globalTime
                        - cachedSegmentStart
                    )
                    / segment.duration
                )
            )
            : 1

        let page =
            pages[
                segment.pageIndex
            ]

        let replacements =
            origamiSwiftUIExportReplacements(
                page:
                    page,
                completedBatchCount:
                    segment
                        .completedBatchCount
            )

        var activeSwapImages:
            [Int: NSImage] = [:]

        var activeSwapStyles:
            [Int: Int] = [:]

        var swapProgress = 1.0
        var transitionProgress = 1.0

        var previousPage:
            OrigamiSwiftUIExportPage?

        var wholePageFoldProgress =
            1.0

        switch segment.kind {
        case .initialReveal:
            transitionProgress =
                origamiSwiftUIExportEaseInOut(
                    localLinearProgress
                )

        case .hold:
            break

        case .swap(let batchIndex):
            if page.swapBatches.indices
                .contains(batchIndex) {

                let batch =
                    page.swapBatches[
                        batchIndex
                    ]

                activeSwapImages =
                    batch.images

                activeSwapStyles =
                    batch.styles

                swapProgress =
                    origamiSwiftUIExportEaseInOut(
                        localLinearProgress
                    )
            }

        case .pageFold:
            guard segment.pageIndex + 1
                    < pages.count
            else {
                break
            }

            previousPage =
                page

            // Preview manually stores one smoothstep value.
            // The shared overlay applies its own smoothstep again.
            wholePageFoldProgress =
                origamiSwiftUIExportSmoothstep(
                    localLinearProgress
                )
        }

        let displayedPage:
            OrigamiSwiftUIExportPage

        let displayedReplacements:
            [Int: NSImage]

        if case .pageFold =
            segment.kind {

            displayedPage =
                pages[
                    min(
                        segment.pageIndex + 1,
                        pages.count - 1
                    )
                ]

            displayedReplacements = [:]
        } else {
            displayedPage = page

            displayedReplacements =
                replacements
        }

        let fadeInAlpha:
            Double

        if fadeDuration > 0 {
            fadeInAlpha = max(
                0,
                1
                - globalTime
                    / fadeDuration
            )
        } else {
            fadeInAlpha = 0
        }

        let fadeOutStart = max(
            0,
            totalDuration
                - fadeDuration
        )

        let fadeOutAlpha:
            Double

        if fadeDuration > 0,
           globalTime >= fadeOutStart {

            fadeOutAlpha =
                origamiSwiftUIExportSmoothstep(
                    (
                        globalTime
                        - fadeOutStart
                    )
                    / fadeDuration
                )
        } else {
            fadeOutAlpha = 0
        }

        let blackOverlayOpacity = min(
            1,
            max(
                fadeInAlpha,
                fadeOutAlpha
            )
        )

        guard let pixelBuffer =
            makeOrigamiSwiftUIExportPixelBuffer(
                page:
                    displayedPage,
                replacements:
                    displayedReplacements,
                activeSwapImages:
                    activeSwapImages,
                activeSwapStyles:
                    activeSwapStyles,
                swapProgress:
                    swapProgress,
                transitionProgress:
                    transitionProgress,
                previousPage:
                    previousPage,
                wholePageFoldProgress:
                    wholePageFoldProgress,
                blackOverlayOpacity:
                    blackOverlayOpacity,
                cropByImageIdentity:
                    cropByImageIdentity,
                renderSize:
                    renderSize,
                pixelBufferPool:
                    adaptor
                        .pixelBufferPool
            )
        else {
            throw BriefShowExportError
                .couldNotCreatePixelBuffer
        }

        let presentationTime =
            CMTime(
                value:
                    frameNumber,
                timescale:
                    fps
            )

        guard adaptor.append(
            pixelBuffer,
            withPresentationTime:
                presentationTime
        ) else {
            throw writer.error
                ?? BriefShowExportError
                    .writerFailed
        }

        frameNumber += 1

        progressHandler(
            min(
                1,
                Double(frameNumber)
                / Double(
                    totalFrameCount
                )
            )
        )
    }

    input.markAsFinished()

    let finishSemaphore =
        DispatchSemaphore(
            value: 0
        )

    writer.finishWriting {
        finishSemaphore.signal()
    }

    finishSemaphore.wait()

    guard writer.status
            == .completed
    else {
        throw writer.error
            ?? BriefShowExportError
                .writerFailed
    }

    print(
        "BriefShow shared SwiftUI Origami export completed.",
        Int(renderSize.width),
        "x",
        Int(renderSize.height),
        "frames:",
        frameNumber,
        "pages:",
        pages.count
    )
}


private func renderSlideshowVideo(
    photoURLs: [URL],
    outputURL: URL,
    resolutionName: String,
    secondsPerPhoto: Double,
    transitionStyle: SlideshowTransitionStyle,
    fadeDuration: Double,
    fileType: AVFileType = .mp4,
    progressHandler: @escaping @Sendable (Double) -> Void
) throws {
    if FileManager.default.fileExists(atPath: outputURL.path) {
        try FileManager.default.removeItem(at: outputURL)
    }

    let renderSize = exportRenderSize(for: resolutionName, photoURLs: photoURLs)
    let fps: Int32 = 30
    let frameDuration = CMTime(value: 1, timescale: fps)
    let framesPerPhoto = max(1, Int(round(secondsPerPhoto * Double(fps))))
    let totalStandardFrameCount =
        max(
            1,
            photoURLs.count * framesPerPhoto
        )
    let fadeFrames = max(1, min(
        Int(round(fadeDuration * Double(fps))),
        max(1, Int(Double(framesPerPhoto) * 0.45))
    ))

    let writer = try AVAssetWriter(outputURL: outputURL, fileType: fileType)

    let pixelCount = renderSize.width * renderSize.height
    let shouldUseHEVC = resolutionName.trimmingCharacters(in: .whitespacesAndNewlines) == "Original" || pixelCount > 8_294_400
    let selectedCodec: AVVideoCodecType = shouldUseHEVC ? .hevc : .h264

    let compressionProperties: [String: Any]
    if selectedCodec == .hevc {
        compressionProperties = [
            AVVideoAverageBitRateKey: exportBitrate(for: renderSize),
            AVVideoMaxKeyFrameIntervalKey: 30,
            AVVideoExpectedSourceFrameRateKey: 30
        ]
    } else {
        compressionProperties = [
            AVVideoAverageBitRateKey: exportBitrate(for: renderSize),
            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            AVVideoMaxKeyFrameIntervalKey: 30,
            AVVideoExpectedSourceFrameRateKey: 30
        ]
    }

    let videoSettings: [String: Any] = [
        AVVideoCodecKey: selectedCodec,
        AVVideoWidthKey: Int(renderSize.width),
        AVVideoHeightKey: Int(renderSize.height),
        AVVideoCompressionPropertiesKey: compressionProperties
    ]

    print("BriefShow export codec:", selectedCodec.rawValue, "resolution:", resolutionName, "size:", Int(renderSize.width), "x", Int(renderSize.height))

    guard writer.canApply(outputSettings: videoSettings, forMediaType: .video) else {
        print("BriefShow export error: codec settings rejected", videoSettings)
        throw BriefShowExportError.cannotAddVideoInput
    }

    let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
    input.expectsMediaDataInRealTime = false

    let pixelBufferAttributes: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: Int(renderSize.width),
        kCVPixelBufferHeightKey as String: Int(renderSize.height),
        kCVPixelBufferCGImageCompatibilityKey as String: true,
        kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
    ]

    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: input,
        sourcePixelBufferAttributes: pixelBufferAttributes
    )

    guard writer.canAdd(input) else {
        throw BriefShowExportError.cannotAddVideoInput
    }

    writer.add(input)

    guard writer.startWriting() else {
        throw writer.error ?? BriefShowExportError.couldNotStartWriter
    }

    writer.startSession(atSourceTime: .zero)

    var frameNumber: Int64 = 0

    var previousImage: CGImage?

    for (photoIndex, url) in photoURLs.enumerated() {
        guard let cgImage = makeCGImage(from: url) else {
            continue
        }

        for frameIndex in 0..<framesPerPhoto {
            while !input.isReadyForMoreMediaData {
                Thread.sleep(forTimeInterval: 0.01)
            }

            let fadeProgress: CGFloat?
            var imageAlpha: CGFloat = 1

            if transitionStyle == .fade,
               let previousImage,
               frameIndex < fadeFrames {
                fadeProgress = CGFloat(frameIndex + 1) / CGFloat(fadeFrames)
            } else {
                fadeProgress = nil
            }

            if transitionStyle == .fade {
                let fadeDenominator = CGFloat(max(1, fadeFrames - 1))

                if photoIndex == 0, frameIndex < fadeFrames {
                    let fadeInAlpha = CGFloat(frameIndex) / fadeDenominator
                    imageAlpha = min(imageAlpha, max(0, min(1, fadeInAlpha)))
                }

                if photoIndex == photoURLs.count - 1, frameIndex >= framesPerPhoto - fadeFrames {
                    let fadeOutFrame = framesPerPhoto - 1 - frameIndex
                    let fadeOutAlpha = CGFloat(fadeOutFrame) / fadeDenominator
                    imageAlpha = min(imageAlpha, max(0, min(1, fadeOutAlpha)))
                }
            }

            guard let pixelBuffer = makePixelBuffer(
                from: cgImage,
                previousImage: previousImage,
                fadeProgress: fadeProgress,
                imageAlpha: imageAlpha,
                renderSize: renderSize,
                pixelBufferPool: adaptor.pixelBufferPool
            ) else {
                throw BriefShowExportError.couldNotCreatePixelBuffer
            }

            let presentationTime = CMTimeMultiply(frameDuration, multiplier: Int32(frameNumber))
            guard adaptor.append(pixelBuffer, withPresentationTime: presentationTime) else {
                throw writer.error ?? BriefShowExportError.couldNotAppendFrame
            }

            frameNumber += 1

            progressHandler(
                min(
                    1,
                    Double(frameNumber)
                    / Double(totalStandardFrameCount)
                )
            )
        }

        previousImage = cgImage
    }

    input.markAsFinished()

    let semaphore = DispatchSemaphore(value: 0)
    writer.finishWriting {
        semaphore.signal()
    }
    semaphore.wait()

    if writer.status == .failed {
        throw writer.error ?? BriefShowExportError.writerFailed
    }
}

private func origamiExportRenderSize(
    for resolutionName: String
) -> CGSize {
    switch resolutionName
        .trimmingCharacters(
            in: .whitespacesAndNewlines
        ) {

    case "480p":
        return CGSize(
            width: 854,
            height: 480
        )

    case "720p":
        return CGSize(
            width: 1280,
            height: 720
        )

    case "1080p":
        return CGSize(
            width: 1920,
            height: 1080
        )

    case "4K", "Original":
        // Origami is always a 16:9 full-screen composition.
        // "Original" means maximum Origami quality, not the
        // aspect ratio of the first imported photograph.
        return CGSize(
            width: 3840,
            height: 2160
        )

    default:
        return CGSize(
            width: 3840,
            height: 2160
        )
    }
}

// MARK: - Imagination export
//
// Imagination's live preview animates via SwiftUI @State + withAnimation,
// driven by real wall-clock timers. There is no "render at time T" hook,
// so exporting it requires a deterministic replica: every value that
// used to be an animated @State var is instead computed as a pure
// function of elapsed time (tau) using the same easing curves, and
// snapshotted frame-by-frame with ImageRenderer, mirroring the approach
// already used for Origami's SwiftUI export pipeline.

private struct ImaginationExportScene {
    let sceneIndex: Int
    let image: NSImage
    let secondaryImage: NSImage?
}

private func buildImaginationExportScenes(
    photoURLs: [URL]
) -> [ImaginationExportScene] {
    let loadedImages = photoURLs.map { NSImage(contentsOf: $0) }

    var scenes: [ImaginationExportScene] = []
    var index = 0

    while index < loadedImages.count {
        guard let image = loadedImages[index] else {
            index += 1
            continue
        }

        let isTwinCandidate =
            index % 3 == 1
            && index + 1 < loadedImages.count

        let secondaryImage: NSImage? =
            isTwinCandidate
            ? loadedImages[index + 1]
            : nil

        let isTwin =
            isTwinCandidate
            && secondaryImage != nil

        scenes.append(
            ImaginationExportScene(
                sceneIndex: index,
                image: image,
                secondaryImage: isTwin ? secondaryImage : nil
            )
        )

        index += isTwin ? 2 : 1
    }

    return scenes
}

// SwiftUI's timing curves are cubic Beziers. This solves the same
// curve (via bisection on the x(t) cubic) so exported frames match
// the live preview's easing instead of a plain linear ramp.
private func imaginationExportCubicBezier(
    _ x: Double,
    _ x1: Double,
    _ y1: Double,
    _ x2: Double,
    _ y2: Double
) -> Double {
    let targetX = min(1, max(0, x))

    func sample(_ t: Double, _ first: Double, _ second: Double) -> Double {
        let inverse = 1 - t
        return 3 * inverse * inverse * t * first
            + 3 * inverse * t * t * second
            + t * t * t
    }

    var low = 0.0
    var high = 1.0

    for _ in 0..<20 {
        let middle = (low + high) * 0.5

        if sample(middle, x1, x2) < targetX {
            low = middle
        } else {
            high = middle
        }
    }

    return sample((low + high) * 0.5, y1, y2)
}

private func imaginationExportBlurProgress(_ tau: Double) -> Double {
    let raw = min(1, max(0, tau / 1.35))
    return imaginationExportCubicBezier(raw, 0, 0, 0.58, 1)
}

private func imaginationExportColorProgress(_ tau: Double) -> Double {
    guard tau > 1.35 else {
        return 0
    }

    let raw = min(1, (tau - 1.35) / 1.5)
    return imaginationExportCubicBezier(raw, 0.42, 0, 0.58, 1)
}

private func imaginationExportDriftProgress(_ tau: Double) -> Double {
    let raw = min(1, max(0, tau / 17.0))
    return imaginationExportCubicBezier(raw, 0.04, 0.96, 0.13, 0.995)
}

private func imaginationExportDistantDriftProgress(_ tau: Double) -> Double {
    let raw = min(1, max(0, tau / 24.2))
    return imaginationExportCubicBezier(raw, 0.22, 0.62, 0.32, 1.0)
}

// Start/end targets for one scene's reveal animation. These mirror the
// per-scene constants computed in the live preview's triggerReveal(),
// with playbackRestartToken fixed at 0 (a fresh, non-restarted play).
private struct ImaginationRevealTargets {
    let revealStartScale: CGFloat
    let revealEndScale: CGFloat
    let revealStartOffsetX: CGFloat
    let revealEndOffsetX: CGFloat
    let revealStartOffsetY: CGFloat
    let revealEndOffsetY: CGFloat
    let revealStartTiltX: Double
    let revealEndTiltX: Double
    let revealStartTiltY: Double
    let revealEndTiltY: Double
    let revealStartRotationZ: Double
    let revealEndRotationZ: Double

    let secondaryStartScale: CGFloat
    let secondaryEndScale: CGFloat
    let secondaryStartOffsetX: CGFloat
    let secondaryEndOffsetX: CGFloat
    let secondaryStartOffsetY: CGFloat
    let secondaryEndOffsetY: CGFloat
    let secondaryStartTiltX: Double
    let secondaryEndTiltX: Double
    let secondaryStartTiltY: Double
    let secondaryEndTiltY: Double
    let secondaryStartRotationZ: Double
    let secondaryEndRotationZ: Double

    let distantStartScale: CGFloat
    let distantEndScale: CGFloat
    let distantStartOffsetX: CGFloat
    let distantEndOffsetX: CGFloat
    let distantStartOffsetY: CGFloat
    let distantEndOffsetY: CGFloat
    let distantStartTiltY: Double
    let distantEndTiltY: Double
    let distantStartRotationZ: Double
    let distantEndRotationZ: Double

    let secondaryDistantStartScale: CGFloat
    let secondaryDistantEndScale: CGFloat
    let secondaryDistantStartOffsetX: CGFloat
    let secondaryDistantEndOffsetX: CGFloat
    let secondaryDistantStartOffsetY: CGFloat
    let secondaryDistantEndOffsetY: CGFloat
    let secondaryDistantStartTiltY: Double
    let secondaryDistantEndTiltY: Double
    let secondaryDistantStartRotationZ: Double
    let secondaryDistantEndRotationZ: Double
}

private func computeImaginationRevealTargets(
    sceneIndex: Int,
    hasSecondary: Bool,
    sceneSize: CGSize
) -> ImaginationRevealTargets {
    let startsOnRight = sceneIndex.isMultiple(of: 2)
    let sideOffset: CGFloat = startsOnRight ? 190 : -190

    let motionSlot = (sceneIndex * 3) % 7
    let movementStyle = motionSlot % 3

    let usesThrownCornerMotion = motionSlot == 5
    let usesDiagonalThrownMotion = motionSlot == 6
    let usesTopCornerMotion = motionSlot == 4
    let usesCrossTiltMotion = motionSlot == 3

    let isAlternatingTwinScene = hasSecondary && sceneIndex % 3 == 1
    let twinSceneVariant = isAlternatingTwinScene ? (sceneIndex / 3) % 3 : 0
    let usesSecondTwinScene = isAlternatingTwinScene && twinSceneVariant == 1
    let usesTwoPhotoScene = isAlternatingTwinScene

    let startingOffsetX: CGFloat =
        usesTwoPhotoScene
        ? (
            startsOnRight
            ? sceneSize.width * (usesSecondTwinScene ? 0.66 : 0.54)
            : -(sceneSize.width * (usesSecondTwinScene ? 0.66 : 0.54))
        )
        : (
            usesThrownCornerMotion
            ? (startsOnRight ? sceneSize.width * 0.52 : -(sceneSize.width * 0.52))
            : (
                usesDiagonalThrownMotion
                ? (startsOnRight ? -(sceneSize.width * 0.34) : sceneSize.width * 0.34)
                : (
                    usesTopCornerMotion
                    ? (startsOnRight ? sceneSize.width * 0.38 : -(sceneSize.width * 0.38))
                    : sideOffset
                )
            )
        )

    let endingOffsetX: CGFloat =
        usesTwoPhotoScene
        ? (
            startsOnRight
            ? sceneSize.width * (usesSecondTwinScene ? 0.25 : 0.19)
            : -(sceneSize.width * (usesSecondTwinScene ? 0.25 : 0.19))
        )
        : sideOffset

    let startingOffsetY: CGFloat
    let endingOffsetY: CGFloat

    if usesSecondTwinScene {
        startingOffsetY = sceneSize.height * 0.07
        endingOffsetY = sceneSize.height * 0.035
    } else if usesThrownCornerMotion {
        startingOffsetY = -(sceneSize.height * 0.36)
        endingOffsetY = 18
    } else if usesDiagonalThrownMotion {
        startingOffsetY = -(sceneSize.height * 0.28)
        endingOffsetY = -26
    } else if usesTopCornerMotion {
        startingOffsetY = -(sceneSize.height * 0.46)
        endingOffsetY = 28
    } else if usesCrossTiltMotion {
        startingOffsetY = 72
        endingOffsetY = -34
    } else {
        switch movementStyle {
        case 1:
            startingOffsetY = -115
            endingOffsetY = 45
        case 2:
            startingOffsetY = 115
            endingOffsetY = -45
        default:
            startingOffsetY = 0
            endingOffsetY = 0
        }
    }

    let startingTiltX: Double =
        usesSecondTwinScene
        ? -5.0
        : (
            usesThrownCornerMotion
            ? -10.0
            : (
                usesDiagonalThrownMotion
                ? -6.5
                : (
                    usesTopCornerMotion
                    ? -8.0
                    : (usesCrossTiltMotion ? -1.5 : 0)
                )
            )
        )

    let endingTiltX: Double =
        usesSecondTwinScene
        ? 0.5
        : (
            usesThrownCornerMotion
            ? 2.5
            : (
                usesDiagonalThrownMotion
                ? 4.0
                : (
                    usesTopCornerMotion
                    ? 1.5
                    : (usesCrossTiltMotion ? 6.5 : 0)
                )
            )
        )

    let startingTiltY: Double =
        usesSecondTwinScene
        ? -9.0
        : (
            usesThrownCornerMotion
            ? (startsOnRight ? -18.0 : 18.0)
            : (
                usesDiagonalThrownMotion
                ? (startsOnRight ? 15.0 : -15.0)
                : (
                    usesTopCornerMotion
                    ? (startsOnRight ? -13.0 : 13.0)
                    : (
                        usesCrossTiltMotion
                        ? -12.0
                        : (startsOnRight ? -9.0 : 9.0)
                    )
                )
            )
        )

    let endingTiltY: Double =
        usesSecondTwinScene
        ? -1.2
        : (
            usesThrownCornerMotion
            ? (startsOnRight ? -2.5 : 2.5)
            : (
                usesDiagonalThrownMotion
                ? (startsOnRight ? -5.0 : 5.0)
                : (
                    usesTopCornerMotion
                    ? (startsOnRight ? -3.0 : 3.0)
                    : (
                        usesCrossTiltMotion
                        ? 7.0
                        : (startsOnRight ? -4.0 : 4.0)
                    )
                )
            )
        )

    let startingRotationZ: Double =
        usesSecondTwinScene
        ? 8.0
        : (
            usesThrownCornerMotion
            ? (startsOnRight ? 9.0 : -9.0)
            : (
                usesDiagonalThrownMotion
                ? (startsOnRight ? -8.0 : 8.0)
                : (
                    usesTopCornerMotion
                    ? (startsOnRight ? 6.0 : -6.0)
                    : (
                        usesCrossTiltMotion
                        ? 3.2
                        : (startsOnRight ? 2.4 : -2.4)
                    )
                )
            )
        )

    let endingRotationZ: Double =
        usesSecondTwinScene
        ? 0.8
        : (
            usesThrownCornerMotion
            ? (startsOnRight ? 0.6 : -0.6)
            : (
                usesDiagonalThrownMotion
                ? (startsOnRight ? 1.4 : -1.4)
                : (
                    usesTopCornerMotion
                    ? (startsOnRight ? 1.0 : -1.0)
                    : (
                        usesCrossTiltMotion
                        ? -1.8
                        : (startsOnRight ? 1.0 : -1.0)
                    )
                )
            )
        )

    let distantStartingX: CGFloat =
        startsOnRight ? -(sceneSize.width * 0.425) : sceneSize.width * 0.425

    let distantStartingY: CGFloat

    if startingOffsetY > 0 {
        distantStartingY = -(sceneSize.height * 0.34)
    } else if startingOffsetY < 0 {
        distantStartingY = sceneSize.height * 0.34
    } else {
        distantStartingY =
            sceneIndex.isMultiple(of: 4)
            ? -(sceneSize.height * 0.34)
            : sceneSize.height * 0.34
    }

    let distantStartingTiltY: Double = startsOnRight ? 5.0 : -5.0
    let distantEndingTiltY: Double = startsOnRight ? 3.0 : -3.0
    let distantStartingRotationZ: Double = startsOnRight ? -7.0 : 7.0
    let distantEndingRotationZ: Double = startsOnRight ? -5.0 : 5.0

    let distantEndingX: CGFloat =
        distantStartingX + (distantStartingX > 0 ? 22 : -22)

    let distantEndingY: CGFloat =
        distantStartingY + (distantStartingY > 0 ? 16 : -16)

    let secondaryStartsOnRight = !startsOnRight

    let secondaryStartingX: CGFloat =
        usesSecondTwinScene
        ? (
            secondaryStartsOnRight
            ? sceneSize.width * 0.62
            : -(sceneSize.width * 0.62)
        )
        : (
            secondaryStartsOnRight
            ? sceneSize.width * 0.54
            : -(sceneSize.width * 0.54)
        )

    let secondaryEndingX: CGFloat =
        usesSecondTwinScene
        ? (
            secondaryStartsOnRight
            ? sceneSize.width * 0.25
            : -(sceneSize.width * 0.25)
        )
        : (
            secondaryStartsOnRight
            ? sceneSize.width * 0.255
            : -(sceneSize.width * 0.255)
        )

    let secondaryStartingY: CGFloat =
        usesSecondTwinScene
        ? -(sceneSize.height * 0.16)
        : (
            startsOnRight
            ? sceneSize.height * 0.20
            : -(sceneSize.height * 0.18)
        )

    let secondaryEndingY: CGFloat =
        usesSecondTwinScene
        ? -(sceneSize.height * 0.055)
        : (
            startsOnRight
            ? sceneSize.height * 0.13
            : -(sceneSize.height * 0.12)
        )

    let secondaryStartingTiltX: Double =
        usesSecondTwinScene ? 19.0 : (startsOnRight ? 7.0 : -7.0)

    let secondaryEndingTiltX: Double =
        usesSecondTwinScene ? 5.0 : (startsOnRight ? 2.5 : -2.5)

    let secondaryStartingTiltY: Double =
        usesSecondTwinScene ? 36.0 : (secondaryStartsOnRight ? -15.0 : 15.0)

    let secondaryEndingTiltY: Double =
        usesSecondTwinScene ? 12.0 : (secondaryStartsOnRight ? -4.5 : 4.5)

    let secondaryStartingRotationZ: Double =
        usesSecondTwinScene ? -40.0 : (secondaryStartsOnRight ? 10.0 : -10.0)

    let secondaryEndingRotationZ: Double =
        usesSecondTwinScene ? -4.0 : (secondaryStartsOnRight ? 4.8 : -4.8)

    let secondaryDistantStartingX: CGFloat =
        secondaryStartsOnRight ? -(sceneSize.width * 0.43) : sceneSize.width * 0.43

    let secondaryDistantStartingY: CGFloat =
        secondaryStartingY > 0
        ? -(sceneSize.height * 0.31)
        : sceneSize.height * 0.31

    let secondaryDistantEndingX: CGFloat =
        secondaryDistantStartingX + (secondaryDistantStartingX > 0 ? 20 : -20)

    let secondaryDistantEndingY: CGFloat =
        secondaryDistantStartingY + (secondaryDistantStartingY > 0 ? 15 : -15)

    let revealStartScale: CGFloat =
        usesSecondTwinScene ? 1.45 : (usesTwoPhotoScene ? 1.08 : 1.50)

    let revealEndScale: CGFloat =
        usesSecondTwinScene ? 1.05 : (usesTwoPhotoScene ? 0.70 : 0.96)

    let secondaryStartScale: CGFloat =
        usesSecondTwinScene ? 0.62 : 1.02

    let secondaryEndScale: CGFloat =
        usesSecondTwinScene ? 0.42 : 0.68

    return ImaginationRevealTargets(
        revealStartScale: revealStartScale,
        revealEndScale: revealEndScale,
        revealStartOffsetX: startingOffsetX,
        revealEndOffsetX: endingOffsetX,
        revealStartOffsetY: startingOffsetY,
        revealEndOffsetY: endingOffsetY,
        revealStartTiltX: startingTiltX,
        revealEndTiltX: endingTiltX,
        revealStartTiltY: startingTiltY,
        revealEndTiltY: endingTiltY,
        revealStartRotationZ: startingRotationZ,
        revealEndRotationZ: endingRotationZ,

        secondaryStartScale: secondaryStartScale,
        secondaryEndScale: secondaryEndScale,
        secondaryStartOffsetX: secondaryStartingX,
        secondaryEndOffsetX: secondaryEndingX,
        secondaryStartOffsetY: secondaryStartingY,
        secondaryEndOffsetY: secondaryEndingY,
        secondaryStartTiltX: secondaryStartingTiltX,
        secondaryEndTiltX: secondaryEndingTiltX,
        secondaryStartTiltY: secondaryStartingTiltY,
        secondaryEndTiltY: secondaryEndingTiltY,
        secondaryStartRotationZ: secondaryStartingRotationZ,
        secondaryEndRotationZ: secondaryEndingRotationZ,

        distantStartScale: 1.56156,
        distantEndScale: 1.20666,
        distantStartOffsetX: distantStartingX,
        distantEndOffsetX: distantEndingX,
        distantStartOffsetY: distantStartingY,
        distantEndOffsetY: distantEndingY,
        distantStartTiltY: distantStartingTiltY,
        distantEndTiltY: distantEndingTiltY,
        distantStartRotationZ: distantStartingRotationZ,
        distantEndRotationZ: distantEndingRotationZ,

        secondaryDistantStartScale: 1.20,
        secondaryDistantEndScale: 0.92,
        secondaryDistantStartOffsetX: secondaryDistantStartingX,
        secondaryDistantEndOffsetX: secondaryDistantEndingX,
        secondaryDistantStartOffsetY: secondaryDistantStartingY,
        secondaryDistantEndOffsetY: secondaryDistantEndingY,
        secondaryDistantStartTiltY: secondaryStartsOnRight ? 5.0 : -5.0,
        secondaryDistantEndTiltY: secondaryStartsOnRight ? 3.0 : -3.0,
        secondaryDistantStartRotationZ: secondaryStartsOnRight ? -7.0 : 7.0,
        secondaryDistantEndRotationZ: secondaryStartsOnRight ? -5.0 : 5.0
    )
}

private struct ImaginationRevealState {
    var revealScale: CGFloat
    var revealBlur: CGFloat
    var revealSaturation: Double
    var revealBrightness: Double
    var revealContrast: Double
    var revealOffsetX: CGFloat
    var revealOffsetY: CGFloat
    var revealTiltX: Double
    var revealTiltY: Double
    var revealRotationZ: Double

    var secondaryScale: CGFloat
    var secondaryBlur: CGFloat
    var secondarySaturation: Double
    var secondaryBrightness: Double
    var secondaryContrast: Double
    var secondaryOffsetX: CGFloat
    var secondaryOffsetY: CGFloat
    var secondaryTiltX: Double
    var secondaryTiltY: Double
    var secondaryRotationZ: Double

    var secondaryDistantScale: CGFloat
    var secondaryDistantOffsetX: CGFloat
    var secondaryDistantOffsetY: CGFloat
    var secondaryDistantTiltY: Double
    var secondaryDistantRotationZ: Double

    var distantScale: CGFloat
    var distantOffsetX: CGFloat
    var distantOffsetY: CGFloat
    var distantTiltY: Double
    var distantRotationZ: Double
}

private func imaginationEvaluateReveal(
    _ targets: ImaginationRevealTargets,
    tau: Double
) -> ImaginationRevealState {
    let blurProgress = imaginationExportBlurProgress(tau)
    let colorProgress = imaginationExportColorProgress(tau)
    let driftProgress = imaginationExportDriftProgress(tau)
    let distantProgress = imaginationExportDistantDriftProgress(tau)

    func lerp(_ start: CGFloat, _ end: CGFloat, _ progress: Double) -> CGFloat {
        start + (end - start) * CGFloat(progress)
    }

    func lerpD(_ start: Double, _ end: Double, _ progress: Double) -> Double {
        start + (end - start) * progress
    }

    return ImaginationRevealState(
        revealScale: lerp(targets.revealStartScale, targets.revealEndScale, driftProgress),
        revealBlur: lerp(30, 0, blurProgress),
        revealSaturation: lerpD(0, 1, colorProgress),
        revealBrightness: lerpD(0.12, 0, colorProgress),
        revealContrast: lerpD(1.12, 1, colorProgress),
        revealOffsetX: lerp(targets.revealStartOffsetX, targets.revealEndOffsetX, driftProgress),
        revealOffsetY: lerp(targets.revealStartOffsetY, targets.revealEndOffsetY, driftProgress),
        revealTiltX: lerpD(targets.revealStartTiltX, targets.revealEndTiltX, driftProgress),
        revealTiltY: lerpD(targets.revealStartTiltY, targets.revealEndTiltY, driftProgress),
        revealRotationZ: lerpD(targets.revealStartRotationZ, targets.revealEndRotationZ, driftProgress),

        secondaryScale: lerp(targets.secondaryStartScale, targets.secondaryEndScale, driftProgress),
        secondaryBlur: lerp(30, 0, blurProgress),
        secondarySaturation: lerpD(0, 1, colorProgress),
        secondaryBrightness: lerpD(0.12, 0, colorProgress),
        secondaryContrast: lerpD(1.12, 1, colorProgress),
        secondaryOffsetX: lerp(targets.secondaryStartOffsetX, targets.secondaryEndOffsetX, driftProgress),
        secondaryOffsetY: lerp(targets.secondaryStartOffsetY, targets.secondaryEndOffsetY, driftProgress),
        secondaryTiltX: lerpD(targets.secondaryStartTiltX, targets.secondaryEndTiltX, driftProgress),
        secondaryTiltY: lerpD(targets.secondaryStartTiltY, targets.secondaryEndTiltY, driftProgress),
        secondaryRotationZ: lerpD(targets.secondaryStartRotationZ, targets.secondaryEndRotationZ, driftProgress),

        secondaryDistantScale: lerp(targets.secondaryDistantStartScale, targets.secondaryDistantEndScale, distantProgress),
        secondaryDistantOffsetX: lerp(targets.secondaryDistantStartOffsetX, targets.secondaryDistantEndOffsetX, distantProgress),
        secondaryDistantOffsetY: lerp(targets.secondaryDistantStartOffsetY, targets.secondaryDistantEndOffsetY, distantProgress),
        secondaryDistantTiltY: lerpD(targets.secondaryDistantStartTiltY, targets.secondaryDistantEndTiltY, distantProgress),
        secondaryDistantRotationZ: lerpD(targets.secondaryDistantStartRotationZ, targets.secondaryDistantEndRotationZ, distantProgress),

        distantScale: lerp(targets.distantStartScale, targets.distantEndScale, distantProgress),
        distantOffsetX: lerp(targets.distantStartOffsetX, targets.distantEndOffsetX, distantProgress),
        distantOffsetY: lerp(targets.distantStartOffsetY, targets.distantEndOffsetY, distantProgress),
        distantTiltY: lerpD(targets.distantStartTiltY, targets.distantEndTiltY, distantProgress),
        distantRotationZ: lerpD(targets.distantStartRotationZ, targets.distantEndRotationZ, distantProgress)
    )
}

// Deterministic replica of ImaginationDustOverlay's particle math, but
// painted straight onto the export CGContext (after the photo frame is
// drawn) instead of composited as a SwiftUI layer. ImageRenderer's
// offscreen snapshot doesn't reliably preserve zIndex ordering across
// .compositingGroup()/.mask() siblings, which is why dust used to be
// invisible or stuck behind the photo in exported video.
private func drawImaginationExportDustParticles(
    into context: CGContext,
    time: Double,
    elapsedSinceBurst: Double,
    burstToken: Int,
    size: CGSize,
    opacityMultiplier: Double,
    scale: CGFloat = 1,
    offset: CGSize = .zero
) {
    guard size.width > 0, size.height > 0 else {
        return
    }

    func random(_ value: Double) -> Double {
        let result = sin(value) * 43_758.545_312_3
        return result - floor(result)
    }

    func wrapped(_ value: Double, minimum: Double, maximum: Double) -> Double {
        let range = maximum - minimum
        guard range > 0 else {
            return value
        }
        var result = (value - minimum).truncatingRemainder(dividingBy: range)
        if result < 0 {
            result += range
        }
        return result + minimum
    }

    // Export renders at a much larger pixel size than the on-screen
    // preview, so the same particle count that reads as "dusty" in the
    // small preview canvas looks nearly empty spread across a 4K frame.
    // More particles (not bigger ones) keeps the same look at any size.
    let particleCount = 240
    let burstStrength = exp(-max(0, elapsedSinceBurst) * 0.78)
    let center = CGPoint(x: size.width / 2, y: size.height / 2)

    for index in 0..<particleCount {
        let seed = Double(index + 1)

        let xSeed = random(seed * 12.9898)
        let ySeed = random(seed * 78.233)
        let speedSeed = random(seed * 41.719)
        let phaseSeed = random(seed * 27.113)
        let radiusSeed = random(seed * 63.771)
        let opacitySeed = random(seed * 94.331)
        let directionSeed = random(seed * 36.173)

        let baseX = xSeed * size.width
        let baseY = ySeed * size.height

        let phase = phaseSeed * Double.pi * 2.0

        let baseSpeed = 0.10 + speedSeed * 0.18
        let secondarySpeed = 0.07 + random(seed * 17.477) * 0.14

        let horizontalRadius = 6.0 + radiusSeed * 20.0
        let verticalRadius = 5.0 + random(seed * 31.557) * 16.0

        let calmX =
            sin(time * baseSpeed + phase) * horizontalRadius
            + cos(time * secondarySpeed + phase * 0.7) * 5.0

        let calmY =
            cos(time * baseSpeed * 0.83 + phase) * verticalRadius
            + sin(time * secondarySpeed * 1.17 + phase * 1.2) * 4.0

        let sideDirection: Double = burstToken.isMultiple(of: 2) ? -1.0 : 1.0

        let particleDirection =
            directionSeed > 0.35
            ? sideDirection
            : -sideDirection * 0.35

        let gustSpeed = 1.8 + speedSeed * 2.8
        let gustDistance = burstStrength * (42.0 + radiusSeed * 76.0)

        let windX =
            sin(time * gustSpeed + phase) * gustDistance * particleDirection

        let windY =
            cos(time * (gustSpeed * 0.72) + phase * 1.4) * gustDistance * 0.38

        let swirlRadius = burstStrength * (15.0 + radiusSeed * 42.0)
        let swirlSpeed = 2.1 + speedSeed * 3.0

        let swirlX = cos(time * swirlSpeed + phase) * swirlRadius
        let swirlY = sin(time * swirlSpeed + phase) * swirlRadius * 0.72

        var x = baseX + calmX + windX + swirlX
        var y = baseY + calmY + windY + swirlY

        let margin = 30.0

        x = wrapped(x, minimum: -margin, maximum: size.width + margin)
        y = wrapped(y, minimum: -margin, maximum: size.height + margin)

        x = (x - center.x) * scale + center.x + offset.width
        y = (y - center.y) * scale + center.y + offset.height

        let particleSize = (0.7 + random(seed * 88.231) * 1.6) * scale

        let baseOpacity = 0.12 + opacitySeed * 0.38
        let gustOpacityBoost = burstStrength * 0.16

        let finalOpacity = min(0.72, baseOpacity + gustOpacityBoost) * opacityMultiplier

        let particleRect = CGRect(
            x: x - particleSize / 2,
            y: y - particleSize / 2,
            width: particleSize,
            height: particleSize
        )

        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: finalOpacity))
        context.fillEllipse(in: particleRect)
    }
}

// Deterministic replica of ImaginationLensLightOverlay, driven by an
// explicit elapsed value instead of TimelineView + Date.
private struct ImaginationExportLensFlareLayer: View {
    let elapsed: Double
    let sceneToken: Int

    private struct FlareGeometry {
        let sourcePoint: CGPoint
        let targetPoint: CGPoint
        let pulseA: Double
        let pulseB: Double
        let pulseC: Double
        let visibility: Double
    }

    // Plain (non-View) helper: a bare `switch` performing assignments
    // inside a @ViewBuilder closure (like GeometryReader's) gets
    // misparsed as if every case must produce a View. Computing the
    // geometry here, outside the ViewBuilder closure, avoids that.
    private func computeGeometry(width: CGFloat, height: CGFloat) -> FlareGeometry {
        let safeElapsed = max(0, elapsed)
        let flareDuration = 6.72

        let rawProgress = min(1, safeElapsed / flareDuration)

        let movementProgress =
            rawProgress * rawProgress * (3 - 2 * rawProgress)

        let visibility = min(1, safeElapsed / 0.22)

        let variant = abs(sceneToken) % 4

        let startX: CGFloat
        let endX: CGFloat
        let flareTargetX: CGFloat
        let flareTargetY: CGFloat

        switch variant {
        case 0:
            startX = width * 1.08
            endX = -(width * 0.58)
            flareTargetX = -(width * 0.34)
            flareTargetY = height * 0.72

        case 1:
            startX = -(width * 0.08)
            endX = width * 1.58
            flareTargetX = width * 1.34
            flareTargetY = height * 0.74

        case 2:
            startX = width * 0.96
            endX = -(width * 0.50)
            flareTargetX = -(width * 0.30)
            flareTargetY = height * 0.82

        default:
            startX = width * 0.04
            endX = width * 1.52
            flareTargetX = width * 1.30
            flareTargetY = height * 0.78
        }

        let sourceX = interpolate(from: startX, to: endX, progress: CGFloat(movementProgress))

        let sourcePoint = CGPoint(x: sourceX, y: -(height * 0.045))
        let targetPoint = CGPoint(x: flareTargetX, y: flareTargetY)

        let pulseA = 0.5 + 0.5 * sin(safeElapsed * 1.15 + Double(variant) * 0.63)
        let pulseB = 0.5 + 0.5 * sin(safeElapsed * 0.92 + 1.35 + Double(variant) * 0.31)
        let pulseC = 0.5 + 0.5 * sin(safeElapsed * 1.06 + 2.10 + Double(variant) * 0.22)

        return FlareGeometry(
            sourcePoint: sourcePoint,
            targetPoint: targetPoint,
            pulseA: pulseA,
            pulseB: pulseB,
            pulseC: pulseC,
            visibility: visibility
        )
    }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            let geometry = computeGeometry(width: width, height: height)

            ZStack {
                roundFlare(
                    diameter: width * (0.50 + 0.16 * geometry.pulseA),
                    opacity: 0.54 * geometry.visibility,
                    blur: 30
                )
                .position(
                    pointOnLine(
                        from: geometry.sourcePoint,
                        to: geometry.targetPoint,
                        progress: 0.26,
                        xOffset: width * 0.018,
                        yOffset: 0
                    )
                )

                roundFlare(
                    diameter: width * (0.28 + 0.10 * geometry.pulseB),
                    opacity: 0.46 * geometry.visibility,
                    blur: 19
                )
                .position(
                    pointOnLine(
                        from: geometry.sourcePoint,
                        to: geometry.targetPoint,
                        progress: 0.50,
                        xOffset: -(width * 0.025),
                        yOffset: height * 0.012
                    )
                )

                roundFlare(
                    diameter: width * (0.15 + 0.065 * geometry.pulseC),
                    opacity: 0.58 * geometry.visibility,
                    blur: 11
                )
                .position(
                    pointOnLine(
                        from: geometry.sourcePoint,
                        to: geometry.targetPoint,
                        progress: 0.72,
                        xOffset: width * 0.018,
                        yOffset: -(height * 0.008)
                    )
                )
            }
            .blendMode(.screen)
            .compositingGroup()
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
            .allowsHitTesting(false)
        }
    }

    private func interpolate(
        from start: CGFloat,
        to end: CGFloat,
        progress: CGFloat
    ) -> CGFloat {
        start + (end - start) * progress
    }

    private func pointOnLine(
        from source: CGPoint,
        to target: CGPoint,
        progress: CGFloat,
        xOffset: CGFloat,
        yOffset: CGFloat
    ) -> CGPoint {
        CGPoint(
            x: source.x + (target.x - source.x) * progress + xOffset,
            y: source.y + (target.y - source.y) * progress + yOffset
        )
    }

    private func roundFlare(
        diameter: CGFloat,
        opacity: Double,
        blur: CGFloat
    ) -> some View {
        Circle()
            .fill(
                RadialGradient(
                    stops: [
                        .init(color: Color.white.opacity(0.10), location: 0),
                        .init(color: Color(red: 1.0, green: 0.78, blue: 0.46).opacity(0.24), location: 0.40),
                        .init(color: Color(red: 0.68, green: 0.82, blue: 1.0).opacity(0.11), location: 0.68),
                        .init(color: Color.white.opacity(0.07), location: 0.86),
                        .init(color: Color.clear, location: 1)
                    ],
                    center: .center,
                    startRadius: 0,
                    endRadius: diameter * 0.50
                )
            )
            .overlay(
                Circle()
                    .stroke(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.15),
                                Color(red: 1.0, green: 0.72, blue: 0.42).opacity(0.11),
                                Color.white.opacity(0.04)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1.8
                    )
                    .blur(radius: 3)
            )
            .frame(width: diameter, height: diameter)
            .blur(radius: blur)
            .opacity(opacity)
    }
}

// Stateless, parametric replica of ImaginationCardPage's body: every
// value that used to be an animated @State var is passed in already
// evaluated at this frame's tau, so ImageRenderer can snapshot it.
private struct ImaginationExportSceneView: View {
    let activeImage: NSImage?
    let secondaryImage: NSImage?
    let sceneIndex: Int
    let hasSecondary: Bool
    let tau: Double
    let globalTime: Double
    let blackOverlayOpacity: Double
    let state: ImaginationRevealState

    private var isAlternatingTwinScene: Bool {
        hasSecondary && sceneIndex % 3 == 1
    }

    private var twinSceneVariant: Int {
        guard isAlternatingTwinScene else {
            return 0
        }

        return (sceneIndex / 3) % 3
    }

    private var usesSecondTwinScene: Bool {
        isAlternatingTwinScene && twinSceneVariant == 1
    }

    private var usesTwoPhotoScene: Bool {
        isAlternatingTwinScene
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black

                if let activeImage {
                    let imageRatio = max(
                        0.01,
                        activeImage.size.width / max(1, activeImage.size.height)
                    )

                    let availableWidth = proxy.size.width * 0.72
                    let availableHeight = proxy.size.height * 0.76

                    let cardSize: CGSize = {
                        let availableRatio = availableWidth / availableHeight

                        if imageRatio > availableRatio {
                            return CGSize(width: availableWidth, height: availableWidth / imageRatio)
                        } else {
                            return CGSize(width: availableHeight * imageRatio, height: availableHeight)
                        }
                    }()

                    let secondaryCardSize: CGSize? = {
                        guard let secondaryImage else {
                            return nil
                        }

                        let secondaryRatio = max(
                            0.01,
                            secondaryImage.size.width / max(1, secondaryImage.size.height)
                        )

                        let secondaryAvailableWidth = proxy.size.width * 0.48
                        let secondaryAvailableHeight = proxy.size.height * 0.54
                        let secondaryAvailableRatio = secondaryAvailableWidth / secondaryAvailableHeight

                        if secondaryRatio > secondaryAvailableRatio {
                            return CGSize(width: secondaryAvailableWidth, height: secondaryAvailableWidth / secondaryRatio)
                        }

                        return CGSize(width: secondaryAvailableHeight * secondaryRatio, height: secondaryAvailableHeight)
                    }()

                    ZStack {
                        Image(nsImage: activeImage)
                            .resizable()
                            .scaledToFill()
                            .frame(width: cardSize.width, height: cardSize.height)
                            .clipped()
                            .blur(radius: 16)
                            .saturation(0)
                            .brightness(-0.08)
                            .contrast(0.92)

                        Color.black.opacity(0.20)
                    }
                    .frame(width: cardSize.width, height: cardSize.height)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .mask(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color.white.opacity(0.80))
                            .padding(30)
                            .blur(radius: 24)
                    )
                    .compositingGroup()
                    .rotation3DEffect(.degrees(state.distantTiltY), axis: (x: 0, y: 1, z: 0), perspective: 0.55)
                    .rotationEffect(.degrees(state.distantRotationZ))
                    .scaleEffect(state.distantScale)
                    .offset(x: state.distantOffsetX, y: state.distantOffsetY)
                    .opacity(0.62)
                    .zIndex(5)

                    if usesTwoPhotoScene, let secondaryImage, let secondaryCardSize {
                        ZStack {
                            Image(nsImage: secondaryImage)
                                .resizable()
                                .scaledToFill()
                                .frame(
                                    width: secondaryCardSize.width * (usesSecondTwinScene ? 1.55 : 1.0),
                                    height: secondaryCardSize.height * (usesSecondTwinScene ? 1.55 : 1.0)
                                )
                                .clipped()
                                .blur(radius: 16)
                                .saturation(0)
                                .brightness(-0.08)
                                .contrast(0.92)

                            Color.black.opacity(0.20)
                        }
                        .frame(
                            width: secondaryCardSize.width * (usesSecondTwinScene ? 1.55 : 1.0),
                            height: secondaryCardSize.height * (usesSecondTwinScene ? 1.55 : 1.0)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .mask(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(Color.white.opacity(0.80))
                                .padding(30)
                                .blur(radius: 24)
                        )
                        .compositingGroup()
                        .rotation3DEffect(.degrees(state.secondaryDistantTiltY), axis: (x: 0, y: 1, z: 0), perspective: 0.55)
                        .rotationEffect(.degrees(state.secondaryDistantRotationZ))
                        .scaleEffect(state.secondaryDistantScale)
                        .offset(x: state.secondaryDistantOffsetX, y: state.secondaryDistantOffsetY)
                        .opacity(0.62)
                        .zIndex(6)

                        ZStack {
                            Image(nsImage: secondaryImage)
                                .resizable()
                                .scaledToFill()
                                .frame(
                                    width: secondaryCardSize.width * (usesSecondTwinScene ? 1.55 : 1.0),
                                    height: secondaryCardSize.height * (usesSecondTwinScene ? 1.55 : 1.0)
                                )
                                .clipped()
                                .saturation(state.secondarySaturation)
                                .brightness(state.secondaryBrightness)
                                .contrast(state.secondaryContrast)
                                .blur(radius: state.secondaryBlur)
                        }
                        .frame(
                            width: secondaryCardSize.width * (usesSecondTwinScene ? 1.55 : 1.0),
                            height: secondaryCardSize.height * (usesSecondTwinScene ? 1.55 : 1.0)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .compositingGroup()
                        .rotation3DEffect(.degrees(state.secondaryTiltY), axis: (x: 0, y: 1, z: 0), perspective: 0.55)
                        .rotation3DEffect(.degrees(state.secondaryTiltX), axis: (x: 1, y: 0, z: 0), perspective: 0.55)
                        .rotationEffect(.degrees(state.secondaryRotationZ))
                        .scaleEffect(
                            state.secondaryScale
                            * (secondaryCardSize.height > secondaryCardSize.width ? 1.50 : 1.0)
                        )
                        .offset(x: state.secondaryOffsetX, y: state.secondaryOffsetY)
                        .zIndex(12)
                    }

                    ZStack {
                        Image(nsImage: activeImage)
                            .resizable()
                            .scaledToFill()
                            .frame(
                                width: cardSize.width * (usesSecondTwinScene ? 0.70 : 1.0),
                                height: cardSize.height * (usesSecondTwinScene ? 0.70 : 1.0)
                            )
                            .clipped()
                            .saturation(state.revealSaturation)
                            .brightness(state.revealBrightness)
                            .contrast(state.revealContrast)
                            .blur(radius: state.revealBlur)
                    }
                    .frame(
                        width: cardSize.width * (usesSecondTwinScene ? 0.70 : 1.0),
                        height: cardSize.height * (usesSecondTwinScene ? 0.70 : 1.0)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .compositingGroup()
                    .rotation3DEffect(.degrees(state.revealTiltY), axis: (x: 0, y: 1, z: 0), perspective: 0.55)
                    .rotation3DEffect(.degrees(state.revealTiltX), axis: (x: 1, y: 0, z: 0), perspective: 0.55)
                    .rotationEffect(.degrees(state.revealRotationZ))
                    .scaleEffect(
                        state.revealScale
                        * (
                            cardSize.height > cardSize.width
                            ? (usesTwoPhotoScene ? 1.50 : 1.10)
                            : 1.0
                        )
                    )
                    .offset(x: state.revealOffsetX, y: state.revealOffsetY)
                    .zIndex(10)
                }

                ImaginationExportLensFlareLayer(elapsed: tau, sceneToken: sceneIndex)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .allowsHitTesting(false)
                    .zIndex(18)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
    }
}

private func makeImaginationExportCGImage(
    scene: ImaginationExportScene,
    state: ImaginationRevealState,
    tau: Double,
    globalTime: Double,
    blackOverlayOpacity: Double,
    renderSize: CGSize
) -> CGImage? {
    var renderedImage: CGImage?

    let renderBlock = {
        let frameView = ImaginationExportSceneView(
            activeImage: scene.image,
            secondaryImage: scene.secondaryImage,
            sceneIndex: scene.sceneIndex,
            hasSecondary: scene.secondaryImage != nil,
            tau: tau,
            globalTime: globalTime,
            blackOverlayOpacity: blackOverlayOpacity,
            state: state
        )
        .frame(width: renderSize.width, height: renderSize.height)
        .background(Color.black)

        let renderer = ImageRenderer(content: frameView)
        renderer.proposedSize = ProposedViewSize(width: renderSize.width, height: renderSize.height)
        renderer.scale = 1

        renderedImage = renderer.cgImage
    }

    if Thread.isMainThread {
        renderBlock()
    } else {
        DispatchQueue.main.sync(execute: renderBlock)
    }

    return renderedImage
}

private func makeImaginationExportPixelBuffer(
    scene: ImaginationExportScene,
    state: ImaginationRevealState,
    tau: Double,
    globalTime: Double,
    blackOverlayOpacity: Double,
    renderSize: CGSize,
    pixelBufferPool: CVPixelBufferPool?
) -> CVPixelBuffer? {
    guard let pixelBufferPool,
          let frameImage = makeImaginationExportCGImage(
            scene: scene,
            state: state,
            tau: tau,
            globalTime: globalTime,
            blackOverlayOpacity: blackOverlayOpacity,
            renderSize: renderSize
          )
    else {
        return nil
    }

    var pixelBuffer: CVPixelBuffer?

    let status = CVPixelBufferPoolCreatePixelBuffer(nil, pixelBufferPool, &pixelBuffer)

    guard status == kCVReturnSuccess, let pixelBuffer else {
        return nil
    }

    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

    guard let context = CGContext(
        data: CVPixelBufferGetBaseAddress(pixelBuffer),
        width: Int(renderSize.width),
        height: Int(renderSize.height),
        bitsPerComponent: 8,
        bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    ) else {
        return nil
    }

    let canvasRect = CGRect(origin: .zero, size: renderSize)

    context.setFillColor(NSColor.black.cgColor)
    context.fill(canvasRect)
    context.interpolationQuality = .high
    context.draw(frameImage, in: canvasRect)

    // Dust is painted directly onto the bitmap (after the photo, before the
    // fade-to-black) instead of going through ImageRenderer, so it's
    // guaranteed to land on top of the photo the same way it does in the
    // live preview. Flip to a top-left origin first since Core Graphics
    // primitive fills (unlike image draws) use the context's native
    // bottom-left coordinate space.
    context.saveGState()
    context.translateBy(x: 0, y: renderSize.height)
    context.scaleBy(x: 1, y: -1)

    drawImaginationExportDustParticles(
        into: context,
        time: globalTime * 1.30,
        elapsedSinceBurst: tau,
        burstToken: scene.sceneIndex,
        size: renderSize,
        opacityMultiplier: 0.95
    )

    drawImaginationExportDustParticles(
        into: context,
        time: globalTime * 1.30,
        elapsedSinceBurst: tau,
        burstToken: scene.sceneIndex,
        size: renderSize,
        opacityMultiplier: 0.65,
        scale: 1.08,
        offset: CGSize(width: 0, height: 24)
    )

    context.restoreGState()

    if blackOverlayOpacity > 0 {
        context.setFillColor(NSColor.black.withAlphaComponent(blackOverlayOpacity).cgColor)
        context.fill(canvasRect)
    }

    return pixelBuffer
}

private func renderImaginationSlideshowVideo(
    photoURLs: [URL],
    outputURL: URL,
    resolutionName: String,
    pageDuration: Double,
    fadeDuration: Double,
    fileType: AVFileType = .mp4,
    progressHandler: @escaping @Sendable (Double) -> Void
) throws {
    if FileManager.default.fileExists(atPath: outputURL.path) {
        try FileManager.default.removeItem(at: outputURL)
    }

    let scenes = buildImaginationExportScenes(photoURLs: photoURLs)

    guard !scenes.isEmpty else {
        throw BriefShowExportError.couldNotCreatePixelBuffer
    }

    let renderSize = exportRenderSize(for: resolutionName, photoURLs: photoURLs)
    let fps: Int32 = 30

    let safePageDuration = max(1.0, pageDuration)

    let totalTransitionDuration = min(
        max(fadeDuration, 0.36),
        max(0.36, safePageDuration * 0.45)
    )

    let closingDuration = totalTransitionDuration * 0.48
    let openingDuration = totalTransitionDuration * 0.52

    // Intro: 3s black fade (1 -> 0) laid over the very start. Outro: 4s
    // black fade (0 -> 1) at the very end. Both extend the total export
    // duration. The reveal animation itself runs continuously and
    // normally the whole time, starting immediately at t=0 underneath
    // the intro fade (matching how inter-page transitions already work) —
    // the overlay is purely cosmetic, it never holds the animation back.
    let introDuration = 3.0
    let outroDuration = 4.0

    // Scene 0 gets its window front-padded by introDuration: its own
    // reveal clock starts at t=0 and simply keeps running underneath
    // the fade, so there is no discontinuity once the fade clears.
    let scene0Window = introDuration + safePageDuration
    let laterSceneWindow = safePageDuration

    let mainDuration = scene0Window + Double(max(0, scenes.count - 1)) * laterSceneWindow
    let totalDuration = mainDuration + outroDuration
    let totalFrameCount = max(1, Int(ceil(totalDuration * Double(fps))))

    func windowStart(_ ordinal: Int) -> Double {
        ordinal <= 0
            ? 0
            : scene0Window + Double(ordinal - 1) * laterSceneWindow
    }

    // The moment each scene's own reveal clock hits tau == 0: scene 0
    // starts immediately at t=0; every later scene starts right after
    // the closing (fade-to-black) tail of the previous scene finishes.
    func revealStart(_ ordinal: Int) -> Double {
        ordinal <= 0 ? 0 : windowStart(ordinal) + closingDuration
    }

    let writer = try AVAssetWriter(outputURL: outputURL, fileType: fileType)

    let pixelCount = renderSize.width * renderSize.height
    let shouldUseHEVC =
        resolutionName.trimmingCharacters(in: .whitespacesAndNewlines) == "Original"
        || pixelCount > 8_294_400

    let codec: AVVideoCodecType = shouldUseHEVC ? .hevc : .h264

    let compressionProperties: [String: Any] = [
        AVVideoAverageBitRateKey: exportBitrate(for: renderSize),
        AVVideoMaxKeyFrameIntervalKey: 30,
        AVVideoExpectedSourceFrameRateKey: 30
    ]

    let videoSettings: [String: Any] = [
        AVVideoCodecKey: codec,
        AVVideoWidthKey: Int(renderSize.width),
        AVVideoHeightKey: Int(renderSize.height),
        AVVideoCompressionPropertiesKey: compressionProperties
    ]

    guard writer.canApply(outputSettings: videoSettings, forMediaType: .video) else {
        throw BriefShowExportError.cannotAddVideoInput
    }

    let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
    input.expectsMediaDataInRealTime = false

    let pixelBufferAttributes: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: Int(renderSize.width),
        kCVPixelBufferHeightKey as String: Int(renderSize.height),
        kCVPixelBufferCGImageCompatibilityKey as String: true,
        kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
    ]

    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: input,
        sourcePixelBufferAttributes: pixelBufferAttributes
    )

    guard writer.canAdd(input) else {
        throw BriefShowExportError.cannotAddVideoInput
    }

    writer.add(input)

    guard writer.startWriting() else {
        throw writer.error ?? BriefShowExportError.couldNotStartWriter
    }

    writer.startSession(atSourceTime: .zero)

    var targetsCache: [Int: ImaginationRevealTargets] = [:]

    func targets(for sceneOrdinal: Int) -> ImaginationRevealTargets {
        if let cached = targetsCache[sceneOrdinal] {
            return cached
        }

        let scene = scenes[sceneOrdinal]

        let computed = computeImaginationRevealTargets(
            sceneIndex: scene.sceneIndex,
            hasSecondary: scene.secondaryImage != nil,
            sceneSize: renderSize
        )

        targetsCache[sceneOrdinal] = computed
        return computed
    }

    var frameNumber: Int64 = 0
    let frameDuration = CMTime(value: 1, timescale: fps)

    for frameIndex in 0..<totalFrameCount {
        while !input.isReadyForMoreMediaData {
            Thread.sleep(forTimeInterval: 0.004)
        }

        let globalTime = Double(frameIndex) / Double(fps)

        let sceneOrdinal: Int
        var overlayOpacity: Double

        if globalTime >= mainDuration {
            // Hold on the last scene — its own reveal/drift keeps
            // progressing continuously while black fades in.
            let outroLocal = globalTime - mainDuration

            sceneOrdinal = scenes.count - 1

            overlayOpacity = imaginationExportCubicBezier(
                outroLocal / outroDuration, 0.42, 0, 0.58, 1
            )
        } else {
            let pageOrdinal: Int = {
                guard globalTime >= scene0Window else {
                    return 0
                }

                return min(
                    scenes.count - 1,
                    1 + Int((globalTime - scene0Window) / laterSceneWindow)
                )
            }()

            let localTime = globalTime - windowStart(pageOrdinal)

            if pageOrdinal == 0 {
                sceneOrdinal = 0

                // The closing-to-black transition into page 1 (if any)
                // is owned entirely by page 1's own window below —
                // computing it here too would double it up and cause
                // a visible flicker right at the boundary.
                if localTime < introDuration {
                    let introProgress = imaginationExportCubicBezier(
                        localTime / introDuration, 0.42, 0, 0.58, 1
                    )
                    overlayOpacity = 1 - introProgress
                } else {
                    overlayOpacity = 0
                }
            } else if localTime < closingDuration {
                sceneOrdinal = pageOrdinal - 1

                let p = min(1, max(0, localTime / closingDuration)) * 0.5
                overlayOpacity = 1 - abs(1 - 2 * p)
            } else if localTime < closingDuration + openingDuration {
                sceneOrdinal = pageOrdinal

                let openingLocal = localTime - closingDuration
                let p = 0.5 + min(1, max(0, openingLocal / openingDuration)) * 0.5
                overlayOpacity = 1 - abs(1 - 2 * p)
            } else {
                sceneOrdinal = pageOrdinal
                overlayOpacity = 0
            }
        }

        let tau = globalTime - revealStart(sceneOrdinal)
        let scene = scenes[sceneOrdinal]
        let sceneTargets = targets(for: sceneOrdinal)
        let state = imaginationEvaluateReveal(sceneTargets, tau: tau)

        guard let pixelBuffer = makeImaginationExportPixelBuffer(
            scene: scene,
            state: state,
            tau: tau,
            globalTime: globalTime,
            blackOverlayOpacity: overlayOpacity,
            renderSize: renderSize,
            pixelBufferPool: adaptor.pixelBufferPool
        ) else {
            throw BriefShowExportError.couldNotCreatePixelBuffer
        }

        let presentationTime = CMTimeMultiply(frameDuration, multiplier: Int32(frameNumber))
        guard adaptor.append(pixelBuffer, withPresentationTime: presentationTime) else {
            throw writer.error ?? BriefShowExportError.couldNotAppendFrame
        }

        frameNumber += 1

        progressHandler(min(1, Double(frameNumber) / Double(totalFrameCount)))
    }

    input.markAsFinished()

    let semaphore = DispatchSemaphore(value: 0)
    writer.finishWriting {
        semaphore.signal()
    }
    semaphore.wait()

    if writer.status == .failed {
        throw writer.error ?? BriefShowExportError.writerFailed
    }
}

private func exportRenderSize(for resolutionName: String, photoURLs: [URL]) -> CGSize {
    if resolutionName == "480p" {
        return CGSize(width: 854, height: 480)
    }

    if resolutionName == "720p" {
        return CGSize(width: 1280, height: 720)
    }

    if resolutionName == "1080p" {
        return CGSize(width: 1920, height: 1080)
    }

    if resolutionName == "4K" {
        return CGSize(width: 3840, height: 2160)
    }

    if resolutionName == "Original",
       let firstURL = photoURLs.first,
       let image = makeCGImage(from: firstURL) {
        return evenSize(width: image.width, height: image.height)
    }

    return CGSize(width: 3840, height: 2160)
}

private func evenSize(width: Int, height: Int) -> CGSize {
    CGSize(
        width: max(2, width - (width % 2)),
        height: max(2, height - (height % 2))
    )
}

private func exportBitrate(for size: CGSize) -> Int {
    let pixels = size.width * size.height

    if pixels >= 3840 * 2160 {
        return 45_000_000
    }

    if pixels >= 1920 * 1080 {
        return 16_000_000
    }

    if pixels >= 1280 * 720 {
        return 8_000_000
    }

    return 4_000_000
}

private func makeCGImage(from url: URL) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
        return nil
    }

    let sourceProperties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    let pixelWidth = sourceProperties?[kCGImagePropertyPixelWidth] as? Int ?? 0
    let pixelHeight = sourceProperties?[kCGImagePropertyPixelHeight] as? Int ?? 0
    let maxPixelSize = max(pixelWidth, pixelHeight, 1)

    guard let orientedImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        kCGImageSourceShouldCache: true,
        kCGImageSourceShouldAllowFloat: false
    ] as CFDictionary) else {
        return nil
    }

    let width = orientedImage.width
    let height = orientedImage.height

    guard width > 0, height > 0 else {
        return nil
    }

    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        return orientedImage
    }

    context.interpolationQuality = .high
    context.draw(orientedImage, in: CGRect(x: 0, y: 0, width: width, height: height))

    return context.makeImage() ?? orientedImage
}

private func makePixelBuffer(
    from cgImage: CGImage,
    previousImage: CGImage?,
    fadeProgress: CGFloat?,
    imageAlpha: CGFloat = 1,
    renderSize: CGSize,
    pixelBufferPool: CVPixelBufferPool?
) -> CVPixelBuffer? {
    guard let pixelBufferPool else {
        return nil
    }

    var pixelBuffer: CVPixelBuffer?
    let status = CVPixelBufferPoolCreatePixelBuffer(nil, pixelBufferPool, &pixelBuffer)

    guard status == kCVReturnSuccess, let pixelBuffer else {
        return nil
    }

    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    defer {
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
    }

    guard let context = CGContext(
        data: CVPixelBufferGetBaseAddress(pixelBuffer),
        width: Int(renderSize.width),
        height: Int(renderSize.height),
        bitsPerComponent: 8,
        bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    ) else {
        return nil
    }

    context.setFillColor(NSColor.black.cgColor)
    context.fill(CGRect(origin: .zero, size: renderSize))
    context.interpolationQuality = .high

    if let previousImage, let fadeProgress {
        let previousRect = aspectFitRect(
            imageSize: CGSize(width: previousImage.width, height: previousImage.height),
            canvasSize: renderSize
        )

        context.saveGState()
        context.setAlpha(1)
        context.draw(previousImage, in: previousRect)
        context.restoreGState()

        let drawRect = aspectFitRect(
            imageSize: CGSize(width: cgImage.width, height: cgImage.height),
            canvasSize: renderSize
        )

        context.saveGState()
        context.setAlpha(fadeProgress * imageAlpha)
        context.draw(cgImage, in: drawRect)
        context.restoreGState()
    } else {
        let drawRect = aspectFitRect(
            imageSize: CGSize(width: cgImage.width, height: cgImage.height),
            canvasSize: renderSize
        )

        context.saveGState()
        context.setAlpha(imageAlpha)
        context.draw(cgImage, in: drawRect)
        context.restoreGState()
    }

    return pixelBuffer
}

private func aspectFitRect(imageSize: CGSize, canvasSize: CGSize) -> CGRect {
    guard imageSize.width > 0, imageSize.height > 0 else {
        return CGRect(origin: .zero, size: canvasSize)
    }

    let imageAspect = imageSize.width / imageSize.height
    let canvasAspect = canvasSize.width / canvasSize.height

    let drawSize: CGSize

    if imageAspect > canvasAspect {
        drawSize = CGSize(
            width: canvasSize.width,
            height: canvasSize.width / imageAspect
        )
    } else {
        drawSize = CGSize(
            width: canvasSize.height * imageAspect,
            height: canvasSize.height
        )
    }

    return CGRect(
        x: (canvasSize.width - drawSize.width) / 2,
        y: (canvasSize.height - drawSize.height) / 2,
        width: drawSize.width,
        height: drawSize.height
    )
}


private func temporaryVideoURL(for outputURL: URL) -> URL {
    let tempName = "BriefShow-video-only-\(UUID().uuidString).mp4"
    return FileManager.default.temporaryDirectory.appendingPathComponent(tempName)
}

private func loadAssetFullySynchronously(_ asset: AVURLAsset) {
    let semaphore = DispatchSemaphore(value: 0)
    asset.loadValuesAsynchronously(forKeys: ["tracks", "duration", "playable"]) {
        semaphore.signal()
    }
    semaphore.wait()
}

private func convertMusicURLToAAC(_ sourceURL: URL) throws -> URL {
    let sourceAsset = AVURLAsset(url: sourceURL)

    let tempURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("m4a")

    guard let exportSession = AVAssetExportSession(
        asset: sourceAsset,
        presetName: AVAssetExportPresetAppleM4A
    ) else {
        throw BriefShowExportError.couldNotExportWithAudio
    }

    exportSession.outputURL = tempURL
    exportSession.outputFileType = .m4a

    let semaphore = DispatchSemaphore(value: 0)
    exportSession.exportAsynchronously {
        semaphore.signal()
    }
    semaphore.wait()

    guard exportSession.status == .completed else {
        print(
            "BriefShow mux: FAILED converting music to AAC:",
            sourceURL.lastPathComponent,
            String(describing: exportSession.error)
        )
        throw exportSession.error ?? BriefShowExportError.couldNotExportWithAudio
    }

    print("BriefShow mux: converted", sourceURL.lastPathComponent, "-> AAC temp file")

    return tempURL
}

private func muxVideoWithMusic(
    videoURL: URL,
    musicURLs: [URL],
    outputURL: URL,
    outputFileType: AVFileType = .mp4,
    fadeInSeconds: Double,
    fadeOutSeconds: Double,
    preferHEVC: Bool,
    forcedFrameRate: Int32? = nil,
    forcedRenderSize: CGSize? = nil
) throws {
    if FileManager.default.fileExists(atPath: outputURL.path) {
        try FileManager.default.removeItem(at: outputURL)
    }

    let videoAsset = AVURLAsset(url: videoURL)
    loadAssetFullySynchronously(videoAsset)
    let composition = AVMutableComposition()

    guard let sourceVideoTrack = videoAsset.tracks(withMediaType: .video).first,
          let compositionVideoTrack = composition.addMutableTrack(
              withMediaType: .video,
              preferredTrackID: kCMPersistentTrackID_Invalid
          ) else {
        throw BriefShowExportError.couldNotExportWithAudio
    }

    let videoDuration = videoAsset.duration
    print("BriefShow mux: videoDuration =", videoDuration, "isValid:", videoDuration.isValid)
    do {
        try compositionVideoTrack.insertTimeRange(
            CMTimeRange(start: .zero, duration: videoDuration),
            of: sourceVideoTrack,
            at: .zero
        )
    } catch {
        print("BriefShow mux FAILED at video insertTimeRange:", String(describing: error))
        throw error
    }
    compositionVideoTrack.preferredTransform = sourceVideoTrack.preferredTransform

    var forcedVideoComposition:
        AVMutableVideoComposition?

    if let forcedFrameRate,
       forcedFrameRate > 0 {

        let targetRenderSize =
            forcedRenderSize
            ?? sourceVideoTrack.naturalSize

        let videoComposition =
            AVMutableVideoComposition()

        videoComposition.renderSize =
            targetRenderSize

        videoComposition.frameDuration =
            CMTime(
                value: 1,
                timescale:
                    forcedFrameRate
            )

        let instruction =
            AVMutableVideoCompositionInstruction()

        instruction.timeRange =
            CMTimeRange(
                start: .zero,
                duration:
                    videoDuration
            )

        let layerInstruction =
            AVMutableVideoCompositionLayerInstruction(
                assetTrack:
                    compositionVideoTrack
            )

        layerInstruction.setTransform(
            sourceVideoTrack
                .preferredTransform,
            at: .zero
        )

        instruction.layerInstructions = [
            layerInstruction
        ]

        videoComposition.instructions = [
            instruction
        ]

        forcedVideoComposition =
            videoComposition

        print(
            "BriefShow mux forced video:",
            Int(targetRenderSize.width),
            "x",
            Int(targetRenderSize.height),
            "@",
            forcedFrameRate,
            "fps"
        )
    }

    var audioMix: AVMutableAudioMix?

    var musicSources: [
        (
            asset: AVURLAsset,
            track: AVAssetTrack,
            duration: CMTime,
            startTime: CMTime
        )
    ] = []

    var temporaryMusicURLs: [URL] = []

    defer {
        for temporaryURL in temporaryMusicURLs {
            try? FileManager.default.removeItem(
                at: temporaryURL
            )
        }
    }

    for url in musicURLs {
        let didStartAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        print(
            "BriefShow mux: security-scoped access started =",
            didStartAccess,
            "for",
            url.lastPathComponent
        )

        let convertedURL: URL

        do {
            convertedURL = try convertMusicURLToAAC(url)
        } catch {
            print(
                "BriefShow mux: SKIPPING music track, AAC conversion failed:",
                url.lastPathComponent,
                String(describing: error)
            )
            continue
        }

        temporaryMusicURLs.append(
            convertedURL
        )

        let asset = AVURLAsset(
            url: convertedURL
        )

        loadAssetFullySynchronously(
            asset
        )

        let assetDuration =
            asset.duration

        let audioTracks =
            asset.tracks(
                withMediaType: .audio
            )

        print(
            "BriefShow mux: music url =", url.lastPathComponent,
            "duration =", assetDuration,
            "isValid:", assetDuration.isValid,
            "audioTrackCount:", audioTracks.count
        )

        guard let track = audioTracks.first,
              assetDuration > .zero,
              track.timeRange.duration > .zero
        else {
            print(
                "BriefShow mux: SKIPPING music track "
                + "(no track or zero duration)"
            )
            continue
        }

        let usableTrackDuration =
            minCMTime(
                assetDuration,
                track.timeRange.duration
            )

        musicSources.append(
            (
                asset: asset,
                track: track,
                duration: usableTrackDuration,
                startTime: track.timeRange.start
            )
        )

        print(
            "BriefShow mux: retained AAC asset:",
            convertedURL.lastPathComponent,
            "track start:",
            track.timeRange.start,
            "track duration:",
            track.timeRange.duration,
            "usable duration:",
            usableTrackDuration
        )
    }

    print("BriefShow mux: usable musicSources count =", musicSources.count)

    if !musicSources.isEmpty,
       let compositionAudioTrack = composition.addMutableTrack(
           withMediaType: .audio,
           preferredTrackID: kCMPersistentTrackID_Invalid
       ) {
        var insertedAudioDuration = CMTime.zero
        var sourceIndex = 0

        while insertedAudioDuration < videoDuration {
            let source = musicSources[sourceIndex % musicSources.count]
            let remainingVideoDuration = videoDuration - insertedAudioDuration
            let audioSegmentDuration = minCMTime(remainingVideoDuration, source.duration)

            do {
                let sourceTimeRange =
                    CMTimeRange(
                        start:
                            source.startTime,
                        duration:
                            audioSegmentDuration
                    )

                try compositionAudioTrack
                    .insertTimeRange(
                        sourceTimeRange,
                        of:
                            source.track,
                        at:
                            insertedAudioDuration
                    )
            } catch {
                print(
                    "BriefShow mux FAILED at audio insertTimeRange:",
                    "insertedAudioDuration:",
                    insertedAudioDuration,
                    "sourceStart:",
                    source.startTime,
                    "sourceDuration:",
                    source.duration,
                    "audioSegmentDuration:",
                    audioSegmentDuration,
                    "trackTimeRange:",
                    source.track.timeRange,
                    "error:",
                    String(
                        describing:
                            error
                    )
                )
                throw error
            }

            insertedAudioDuration = insertedAudioDuration + audioSegmentDuration
            sourceIndex += 1
        }

        let audioDuration = minCMTime(videoDuration, insertedAudioDuration)

        let audioParameters = AVMutableAudioMixInputParameters(track: compositionAudioTrack)
        audioParameters.setVolume(1, at: .zero)

        let audioDurationSeconds = max(0, CMTimeGetSeconds(audioDuration))
        let requestedFadeInSeconds = max(0, fadeInSeconds)
        let requestedFadeOutSeconds = max(0, fadeOutSeconds)
        let requestedFadeTotal = requestedFadeInSeconds + requestedFadeOutSeconds
        let fadeScale = requestedFadeTotal > audioDurationSeconds && requestedFadeTotal > 0
            ? audioDurationSeconds / requestedFadeTotal
            : 1

        let fadeInDuration = CMTime(
            seconds: requestedFadeInSeconds * fadeScale,
            preferredTimescale: 600
        )

        if fadeInDuration > .zero {
            audioParameters.setVolumeRamp(
                fromStartVolume: 0,
                toEndVolume: 1,
                timeRange: CMTimeRange(start: .zero, duration: fadeInDuration)
            )
        }

        let fadeOutDuration = CMTime(
            seconds: requestedFadeOutSeconds * fadeScale,
            preferredTimescale: 600
        )

        if fadeOutDuration > .zero {
            let fadeOutStart = maxCMTime(fadeInDuration, CMTimeSubtract(audioDuration, fadeOutDuration))
            let safeFadeOutDuration = minCMTime(fadeOutDuration, CMTimeSubtract(audioDuration, fadeOutStart))

            if safeFadeOutDuration > .zero {
                audioParameters.setVolumeRamp(
                    fromStartVolume: 1,
                    toEndVolume: 0,
                    timeRange: CMTimeRange(start: fadeOutStart, duration: safeFadeOutDuration)
                )
            }
        }

        audioMix = AVMutableAudioMix()
        audioMix?.inputParameters = [audioParameters]
    }

    // Passthrough is only safe on AVMutableComposition when
    // AVFoundation itself reports it as compatible, and never
    // when we need to apply an audio mix (volume ramps require
    // re-encoding, which Passthrough cannot do).
    let compatiblePresets = AVAssetExportSession.exportPresets(compatibleWith: composition)
    let passthroughIsSafe = audioMix == nil
        && compatiblePresets.contains(AVAssetExportPresetPassthrough)

    let preferredPreset: String

    if preferHEVC,
       compatiblePresets.contains(
            AVAssetExportPresetHEVCHighestQuality
       ) {

        preferredPreset =
            AVAssetExportPresetHEVCHighestQuality
    } else if preferHEVC,
              passthroughIsSafe {

        preferredPreset =
            AVAssetExportPresetPassthrough
    } else {
        preferredPreset =
            AVAssetExportPresetHighestQuality
    }

    print(
        "BriefShow mux preset:",
        preferredPreset,
        "preferHEVC:",
        preferHEVC,
        "passthroughIsSafe:",
        passthroughIsSafe,
        "compatiblePresets:",
        compatiblePresets
    )

    guard let exportSession = AVAssetExportSession(
        asset: composition,
        presetName: preferredPreset
    ) else {
        throw BriefShowExportError.couldNotExportWithAudio
    }

    exportSession.outputURL = outputURL
    exportSession.outputFileType = outputFileType
    exportSession.audioMix = audioMix
    exportSession.videoComposition =
        forcedVideoComposition
    exportSession.shouldOptimizeForNetworkUse = true

    let semaphore = DispatchSemaphore(value: 0)
    exportSession.exportAsynchronously {
        semaphore.signal()
    }
    semaphore.wait()

    if exportSession.status != .completed {
        let underlyingError = exportSession.error
        print(
            "BriefShow mux FAILED - status:",
            exportSession.status.rawValue,
            "error:",
            underlyingError?.localizedDescription ?? "nil",
            "fullError:",
            String(describing: underlyingError)
        )
        throw underlyingError ?? BriefShowExportError.couldNotExportWithAudio
    }
}

private func minCMTime(_ first: CMTime, _ second: CMTime) -> CMTime {
    CMTimeCompare(first, second) <= 0 ? first : second
}

private func maxCMTime(_ first: CMTime, _ second: CMTime) -> CMTime {
    CMTimeCompare(first, second) >= 0 ? first : second
}

enum BriefShowExportError: LocalizedError {
    case cannotAddVideoInput
    case couldNotStartWriter
    case couldNotCreatePixelBuffer
    case couldNotAppendFrame
    case writerFailed
    case couldNotExportWithAudio

    var errorDescription: String? {
        switch self {
        case .cannotAddVideoInput:
            return "Could not add video input."
        case .couldNotStartWriter:
            return "Could not start video writer."
        case .couldNotCreatePixelBuffer:
            return "Could not create video frame."
        case .couldNotAppendFrame:
            return "Could not write video frame."
        case .writerFailed:
            return "Video writer failed."
        case .couldNotExportWithAudio:
            return "Could not add music to exported video."
        }
    }
}

private func makePreviewImage(from url: URL) -> NSImage? {
    guard let sourceImage = NSImage(contentsOf: url) else {
        return nil
    }

    let maxSide: CGFloat = 1400
    let originalSize = sourceImage.size
    let largestSide = max(originalSize.width, originalSize.height)

    guard largestSide > maxSide else {
        return sourceImage
    }

    let scale = maxSide / largestSide
    let previewSize = NSSize(
        width: originalSize.width * scale,
        height: originalSize.height * scale
    )

    let previewImage = NSImage(size: previewSize)
    previewImage.lockFocus()
    sourceImage.draw(
        in: NSRect(origin: .zero, size: previewSize),
        from: NSRect(origin: .zero, size: originalSize),
        operation: .copy,
        fraction: 1
    )
    previewImage.unlockFocus()

    return previewImage
}

func loadDroppedFileURLs(
    from providers: [NSItemProvider],
    completion: @escaping ([URL]) -> Void
) -> Bool {
    let fileURLType = UTType.fileURL.identifier
    let group = DispatchGroup()
    let lock = NSLock()
    var urls: [URL] = []

    for provider in providers where provider.hasItemConformingToTypeIdentifier(fileURLType) {
        group.enter()

        provider.loadItem(forTypeIdentifier: fileURLType, options: nil) { item, _ in
            defer {
                group.leave()
            }

            let url: URL?

            if let fileURL = item as? URL {
                url = fileURL
            } else if let data = item as? Data {
                url = URL(dataRepresentation: data, relativeTo: nil)
            } else if let string = item as? String {
                url = URL(string: string)
            } else {
                url = nil
            }

            if let url {
                lock.lock()
                urls.append(url)
                lock.unlock()
            }
        }
    }

    group.notify(queue: .main) {
        completion(urls)
    }

    return true
}

struct HeaderView: View {
    @ObservedObject private var accountManager = AccountManager.shared
    @ObservedObject private var remoteStatus = AppRemoteStatus.shared
    @Binding var isProfileModalPresented: Bool
    let onOpenShowScreen: () -> Void

    var body: some View {
        HStack {
            // No wordmark or theme circles here — "BriefShow" branding and
            // theme switching now live on the folder-tree/grid screen this
            // editor is reached from (via "Browse" below); the editor
            // itself just inherits whichever theme is already active.
            Spacer()

            VStack(alignment: .trailing, spacing: 6) {
                HStack(spacing: 12) {
                    Button {
                        onOpenShowScreen()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "square.grid.3x3.fill")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 13, height: 13)

                            Text("Browse")
                        }
                        .frame(height: 15)
                    }
                    .buttonStyle(HeaderLinkButtonStyle())

                    if remoteStatus.isLocked, let session = accountManager.session {
                        Button {
                            isProfileModalPresented = true
                        } label: {
                            ProfileBadge(session: session)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .zIndex(300)
    }
}

struct RocketsBriefHoverCard: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Need a website, web app, or mobile app?")
                .font(.custom("Figtree", size: 14).weight(.medium))
                .foregroundColor(AppColors.ink)

            Text("Visit RocketsBrief and turn your idea into a hosted preview from just $5.")
                .font(.custom("Figtree", size: 11).weight(.regular))
                .foregroundColor(AppColors.muted)
                .fixedSize(horizontal: false, vertical: true)

            Text("Click RocketsBrief to open the site.")
                .font(.custom("Figtree", size: 10.5).weight(.semibold))
                .foregroundColor(AppColors.hoverInk)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(width: 270, alignment: .leading)
        .background(AppColors.background)
        .overlay(
            RoundedRectangle(cornerRadius: 26)
                .stroke(AppColors.border, lineWidth: 3)
        )
        .clipShape(RoundedRectangle(cornerRadius: 26))
        .shadow(color: Color.black.opacity(0.13), radius: 18, x: 0, y: 10)
    }
}

struct SupportHoverCard: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Need help, or have a bug to report?")
                .font(.custom("Figtree", size: 14).weight(.medium))
                .foregroundColor(AppColors.ink)

            Text("Opens the RocketsBrief support chat. Sign in or create a free account first if you haven't already.")
                .font(.custom("Figtree", size: 11).weight(.regular))
                .foregroundColor(AppColors.muted)
                .fixedSize(horizontal: false, vertical: true)

            Text("Click Support to open the chat.")
                .font(.custom("Figtree", size: 10.5).weight(.semibold))
                .foregroundColor(AppColors.hoverInk)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(width: 270, alignment: .leading)
        .background(AppColors.background)
        .overlay(
            RoundedRectangle(cornerRadius: 26)
                .stroke(AppColors.border, lineWidth: 3)
        )
        .clipShape(RoundedRectangle(cornerRadius: 26))
        .shadow(color: Color.black.opacity(0.13), radius: 18, x: 0, y: 10)
    }
}

struct FundMissionHoverCard: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Enjoying BriefShow?")
                .font(.custom("Figtree", size: 14).weight(.medium))
                .foregroundColor(AppColors.ink)

            Text("BriefShow is free to use. Your support helps RocketsBrief build more AI-powered tools, creative apps, and digital products — including some that may stay free for the community.")
                .font(.custom("Figtree", size: 11).weight(.regular))
                .foregroundColor(AppColors.muted)
                .fixedSize(horizontal: false, vertical: true)

            Text("Click Fund Mission to support RocketsBrief.")
                .font(.custom("Figtree", size: 10.5).weight(.semibold))
                .foregroundColor(AppColors.hoverInk)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(width: 285, alignment: .leading)
        .background(AppColors.background)
        .overlay(
            RoundedRectangle(cornerRadius: 26)
                .stroke(AppColors.border, lineWidth: 3)
        )
        .clipShape(RoundedRectangle(cornerRadius: 26))
        .shadow(color: Color.black.opacity(0.13), radius: 18, x: 0, y: 10)
    }
}

struct DisclaimerHoverCard: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Disclaimer & Usage Notice")
                .font(.custom("Figtree", size: 14).weight(.medium))
                .foregroundColor(AppColors.ink)

            Text("Read the usage notice for BriefShow, ShowGrid, and RocketsBrief products, including user responsibility, voluntary support terms, limitations, and prohibited use.")
                .font(.custom("Figtree", size: 11).weight(.regular))
                .foregroundColor(AppColors.muted)
                .fixedSize(horizontal: false, vertical: true)

            Text("Click Disclaimer to read the full notice.")
                .font(.custom("Figtree", size: 10.5).weight(.semibold))
                .foregroundColor(AppColors.hoverInk)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(width: 315, alignment: .leading)
        .background(AppColors.background)
        .overlay(
            RoundedRectangle(cornerRadius: 26)
                .stroke(AppColors.border, lineWidth: 3)
        )
        .clipShape(RoundedRectangle(cornerRadius: 26))
        .shadow(color: Color.black.opacity(0.13), radius: 18, x: 0, y: 10)
    }
}

struct ShowGridShortcutsHoverCard: View {
    @ObservedObject private var themeManager = ThemeManager.shared

    private struct ShortcutRow: Identifiable {
        let id = UUID()
        let key: String
        let description: String
    }

    private let rows: [ShortcutRow] = [
        ShortcutRow(key: "X", description: "Label the selected photo(s)"),
        ShortcutRow(key: "1..5", description: "Set that many stars on the selected photo(s)"),
        ShortcutRow(key: "Space", description: "Preview the selected photo(s) — up to 5 at once"),
        ShortcutRow(key: "C", description: "Exit the preview"),
        ShortcutRow(key: "V", description: "Clear every label and star rating"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Keyboard shortcuts")
                .font(.custom("Figtree", size: 14).weight(.medium))
                .foregroundColor(AppColors.ink)

            VStack(alignment: .leading, spacing: 7) {
                ForEach(rows) { row in
                    HStack(spacing: 10) {
                        Text(row.key)
                            .font(.custom("Figtree", size: 11).weight(.bold))
                            .foregroundColor(AppColors.ink)
                            .frame(minWidth: 36)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(AppColors.panel)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(AppColors.border, lineWidth: 1)
                            )

                        Text(row.description)
                            .font(.custom("Figtree", size: 11).weight(.regular))
                            .foregroundColor(AppColors.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Text("Select one or more photos first, then press a key.")
                .font(.custom("Figtree", size: 10.5).weight(.semibold))
                .foregroundColor(AppColors.hoverInk)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(width: 300, alignment: .leading)
        .background(AppColors.background)
        .overlay(
            RoundedRectangle(cornerRadius: 26)
                .stroke(AppColors.border, lineWidth: 3)
        )
        .clipShape(RoundedRectangle(cornerRadius: 26))
        .shadow(color: Color.black.opacity(0.13), radius: 18, x: 0, y: 10)
    }
}

struct DisclaimerNoticeModal: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @Environment(\.dismiss) private var dismiss

    private let noticeSections: [(String, String)] = [
        (
            "Free creative tool",
            "BriefShow and ShowGrid are provided as free creative tools by RocketsBrief. They are offered “as is” and “as available,” without guarantees that they will always be error-free, uninterrupted, or suitable for every specific purpose."
        ),
        (
            "User responsibility",
            "You are responsible for the images, music, files, prompts, content, exports, and any other materials you upload, create, process, publish, share, or use through BriefShow, ShowGrid, or any RocketsBrief product."
        ),
        (
            "Prohibited use",
            "You may not use BriefShow, ShowGrid, RocketsBrief, or any related tool to create, promote, distribute, or support unlawful, harmful, fraudulent, abusive, infringing, or prohibited activity. This includes scams, phishing, malware, spam, impersonation, copyright infringement, illegal products or services, or any activity that violates applicable laws, third-party rights, platform rules, or payment processor policies."
        ),
        (
            "Review before use",
            "Any output or exported photos created with BriefShow or ShowGrid should be reviewed by you before publishing, selling, sharing, or relying on it. RocketsBrief does not guarantee legal compliance, business results, earnings, conversions, or that any output will meet a specific requirement."
        ),
        (
            "Fund Mission support",
            "Fund Mission contributions are voluntary support payments. They help support the development of RocketsBrief apps, AI-powered tools, digital products, and community resources, including some products that may be available for free. A Fund Mission contribution does not purchase a specific service, subscription, custom work, investment, ownership rights, or guaranteed deliverable."
        ),
        (
            "Right to limit access",
            "RocketsBrief may refuse, limit, suspend, or remove access to any product or service if it believes a user is violating these terms, applicable law, third-party rights, payment processor rules, or creating risk for RocketsBrief, other users, or the public."
        ),
        (
            "Future changes to BriefShow and ShowGrid",
            "RocketsBrief may change, add, remove, lock, or discontinue any feature, theme, or part of BriefShow or ShowGrid at any time, without notice. This includes requiring a free account sign-up to continue using either one, and introducing paid features, subscriptions, or pricing for BriefShow or ShowGrid in the future. By continuing to use either one, you agree that these changes may happen at any time."
        ),
        (
            "Copyright and ownership",
            "BriefShow and ShowGrid are created by and are the property of the RocketsBrief Team. You are welcome to share or recommend them to others free of charge. You may not sell, resell, rebrand, redistribute for payment, or claim ownership of BriefShow or ShowGrid, in whole or in part."
        ),
        (
            "Account data and email use",
            "If BriefShow or ShowGrid ever requires a free account to continue use, your email address is stored securely using Supabase, a third-party database provider. RocketsBrief does not have access to your email inbox or password, and never asks for them. By creating an account, you agree that RocketsBrief may use your email address to send you marketing material, product updates, and promotional messages about RocketsBrief and its products."
        ),
        (
            "Usage analytics",
            "BriefShow and ShowGrid share only basic metrics with RocketsBrief: how many videos have been exported from BriefShow, and how many separate machines run BriefShow or ShowGrid. To protect your privacy, the app generates a strictly randomized installation ID that has no connection to your hardware, device serial numbers, or network configuration. This does not include your files, photos, music, exported videos, or any personal information — and it is completely separate from, and in addition to, the email address you provide only if you create an account."
        )
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Disclaimer & Usage Notice")
                        .font(.custom("Figtree", size: 24).weight(.semibold))
                        .foregroundColor(AppColors.ink)

                    Text("For BriefShow, ShowGrid, and RocketsBrief products")
                        .font(.custom("Figtree", size: 12.5).weight(.regular))
                        .foregroundColor(AppColors.muted)
                }

                Spacer()

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(HeaderLinkButtonStyle())
            }
            .padding(.horizontal, 24)
            .padding(.top, 22)
            .padding(.bottom, 14)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(noticeSections, id: \.0) { section in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(section.0)
                                .font(.custom("Figtree", size: 14).weight(.semibold))
                                .foregroundColor(AppColors.ink)

                            Text(section.1)
                                .font(.custom("Figtree", size: 12).weight(.regular))
                                .foregroundColor(AppColors.muted)
                                .lineSpacing(3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    Text("By using BriefShow or ShowGrid, you agree to this entire Disclaimer & Usage Notice, including that you are responsible for your own use of the tool and any content or output you create with it.")
                        .font(.custom("Figtree", size: 12).weight(.semibold))
                        .foregroundColor(AppColors.hoverInk)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
        .frame(width: 640, height: 620)
        .background(AppColors.background)
    }
}

struct LeftImportPanel: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @Binding var timingMode: SlideshowTimingMode
    @Binding var secondsPerPhoto: Double
    @Binding var fadeDuration: Double
    @Binding var magazineImageFadeSeconds: Double
    @Binding var magazineImageDelaySeconds: Double
    @Binding var origamiImagesBeforePageChange: Int
    @Binding var origamiInternalHoldSeconds: Double
    @Binding var musicFadeInSeconds: Double
    @Binding var musicFadeOutSeconds: Double
    @Binding var shouldLoopPreview: Bool
    @Binding var transitionStyle: SlideshowTransitionStyle
    @Binding var visualTheme: SlideshowVisualTheme
    let hasPhotos: Bool
    let onOpenCropEditor: () -> Void

    @State private var isThemePickerPresented = false
    @State private var isThemeButtonHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PanelTitle(title: "Settings", subtitle: "Timing and transitions")

            VStack(alignment: .leading, spacing: 8) {
                Text("Slideshow Settings")
                    .font(.custom("Figtree", size: 13).weight(.medium))
                    .foregroundColor(AppColors.ink)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Theme")
                        .font(.custom("Figtree", size: 11.5).weight(.medium))
                        .foregroundColor(AppColors.muted)

                    Button {
                        isThemePickerPresented.toggle()
                    } label: {
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(visualTheme.rawValue)
                                    .font(.custom("Figtree", size: 12.5).weight(.medium))
                                    .fontWeight(isThemeButtonHovered ? .semibold : nil)
                                    .foregroundColor(isThemeButtonHovered ? AppColors.hoverInk : AppColors.ink)
                                    .scaleEffect(isThemeButtonHovered ? 1.025 : 1, anchor: .leading)

                                Text("Choose Theme")
                                    .font(.custom("Figtree", size: 10.5).weight(.regular))
                                    .fontWeight(isThemeButtonHovered ? .semibold : nil)
                                    .foregroundColor(isThemeButtonHovered ? AppColors.hoverInk.opacity(0.82) : AppColors.muted.opacity(0.72))
                                    .scaleEffect(isThemeButtonHovered ? 1.02 : 1, anchor: .leading)
                            }

                            Spacer()

                            Image(systemName: "sparkles")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(AppColors.hoverInk)
                                .scaleEffect(isThemeButtonHovered ? 1.08 : 1)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(RoundedRectangle(cornerRadius: 18))
                    }
                    .buttonStyle(PlainButtonStyle())
                    .background(AppColors.panel)
                    .overlay(
                        RoundedRectangle(cornerRadius: 18)
                            .stroke(isThemeButtonHovered ? AppColors.hoverInk : AppColors.border, lineWidth: 2)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .onHover { hovering in
                        withAnimation(.linear(duration: 0.10)) {
                            isThemeButtonHovered = hovering
                        }
                    }
                    .sheet(isPresented: $isThemePickerPresented) {
                        ThemePickerPopover(
                            selectedTheme: $visualTheme,
                            transitionStyle: $transitionStyle,
                            timingMode: $timingMode,
                            secondsPerPhoto: $secondsPerPhoto,
                            magazineImageFadeSeconds: $magazineImageFadeSeconds,
                            magazineImageDelaySeconds: $magazineImageDelaySeconds,
                            musicFadeInSeconds: $musicFadeInSeconds,
                            musicFadeOutSeconds: $musicFadeOutSeconds,
                            shouldLoopPreview: $shouldLoopPreview,
                            isPresented: $isThemePickerPresented
                        )
                    }

                    Text(themeHelperText)
                        .font(.custom("Figtree", size: 10.5).weight(.regular))
                        .foregroundColor(AppColors.muted.opacity(0.72))
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 8) {
                    TimingModeButton(
                        title: "Follow Music",
                        isSelected: timingMode == .followMusic
                    ) {
                        timingMode = .followMusic
                    }

                    TimingModeButton(
                        title: "Custom Speed",
                        isSelected: timingMode == .customSpeed
                    ) {
                        timingMode = .customSpeed
                    }
                }

                if timingMode == .customSpeed
                    && !usesOrigamiSettings {

                    CompactStepperRow(
                        label:
                            usesMagazineSettings
                            || visualTheme == .imagination
                            ? "Seconds / Page"
                            : "Seconds / Photo",
                        value: Binding(
                            get: { secondsPerPhoto },
                            set: { newValue in
                                secondsPerPhoto =
                                    visualTheme == .imagination
                                    ? max(3, newValue)
                                    : newValue
                                enforceFadeLimit()
                            }
                        ),
                        range:
                            usesMagazineSettings
                            ? 0...20
                            : (
                                visualTheme == .imagination
                                ? 3...20
                                : 1...20
                            ),
                        step: 1,
                        suffix: "s"
                    )
                }

                if visualTheme == .singleFade {
                    CompactStepperRow(
                        label: "Single Fade",
                        value: Binding(
                            get: { fadeDuration },
                            set: { newValue in
                                fadeDuration = min(newValue, maxAllowedFadeDuration)
                                enforceFadeLimit()
                            }
                        ),
                        range: fadeStepperRange,
                        step: 0.5,
                        suffix: "s"
                    )
                }

                if usesOrigamiSettings {
                    VStack(
                        alignment: .leading,
                        spacing: 6
                    ) {
                        CompactStepperRow(
                            label: "Swap Delay",
                            value:
                                $origamiInternalHoldSeconds,
                            range: 1...15,
                            step: 0.5,
                            suffix: "s"
                        )

                        CompactStepperRow(
                            label: "Swap Count",
                            value: Binding(
                                get: {
                                    Double(
                                        origamiImagesBeforePageChange
                                    )
                                },
                                set: { newValue in
                                    origamiImagesBeforePageChange =
                                        max(
                                            0,
                                            min(
                                                6,
                                                Int(
                                                    newValue.rounded()
                                                )
                                            )
                                        )
                                }
                            ),
                            range: 0...6,
                            step: 1,
                            suffix: ""
                        )

                        cropPhotosButton
                    }
                    .padding(.top, 2)
                }

                if usesMagazineSettings {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            TimingModeButton(
                                title: "Fade",
                                isSelected: transitionStyle == .fade
                            ) {
                                transitionStyle = .fade
                            }

                            TimingModeButton(
                                title: "Blink",
                                isSelected: transitionStyle == .blink
                            ) {
                                transitionStyle = .blink
                            }
                        }

                        if transitionStyle == .fade {
                            CompactStepperRow(
                                label: "Image Fade In",
                                value: $magazineImageFadeSeconds,
                                range: 0.2...2.0,
                                step: 0.1,
                                suffix: "s"
                            )
                        }

                        CompactStepperRow(
                            label: "Start Delay",
                            value: $magazineImageDelaySeconds,
                            range: 0...2.0,
                            step: 0.1,
                            suffix: "s"
                        )

                        cropPhotosButton
                    }
                    .padding(.top, 2)
                }

                CompactStepperRow(
                    label: "Music Fade In",
                    value: $musicFadeInSeconds,
                    range: 0...10,
                    step: 1,
                    suffix: "s"
                )

                CompactStepperRow(
                    label: "Music Fade Out",
                    value: $musicFadeOutSeconds,
                    range: 0...10,
                    step: 1,
                    suffix: "s"
                )

                Toggle("Loop Preview", isOn: $shouldLoopPreview)
                    .toggleStyle(.checkbox)
                    .font(.custom("Figtree", size: 12).weight(.medium))
                    .foregroundColor(AppColors.ink)
                    .padding(.top, 2)

                Text(timingModeHelperText)
                    .font(.custom("Figtree", size: 11).weight(.regular))
                    .foregroundColor(AppColors.muted.opacity(0.78))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(AppColors.panel)
                    .overlay(
                        RoundedRectangle(cornerRadius: 18)
                            .stroke(AppColors.border.opacity(0.85), lineWidth: 2)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .padding(.top, 2)
            }
            .padding(14)
            .background(AppColors.background)
            .overlay(
                RoundedRectangle(cornerRadius: 24)
                    .stroke(AppColors.border, lineWidth: 4)
            )
            .clipShape(RoundedRectangle(cornerRadius: 24))
        }
        .padding(14)
        .frame(width: 290)
        .background(AppColors.background)
        .overlay(
            RoundedRectangle(cornerRadius: 34)
                .stroke(AppColors.border, lineWidth: 4)
        )
        .clipShape(RoundedRectangle(cornerRadius: 34))
        
    }

    private var usesMagazineSettings: Bool {
        visualTheme == .magazine || visualTheme == .magazine43 || visualTheme == .magazineFamily || visualTheme == .magazineCouples
    }

    private var usesOrigamiSettings: Bool {
        visualTheme == .origami || visualTheme == .origami43
    }

    private var cropPhotosButton: some View {
        Button(action: onOpenCropEditor) {
            HStack(spacing: 6) {
                Image(systemName: "crop")
                    .font(.system(size: 11, weight: .semibold))

                Text("Crop Photos")
                    .font(.custom("Figtree", size: 12).weight(.medium))
            }
            .foregroundColor(hasPhotos ? AppColors.ink : AppColors.muted.opacity(0.5))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(AppColors.panel)
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(AppColors.border.opacity(hasPhotos ? 1 : 0.5), lineWidth: 1.6)
            )
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .disabled(!hasPhotos)
        .padding(.top, 2)
    }

    private var maxAllowedFadeDuration: Double {
        guard timingMode == .customSpeed else {
            return 3
        }

        return max(0, min(3, secondsPerPhoto - 1))
    }

    private var fadeStepperRange: ClosedRange<Double> {
        maxAllowedFadeDuration == 0 ? 0...0 : 0.5...maxAllowedFadeDuration
    }

    private var isFadeControlDisabled: Bool {
        visualTheme != .singleFade
    }

    private func enforceFadeLimit() {
        guard !usesMagazineSettings else {
            return
        }

        let maxFade = maxAllowedFadeDuration

        if maxFade == 0 {
            fadeDuration = 0
            transitionStyle = .blink
            return
        }

        if fadeDuration == 0 {
            fadeDuration = min(0.5, maxFade)
        }

        if fadeDuration > maxFade {
            fadeDuration = maxFade
        }
    }

    private var themeHelperText: String {
        switch visualTheme {
        case .singleFade:
            return "Single Fade keeps one photo per slide with a soft transition."
        case .singleBlink:
            return "Single Blink keeps one photo per slide with fast clean cuts."
        case .magazine:
            return "Kousei will create editorial pages with one, three, or more photos per page."
        case .magazine43:
            return "Kousei 4:3 uses the same editorial pages, with every photo cropped to a clean 4:3 or 3:4 grid cell."
        case .magazineFamily:
            return "Magazine Family will use warmer layouts for group and family photos."
        case .magazineCouples:
            return "Magazine Couples will use romantic layouts for portraits, weddings, and trips."
        case .origami:
            return "Kirigami will use geometric panel-style pages inspired by folded paper movement."
        case .origami43:
            return "Kirigami 4:3 uses the same folded panel movement, with every photo cropped to a clean 4:3 or 3:4 grid cell."
        case .imagination:
            return "Kanata brings photos to life as 3D cards emerging from deep space."
        }
    }

    private var timingModeHelperText: String {
        if usesOrigamiSettings {
            return "Image Change Delay controls the pause before the image fold. Images Before Page controls how many images change together before the complete page folds."
        }

        if usesMagazineSettings {
            if transitionStyle == .blink {
                return "Blink is active, so each photo pops in instantly. Start Delay controls when the next image appears, and Seconds / Page controls how long the full page waits before the next empty page starts."
            }

            return "For Kousei, Image Fade In controls alpha 0→1, Start Delay controls when the next image begins, and Seconds / Page controls how long the full page waits before the next empty page starts."
        }

        switch timingMode {
        case .followMusic:
            return "Automatically spaces photos to match the music length, with music fade-in at the start and fade-out at the end."
        case .customSpeed:
            if maxAllowedFadeDuration == 0 {
                return "At 1 second per photo, fade is disabled and Blink is used for a cleaner fast slideshow."
            }

            if transitionStyle == .blink {
                return "Blink is active, so image fade is disabled. Switch back to Fade if you want soft transitions."
            }

            return "Fade is limited to stay shorter than each photo duration, so the slideshow stays clean and professional."
        }
    }
}

struct MagazineCropEditorSheet: View {
    let photoURLs: [URL]
    let previewImages: [NSImage]
    let visualTheme: SlideshowVisualTheme
    let pageRanges: [Range<Int>]
    let origamiPagePlans: [OrigamiPagePlan]
    @Binding var cropTransforms: [URL: MagazinePhotoCrop]
    @Binding var manualMagazineLayoutOverrides: [Int: Int]
    @Binding var manualOrigamiLayoutOverrides: [Int: Int]
    let onClose: () -> Void

    // For a photo that's a Kirigami swap-in replacement, the aspect ratio of
    // the base-slot photo whose slot it actually lands in — so the
    // single-photo fine-tune editor's frame matches the slot it's really
    // squeezed into, not an ideal slot for its own shape.
    private var origamiAnchorAspectRatioByIndex: [Int: CGFloat] {
        guard !origamiPagePlans.isEmpty else {
            return [:]
        }

        var result: [Int: CGFloat] = [:]

        for plan in origamiPagePlans {
            let baseImages = Array(previewImages[plan.baseRange])

            for (photoIndex, slot) in plan.slotByReplacementIndex
            where baseImages.indices.contains(slot) {
                let size = baseImages[slot].size

                guard size.width > 0, size.height > 0 else {
                    continue
                }

                result[photoIndex] = size.width / size.height
            }
        }

        return result
    }

    // Above this, the default crop loses enough of the photo to flag it.
    private let cropWarningThreshold: Double = 0.32

    @State private var selectedIndex: Int = 0
    @State private var currentPageIndex: Int = 0
    @State private var isViewingSinglePhoto: Bool = false

    private var photoCount: Int {
        min(photoURLs.count, previewImages.count)
    }

    private var selectedCrop: Binding<MagazinePhotoCrop> {
        crop(for: selectedIndex)
    }

    private func crop(for index: Int) -> Binding<MagazinePhotoCrop> {
        guard photoURLs.indices.contains(index) else {
            return .constant(.default)
        }

        let url = photoURLs[index]

        return Binding(
            get: { cropTransforms[url] ?? .default },
            set: { cropTransforms[url] = $0 }
        )
    }

    // Only a visual guide in the editor — the real slot rect varies slightly
    // by page layout, but a focus-point crop is forgiving of that variance.
    private func editorAspectRatio(for index: Int) -> CGFloat {
        guard previewImages.indices.contains(index) else {
            return 1
        }

        if visualTheme == .magazine43 || visualTheme == .origami43 {
            let size = previewImages[index].size

            guard size.width > 0, size.height > 0 else {
                return 4.0 / 3.0
            }

            return size.width >= size.height ? 4.0 / 3.0 : 3.0 / 4.0
        }

        if visualTheme == .origami,
           let anchorRatio = origamiAnchorAspectRatioByIndex[index] {
            return representativeAspectRatio(for: photoAspectClass(for: anchorRatio))
        }

        let size = previewImages[index].size

        guard size.width > 0, size.height > 0 else {
            return 1
        }

        let ratio = size.width / size.height

        if visualTheme == .origami {
            return representativeAspectRatio(for: photoAspectClass(for: ratio))
        }

        if ratio < 0.82 {
            return 0.8
        }

        if ratio > 1.18 {
            return 1.5
        }

        return 1
    }

    // How much of the photo would be lost with no manual crop at all —
    // used to flag photos worth checking before the client pages through
    // everything.
    private func defaultCropSeverity(for index: Int) -> Double {
        guard previewImages.indices.contains(index) else {
            return 0
        }

        let size = previewImages[index].size

        guard size.width > 0, size.height > 0 else {
            return 0
        }

        let ratio = size.width / size.height
        let target = editorAspectRatio(for: index)
        let visibleFraction = magazineCropVisibleAreaFraction(
            imageAspectRatio: ratio,
            targetAspectRatio: target
        )

        return 1 - visibleFraction
    }

    private func needsCropAttention(at index: Int) -> Bool {
        guard photoURLs.indices.contains(index) else {
            return false
        }

        guard cropTransforms[photoURLs[index]] == nil else {
            // Already looked at and adjusted (or intentionally left as is).
            return false
        }

        return defaultCropSeverity(for: index) > cropWarningThreshold
    }

    private var cropByImageIdentity: [ObjectIdentifier: MagazinePhotoCrop] {
        guard !cropTransforms.isEmpty else {
            return [:]
        }

        var result: [ObjectIdentifier: MagazinePhotoCrop] = [:]

        for (index, url) in photoURLs.enumerated()
        where previewImages.indices.contains(index) {
            if let crop = cropTransforms[url] {
                result[ObjectIdentifier(previewImages[index])] = crop
            }
        }

        return result
    }

    private var currentPageRange: Range<Int>? {
        guard pageRanges.indices.contains(currentPageIndex) else {
            return nil
        }

        return pageRanges[currentPageIndex]
    }

    private var currentPageLayoutVariantCount: Int {
        if visualTheme == .magazine43 {
            guard let range = currentPageRange else { return 1 }

            return strict43LayoutVariantCount(photoCount: min(range.count, 4))
        }

        // Kirigami 4:3's strict grid isn't wired up to manual overrides —
        // stays deterministic from photo count/orientation for now.
        guard visualTheme != .origami43 else {
            return 1
        }

        guard let range = currentPageRange else { return 1 }

        let plan = origamiPagePlans.indices.contains(currentPageIndex)
            ? origamiPagePlans[currentPageIndex]
            : nil

        let rawCount = visualTheme == .origami
            ? (plan?.baseRange.count ?? range.count)
            : range.count

        let count = min(rawCount, 6)

        if count <= 1 { return 1 }

        return visualTheme == .origami
            ? origamiLayoutVariantCount(photoCount: count)
            : magazineLayoutVariantCount(photoCount: count)
    }

    private func openPhoto(at index: Int) {
        selectedIndex = index
        isViewingSinglePhoto = true
    }

    private func returnToPages() {
        if let pageIndex = pageRanges.firstIndex(where: { $0.contains(selectedIndex) }) {
            currentPageIndex = pageIndex
        }

        isViewingSinglePhoto = false
    }

    private var showsPageBrowser: Bool {
        !isViewingSinglePhoto && !pageRanges.isEmpty
    }

    private var pageBrowserHint: String {
        guard showsPageBrowser else {
            return "Drag to reposition, pinch or use the slider to zoom in on exactly what should stay in frame."
        }

        return "Drag any photo above to reposition it, or tap its thumbnail below to zoom in and fine-tune."
    }

    // Maps an NSImage rendered in the page preview back to its source URL,
    // so a drag right on the page preview can commit into cropTransforms
    // (keyed by URL) without the client ever leaving the page view.
    private func url(for image: NSImage) -> URL? {
        guard let index = previewImages.firstIndex(where: { $0 === image }),
              photoURLs.indices.contains(index)
        else {
            return nil
        }

        return photoURLs[index]
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .onTapGesture { onClose() }

            VStack(alignment: .leading, spacing: 16) {
                header

                if photoCount == 0 {
                    Text("Add photos first to set a manual crop.")
                        .font(.custom("Figtree", size: 13).weight(.regular))
                        .foregroundColor(AppColors.muted)
                        .frame(width: 560, height: 420)
                } else if showsPageBrowser {
                    pageBrowser
                } else if previewImages.indices.contains(selectedIndex) {
                    singlePhotoEditor
                }
            }
            .padding(24)
            .frame(width: 608)
            .background(AppColors.background)
            .clipShape(RoundedRectangle(cornerRadius: 28))
            .overlay(
                RoundedRectangle(cornerRadius: 28)
                    .stroke(AppColors.border, lineWidth: 4)
            )
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Crop Photos")
                    .font(.custom("Figtree", size: 20).weight(.semibold))
                    .foregroundColor(AppColors.ink)

                Text(pageBrowserHint)
                .font(.custom("Figtree", size: 11.5).weight(.regular))
                .foregroundColor(AppColors.muted)
                .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            Button {
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10.5, weight: .bold))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(HeaderLinkButtonStyle())
        }
    }

    @ViewBuilder
    private var pageBrowser: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button {
                    currentPageIndex = max(0, currentPageIndex - 1)
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(HeaderLinkButtonStyle())
                .disabled(currentPageIndex <= 0)
                .keyboardShortcut(.leftArrow, modifiers: [])

                Spacer()

                Text("Page \(currentPageIndex + 1) of \(pageRanges.count)")
                    .font(.custom("Figtree", size: 12.5).weight(.medium))
                    .foregroundColor(AppColors.ink)

                Spacer()

                Button {
                    currentPageIndex = min(pageRanges.count - 1, currentPageIndex + 1)
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(HeaderLinkButtonStyle())
                .disabled(currentPageIndex >= pageRanges.count - 1)
                .keyboardShortcut(.rightArrow, modifiers: [])
            }
            .frame(width: 560)

            if currentPageLayoutVariantCount > 1 {
                HStack {
                    Spacer()

                    Button {
                        if visualTheme == .origami {
                            let current = manualOrigamiLayoutOverrides[currentPageIndex] ?? 0
                            manualOrigamiLayoutOverrides[currentPageIndex] = (current + 1) % currentPageLayoutVariantCount
                        } else {
                            let current = manualMagazineLayoutOverrides[currentPageIndex] ?? 0
                            manualMagazineLayoutOverrides[currentPageIndex] = (current + 1) % currentPageLayoutVariantCount
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "square.grid.2x2.fill")
                                .font(.system(size: 10, weight: .semibold))
                            Text("Change Page Layout")
                                .font(.custom("Figtree", size: 11.5).weight(.medium))
                        }
                    }
                    .buttonStyle(HeaderLinkButtonStyle())
                }
                .frame(width: 560)
            }

            if let range = currentPageRange {
                Group {
                    if visualTheme == .origami || visualTheme == .origami43 {
                        let plan = origamiPagePlans.indices.contains(currentPageIndex)
                            ? origamiPagePlans[currentPageIndex]
                            : nil

                        let baseImages = plan.map { Array(previewImages[$0.baseRange]) }
                            ?? Array(previewImages[range])

                        let slotReplacementImages: [Int: NSImage] =
                            (plan?.slotByReplacementIndex ?? [:]).reduce(into: [:]) { result, pair in
                                let (photoIndex, slot) = pair

                                guard previewImages.indices.contains(photoIndex) else {
                                    return
                                }

                                result[slot] = previewImages[photoIndex]
                            }

                        OrigamiPreviewPage(
                            images: baseImages,
                            theme: visualTheme,
                            slotReplacementImages: slotReplacementImages,
                            activeSwapImages: [:],
                            activeSwapStyles: [:],
                            swapProgress: 1,
                            activePhotoName: "",
                            showsPhotoName: false,
                            transitionProgress: 1,
                            animationVariant: currentPageIndex,
                            cropByImageIdentity: cropByImageIdentity,
                            manualLayoutVariant: manualOrigamiLayoutOverrides[currentPageIndex],
                            onCropChange: { image, newCrop in
                                guard let url = url(for: image) else {
                                    return
                                }

                                cropTransforms[url] = newCrop
                            }
                        )
                    } else {
                        MagazinePreviewPage(
                            images: Array(previewImages[range]),
                            theme: visualTheme,
                            activePhotoName: "",
                            activePhotoIndex: 0,
                            transitionProgress: 1,
                            imageFadeSeconds: 0.3,
                            imageDelaySeconds: 0.3,
                            revealStyle: .fade,
                            layoutSeed: currentPageIndex,
                            cropByImageIdentity: cropByImageIdentity,
                            manualLayoutVariant: manualMagazineLayoutOverrides[currentPageIndex],
                            onCropChange: { image, newCrop in
                                guard let url = url(for: image) else {
                                    return
                                }

                                cropTransforms[url] = newCrop
                            }
                        )
                    }
                }
                .frame(width: 560, height: 315)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(AppColors.border, lineWidth: 2)
                )

                thumbnailRow(for: Array(range))
            }
        }
    }

    @ViewBuilder
    private var singlePhotoEditor: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !pageRanges.isEmpty {
                Button {
                    returnToPages()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 10, weight: .semibold))

                        Text("Back to Pages")
                            .font(.custom("Figtree", size: 11.5).weight(.medium))
                    }
                }
                .buttonStyle(.plain)
                .foregroundColor(AppColors.hoverInk)
            }

            MagazineCropEditorTile(
                image: previewImages[selectedIndex],
                targetAspectRatio: editorAspectRatio(for: selectedIndex),
                crop: selectedCrop
            )
            .frame(width: 560, height: 420)
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .stroke(AppColors.border, lineWidth: 2)
            )

            if needsCropAttention(at: selectedIndex) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))

                    Text(
                        "About \(Int((defaultCropSeverity(for: selectedIndex) * 100).rounded()))% of this photo would be cropped away by default — worth a look."
                    )
                    .font(.custom("Figtree", size: 11.5).weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundColor(.orange)
            }

            controls
            thumbnailRow(for: Array(0..<photoCount))
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Image(systemName: "minus.magnifyingglass")
                .font(.system(size: 12))
                .foregroundColor(AppColors.muted)

            Slider(value: selectedCrop.zoom, in: 1...3)

            Image(systemName: "plus.magnifyingglass")
                .font(.system(size: 12))
                .foregroundColor(AppColors.muted)

            Button("Reset") {
                selectedCrop.wrappedValue = .default
            }
            .buttonStyle(.plain)
            .font(.custom("Figtree", size: 11.5).weight(.medium))
            .foregroundColor(AppColors.hoverInk)
        }
    }

    private func thumbnailRow(for indices: [Int]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(indices, id: \.self) { index in
                    Button {
                        openPhoto(at: index)
                    } label: {
                        Image(nsImage: previewImages[index])
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 52, height: 52)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(
                                        isViewingSinglePhoto && index == selectedIndex ? AppColors.hoverInk : Color.clear,
                                        lineWidth: 2.5
                                    )
                            )
                            .overlay(alignment: .topTrailing) {
                                if needsCropAttention(at: index) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundColor(.white)
                                        .padding(3)
                                        .background(Circle().fill(Color.orange))
                                        .padding(3)
                                } else if cropTransforms[photoURLs[index]] != nil {
                                    Circle()
                                        .fill(AppColors.hoverInk)
                                        .frame(width: 8, height: 8)
                                        .padding(3)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(height: 60)
    }
}

struct MagazineCropEditorTile: View {
    let image: NSImage
    let targetAspectRatio: CGFloat
    @Binding var crop: MagazinePhotoCrop

    @State private var dragTranslation: CGSize = .zero
    @GestureState private var magnifyBy: CGFloat = 1

    var body: some View {
        GeometryReader { proxy in
            let frameSize = editorFrameSize(in: proxy.size)
            let liveZoom = max(1, crop.zoom * Double(magnifyBy))

            let liveCrop = MagazinePhotoCrop(
                focusX: crop.focusX,
                focusY: crop.focusY,
                zoom: liveZoom
            )

            let baseOffset = magazineCropOffset(
                imageSize: image.size,
                frameSize: frameSize,
                crop: liveCrop
            )

            ZStack {
                Color.black

                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: frameSize.width, height: frameSize.height)
                    .scaleEffect(liveZoom)
                    .offset(
                        CGSize(
                            width: baseOffset.width + dragTranslation.width,
                            height: baseOffset.height + dragTranslation.height
                        )
                    )
                    .frame(width: frameSize.width, height: frameSize.height)
                    .clipped()
            }
            .frame(width: frameSize.width, height: frameSize.height)
            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .onChanged { value in
                        dragTranslation = value.translation
                    }
                    .onEnded { value in
                        commitDrag(
                            translation: value.translation,
                            imageSize: image.size,
                            frameSize: frameSize
                        )
                        dragTranslation = .zero
                    }
            )
            .simultaneousGesture(
                MagnificationGesture()
                    .updating($magnifyBy) { value, state, _ in
                        state = value
                    }
                    .onEnded { value in
                        crop.zoom = min(3, max(1, crop.zoom * value))
                    }
            )
        }
        .clipped()
    }

    private func editorFrameSize(in containerSize: CGSize) -> CGSize {
        guard containerSize.width > 0, containerSize.height > 0 else {
            return containerSize
        }

        let containerAspect = containerSize.width / containerSize.height

        if targetAspectRatio > containerAspect {
            return CGSize(
                width: containerSize.width,
                height: containerSize.width / targetAspectRatio
            )
        }

        return CGSize(
            width: containerSize.height * targetAspectRatio,
            height: containerSize.height
        )
    }

    private func commitDrag(translation: CGSize, imageSize: CGSize, frameSize: CGSize) {
        let renderedSize = magazineCropRenderSize(
            imageSize: imageSize,
            frameSize: frameSize,
            zoom: CGFloat(crop.zoom)
        )

        let overflowX = renderedSize.width - frameSize.width
        let overflowY = renderedSize.height - frameSize.height

        let currentOffset = magazineCropOffset(
            imageSize: imageSize,
            frameSize: frameSize,
            crop: crop
        )

        if overflowX > 1 {
            let newOffsetX = currentOffset.width + translation.width
            crop.focusX = min(1, max(0, 0.5 - newOffsetX / overflowX))
        }

        if overflowY > 1 {
            let newOffsetY = currentOffset.height + translation.height
            crop.focusY = min(1, max(0, 0.5 - newOffsetY / overflowY))
        }
    }
}

struct ThemePickerPopover: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @Binding var selectedTheme: SlideshowVisualTheme
    @Binding var transitionStyle: SlideshowTransitionStyle
    @Binding var timingMode: SlideshowTimingMode
    @Binding var secondsPerPhoto: Double
    @Binding var magazineImageFadeSeconds: Double
    @Binding var magazineImageDelaySeconds: Double
    @Binding var musicFadeInSeconds: Double
    @Binding var musicFadeOutSeconds: Double
    @Binding var shouldLoopPreview: Bool
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                Text("Choose Theme")
                    .font(.custom("Figtree", size: 22).weight(.semibold))
                    .foregroundColor(AppColors.ink)

                Spacer()

                Button {
                    isPresented = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10.5, weight: .bold))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(HeaderLinkButtonStyle())
            }

            Text("Pick the slideshow style. New themes are added regularly as BriefShow keeps improving.")
                .font(.custom("Figtree", size: 12).weight(.regular))
                .foregroundColor(AppColors.muted)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 10) {
                ThemePickerSectionTitle("Classic")

                ThemePickerOption(
                    title: "Single Fade",
                    subtitle: "One photo per slide with soft fade transitions.",
                    isSelected: selectedTheme == .singleFade,
                    isLocked: false
                ) {
                    selectedTheme = .singleFade
                    transitionStyle = .fade
                    isPresented = false
                }

                ThemePickerOption(
                    title: "Single Blink",
                    subtitle: "One photo per slide with fast clean cuts.",
                    isSelected: selectedTheme == .singleBlink,
                    isLocked: false
                ) {
                    selectedTheme = .singleBlink
                    transitionStyle = .blink
                    isPresented = false
                }

                ThemePickerSectionTitle("Other")

                ThemePickerOption(
                    title: "Kousei",
                    subtitle: "Editorial pages with one, three, or more photos.",
                    isSelected: selectedTheme == .magazine,
                    isLocked: false
                ) {
                    selectedTheme = .magazine
                    transitionStyle = .fade
                    timingMode = .customSpeed
                    secondsPerPhoto = 4
                    magazineImageFadeSeconds = 0.3
                    magazineImageDelaySeconds = 0.3
                    musicFadeInSeconds = 4
                    musicFadeOutSeconds = 4
                    shouldLoopPreview = false
                    isPresented = false
                }

                ThemePickerOption(
                    title: "Kousei 4:3",
                    subtitle: "Same editorial pages, every photo cropped to a clean 4:3 or 3:4 grid.",
                    isSelected: selectedTheme == .magazine43,
                    isLocked: false
                ) {
                    selectedTheme = .magazine43
                    transitionStyle = .fade
                    timingMode = .customSpeed
                    secondsPerPhoto = 4
                    magazineImageFadeSeconds = 0.3
                    magazineImageDelaySeconds = 0.3
                    musicFadeInSeconds = 4
                    musicFadeOutSeconds = 4
                    shouldLoopPreview = false
                    isPresented = false
                }

                ThemePickerOption(
                    title: "Kirigami",
                    subtitle: "Geometric folded-panel movement and page layouts.",
                    isSelected: selectedTheme == .origami,
                    isLocked: false
                ) {
                    selectedTheme = .origami
                    isPresented = false
                }

                ThemePickerOption(
                    title: "Kirigami 4:3",
                    subtitle: "Same folded-panel movement, every photo cropped to a clean 4:3 or 3:4 grid.",
                    isSelected: selectedTheme == .origami43,
                    isLocked: false
                ) {
                    selectedTheme = .origami43
                    isPresented = false
                }

                ThemePickerOption(
                    title: "Kanata",
                    subtitle: "Photos emerge as 3D cards from deep space.",
                    isSelected: selectedTheme == .imagination,
                    isLocked: false
                ) {
                    selectedTheme = .imagination
                    transitionStyle = .fade
                    secondsPerPhoto = max(3, secondsPerPhoto)
                    isPresented = false
                }

                ThemePickerSectionTitle("More Themes Coming")

                ThemePickerInfoCard(
                    icon: "hammer.fill",
                    text: "BriefShow is still in active development, so new themes can show up at any time. Keep the app updated to unlock them as soon as they're ready."
                )

                ThemePickerInfoCard(
                    icon: "bubble.left.and.bubble.right.fill",
                    text: "Need help or want to report a bug? Click Support above. Sign in or create a free account, then message us directly through the support chat."
                )
            }
        }
        .padding(22)
        .frame(width: 500, height: 680, alignment: .topLeading)
        .background(AppColors.background)
    }
}

struct ThemePickerInfoCard: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    let icon: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(AppColors.muted)
                .frame(width: 20)

            Text(text)
                .font(.custom("Figtree", size: 12).weight(.regular))
                .foregroundColor(AppColors.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColors.panel)
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(AppColors.border, lineWidth: 1.2)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

struct ThemePickerSectionTitle: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.custom("Figtree", size: 11.5).weight(.semibold))
            .foregroundColor(AppColors.hoverInk)
            .padding(.top, 2)
    }
}

struct ThemePickerOption: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    let title: String
    let subtitle: String
    let isSelected: Bool
    let isLocked: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button {
            if !isLocked {
                action()
            }
        } label: {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.custom("Figtree", size: 12.5).weight(.medium))
                            .fontWeight(isSelected || (isHovered && !isLocked) ? .semibold : nil)
                            .foregroundColor(titleColor)
                            .scaleEffect(isSelected || (isHovered && !isLocked) ? 1.025 : 1, anchor: .leading)

                        if isLocked {
                            Text("Locked")
                                .font(.custom("Figtree", size: 9.5).weight(.semibold))
                                .foregroundColor(AppColors.muted)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(AppColors.panelAlt)
                                .clipShape(RoundedRectangle(cornerRadius: 999))
                        }
                    }

                    Text(subtitle)
                        .font(.custom("Figtree", size: 10.5).weight(.regular))
                        .foregroundColor(AppColors.muted.opacity(isLocked ? 0.55 : 0.78))
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                Image(systemName: isSelected ? "checkmark.circle.fill" : (isLocked ? "lock.fill" : "circle"))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(iconColor)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 16))
            .background(backgroundColor)
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(borderColor, lineWidth: isSelected ? 1.9 : 1.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(isLocked)
        .onHover { hovering in
            withAnimation(.linear(duration: 0.10)) {
                isHovered = hovering
            }
        }
    }

    private var titleColor: Color {
        if isLocked {
            return AppColors.muted.opacity(0.55)
        }

        if isSelected || isHovered {
            return AppColors.hoverInk
        }

        return AppColors.ink
    }

    private var iconColor: Color {
        if isSelected || (isHovered && !isLocked) {
            return AppColors.hoverInk
        }

        return AppColors.muted.opacity(isLocked ? 0.45 : 0.50)
    }

    private var backgroundColor: Color {
        isSelected
            ? AppColors.panel
            : AppColors.background
    }

    private var borderColor: Color {
        if isSelected || (isHovered && !isLocked) {
            return AppColors.hoverInk
        }

        return AppColors.border.opacity(isLocked ? 0.45 : 0.85)
    }
}

struct FullScreenPreviewSheet: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    let activePreviewImage: NSImage?
    let previousPreviewImage: NSImage?
    let activePhotoName: String
    let activePhotoIndex: Int
    let photoCount: Int
    let isPreparingPhotos: Bool
    let previewImages: [NSImage]
    let origamiSlotReplacementImages: [Int: NSImage]
    let origamiActiveSwapImages: [Int: NSImage]
    let origamiActiveSwapStyles: [Int: Int]
    let origamiSwapProgress: Double
    let previousOrigamiPageImages: [NSImage]
    let previousOrigamiPageReplacements: [Int: NSImage]
    let previousOrigamiPageAnimationVariant: Int
    let origamiWholePageFoldProgress: Double
    let origamiBlackOverlayOpacity: Double
    let magazineBlackOverlayOpacity: Double
    let visualTheme: SlideshowVisualTheme
    let timeCounterText: String
    let transitionStyle: SlideshowTransitionStyle
    let transitionProgress: Double
    let magazineImageFadeSeconds: Double
    let magazineImageDelaySeconds: Double
    let magazineLayoutSeed: Int
    let photoCropByImageIdentity: [ObjectIdentifier: MagazinePhotoCrop]
    let magazinePageSlotCount: Int
    let origamiAnimationSeed: Int
    var manualMagazineLayoutOverrides: [Int: Int] = [:]
    var manualOrigamiLayoutOverrides: [Int: Int] = [:]
    let isPreviewPlaying: Bool
    let imaginationPlaybackRestartToken: Int
    let imaginationIntroOutroOpacity: Double
    let previewProgress: Double
    let onTogglePreview: () -> Void
    let onStartFromBeginning: () -> Void
    let onSeek: (Double) -> Void
    let onClose: () -> Void
    let previewRenderMode: PreviewRenderMode
    let previewVideoPlayer: AVPlayer?

    @State private var isScrubbing = false
    @State private var scrubProgress: Double = 0

    private var usesMagazinePreview: Bool {
        visualTheme == .magazine || visualTheme == .magazine43 || visualTheme == .magazineFamily || visualTheme == .magazineCouples
    }

    private var themedPreviewImages: [NSImage] {
        guard !previewImages.isEmpty else {
            return activePreviewImage.map { [$0] } ?? []
        }

        let safeIndex = previewImages.indices.contains(activePhotoIndex) ? activePhotoIndex : 0
        let slotCount = max(1, min(6, magazinePageSlotCount))
        return Array(previewImages[safeIndex...].prefix(slotCount))
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black
                    .ignoresSafeArea()

                fittedPreviewContent(in: proxy.size)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .background(Color.black)
                    .ignoresSafeArea()

                // Always mounted (never conditionally inserted/removed) so its
                // NSViewRepresentable identity stays stable across mode
                // switches — see the matching comment in CenterPreviewPanel.
                AVPlayerViewRepresentable(player: previewVideoPlayer)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .opacity(previewRenderMode.isRenderedVideo && previewVideoPlayer != nil ? 1 : 0)
                    .allowsHitTesting(previewRenderMode.isRenderedVideo && previewVideoPlayer != nil)
                    .ignoresSafeArea()

                fullscreenCloseButton
                    .position(x: proxy.size.width - 44, y: 44)
                    .zIndex(1000)

                // In video mode, AVKit's own play/pause/scrub overlay
                // (part of VideoPlayer above) replaces these custom controls.
                if !(previewRenderMode.isRenderedVideo && previewVideoPlayer != nil) {
                    fullscreenBottomControls
                        .frame(width: max(420, proxy.size.width - 56))
                        .position(x: proxy.size.width / 2, y: proxy.size.height - 74)
                        .zIndex(1000)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .background(Color.black)
        }
        .frame(
            width: NSScreen.main?.frame.width ?? 1400,
            height: NSScreen.main?.frame.height ?? 900
        )
        .background(Color.black)
        .ignoresSafeArea()
        .onExitCommand {
            onClose()
        }
    }

    @ViewBuilder
    private func fittedPreviewContent(in size: CGSize) -> some View {
        if previewRenderMode.isRenderedVideo && previewVideoPlayer != nil {
            EmptyView()
        } else if let activePreviewImage {
            if usesMagazinePreview {
                ZStack {
                    MagazinePreviewPage(
                        images: themedPreviewImages,
                        theme: visualTheme,
                        activePhotoName: activePhotoName,
                        activePhotoIndex: activePhotoIndex,
                        transitionProgress: transitionProgress,
                        imageFadeSeconds: magazineImageFadeSeconds,
                        imageDelaySeconds: magazineImageDelaySeconds,
                        revealStyle: transitionStyle,
                        layoutSeed: magazineLayoutSeed,
                        cropByImageIdentity: photoCropByImageIdentity,
                        manualLayoutVariant: manualMagazineLayoutOverrides[magazineLayoutSeed]
                    )

                    Color.black
                        .opacity(
                            magazineBlackOverlayOpacity
                        )
                        .allowsHitTesting(false)
                        .zIndex(500)
                }
                .frame(width: size.width, height: size.height)
                .background(Color.black)
                .drawingGroup()
            } else if visualTheme == .origami || visualTheme == .origami43 {
                ZStack {
                    OrigamiPreviewPage(
                        images: themedPreviewImages,
                        theme: visualTheme,
                        slotReplacementImages: origamiSlotReplacementImages,
                        activeSwapImages: origamiActiveSwapImages,
                        activeSwapStyles: origamiActiveSwapStyles,
                        swapProgress: origamiSwapProgress,
                        activePhotoName: activePhotoName,
                        showsPhotoName: false,
                        transitionProgress: transitionProgress,
                        animationVariant: origamiAnimationSeed,
                        cropByImageIdentity: photoCropByImageIdentity,
                        manualLayoutVariant: manualOrigamiLayoutOverrides[origamiAnimationSeed]
                    )

                    if !previousOrigamiPageImages.isEmpty {
                        OrigamiWholePageHalfFoldOverlay(
                            images: previousOrigamiPageImages,
                            theme: visualTheme,
                            slotReplacementImages:
                                previousOrigamiPageReplacements,
                            animationVariant:
                                previousOrigamiPageAnimationVariant,
                            progress:
                                origamiWholePageFoldProgress,
                            cropByImageIdentity: photoCropByImageIdentity,
                            manualLayoutVariant: manualOrigamiLayoutOverrides[previousOrigamiPageAnimationVariant]
                        )
                        .allowsHitTesting(false)
                        .zIndex(100)
                    }

                    Color.black
                        .opacity(
                            origamiBlackOverlayOpacity
                        )
                        .allowsHitTesting(false)
                        .zIndex(500)
                }
                .frame(
                    width: size.width,
                    height: size.height
                )
                .background(Color.black)
                .drawingGroup()
            } else if visualTheme == .imagination {
                ImaginationCardPage(
                    activeImage: activePreviewImage,
                    secondaryImage:
                        previewImages.indices.contains(
                            activePhotoIndex + 1
                        )
                        ? previewImages[
                            activePhotoIndex + 1
                        ]
                        : nil,
                    activePhotoIndex: activePhotoIndex,
                    transitionProgress: transitionProgress,
                    isPreviewPlaying: isPreviewPlaying,
                    playbackRestartToken:
                        imaginationPlaybackRestartToken,
                    introOutroOverlayOpacity:
                        imaginationIntroOutroOpacity
                )
                .id(activePhotoIndex)
                .frame(width: size.width, height: size.height)
                .allowsHitTesting(false)
            } else {
                ZStack {
                    Color.black

                    if transitionStyle == .fade, let previousPreviewImage {
                        FittedFullscreenImage(image: previousPreviewImage)
                            .opacity(max(0, 1 - transitionProgress))
                    }

                    FittedFullscreenImage(image: activePreviewImage)
                        .opacity(transitionStyle == .fade && previousPreviewImage != nil ? transitionProgress : 1)
                }
                .frame(width: size.width, height: size.height)
                .background(Color.black)
                .drawingGroup()
            }
        } else {
            ZStack {
                Color.black

                Text("Add photos to preview your slideshow.")
                    .font(.custom("Figtree", size: 18).weight(.medium))
                    .foregroundColor(.white.opacity(0.78))
            }
            .frame(width: size.width, height: size.height)
        }
    }

    private var fullscreenCloseButton: some View {
        Button {
            onClose()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(AppColors.ink)
                .frame(width: 34, height: 34)
                .background(AppColors.background.opacity(0.96))
                .overlay(
                    RoundedRectangle(cornerRadius: 999)
                        .stroke(AppColors.ink.opacity(0.75), lineWidth: 1.5)
                )
                .clipShape(RoundedRectangle(cornerRadius: 999))
                .shadow(color: Color.black.opacity(0.34), radius: 8, x: 0, y: 3)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.escape, modifiers: [])
    }

    private var fullscreenBottomControls: some View {
        GeometryReader { proxy in
            HStack(alignment: .center, spacing: 12) {
                HStack(spacing: 8) {
                    fullscreenIconButton(
                        systemName: isPreviewPlaying ? "pause.fill" : "play.fill",
                        label: isPreviewPlaying ? "Stop Preview" : "Play Preview",
                        isDisabled: photoCount == 0 || isPreparingPhotos,
                        action: onTogglePreview
                    )

                    fullscreenIconButton(
                        systemName: "arrow.counterclockwise",
                        label: "Play From Beginning",
                        isDisabled: photoCount == 0 || isPreparingPhotos,
                        action: onStartFromBeginning
                    )
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
                .background(Color.black.opacity(0.62))
                .clipShape(RoundedRectangle(cornerRadius: 999))
                .shadow(color: Color.black.opacity(0.30), radius: 10, x: 0, y: 4)

                Spacer(minLength: 12)

                fullscreenScrubber
                    .frame(width: max(120, proxy.size.width * 0.42), height: 16)

                Spacer(minLength: 12)

                Text(timeCounterText)
                    .font(.custom("Figtree", size: 12).weight(.medium))
                    .foregroundColor(.white.opacity(0.96))
                    .lineLimit(1)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(0.68))
                    .clipShape(RoundedRectangle(cornerRadius: 999))
                    .shadow(color: Color.black.opacity(0.30), radius: 10, x: 0, y: 4)
            }
            .frame(width: proxy.size.width)
        }
        .frame(height: 52)
    }

    private func fullscreenIconButton(
        systemName: String,
        label: String,
        isDisabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        FullscreenIconButton(systemName: systemName, label: label, isDisabled: isDisabled, action: action)
    }

    private var fullscreenScrubber: some View {
        let displayedProgress = isScrubbing ? scrubProgress : previewProgress

        return GeometryReader { proxy in
            let trackWidth = proxy.size.width
            let knobX = trackWidth * displayedProgress

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.24))
                    .frame(height: 4)

                Capsule()
                    .fill(Color.white.opacity(0.92))
                    .frame(width: max(0, knobX), height: 4)

                Circle()
                    .fill(Color.white)
                    .frame(width: 13, height: 13)
                    .shadow(color: Color.black.opacity(0.4), radius: 4, y: 1)
                    .offset(x: max(0, min(trackWidth, knobX)) - 6.5)
                    .scaleEffect(isScrubbing ? 1.25 : 1)
                    .animation(.easeOut(duration: 0.12), value: isScrubbing)
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard photoCount > 0, !isPreparingPhotos, trackWidth > 0 else { return }
                        isScrubbing = true
                        scrubProgress = min(1, max(0, value.location.x / trackWidth))
                    }
                    .onEnded { value in
                        guard photoCount > 0, !isPreparingPhotos, trackWidth > 0 else {
                            isScrubbing = false
                            return
                        }
                        let finalProgress = min(1, max(0, value.location.x / trackWidth))
                        onSeek(finalProgress)
                        isScrubbing = false
                    }
            )
        }
    }
}

private struct HoverTooltipArrow: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// Hover-only tooltip styled like a native macOS popover (frosted glass +
/// arrow), but a plain non-interactive overlay rather than an actual
/// `.popover`. A real popover eats the first click on the button underneath
/// it (used to dismiss itself), forcing a second click to trigger the
/// action - this reproduces the look without that side effect.
private struct HoverTooltipBubble: View {
    let label: String
    let textColor: Color
    var arrowEdge: Edge = .bottom

    var body: some View {
        VStack(spacing: 0) {
            if arrowEdge == .top {
                HoverTooltipArrow()
                    .fill(.regularMaterial)
                    .frame(width: 11, height: 6)
                    .rotationEffect(.degrees(180))
                    .offset(y: 1)
            }

            Text(label)
                .font(.custom("Figtree", size: 11).weight(.medium))
                .foregroundColor(textColor)
                .multilineTextAlignment(.leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                )

            if arrowEdge == .bottom {
                HoverTooltipArrow()
                    .fill(.regularMaterial)
                    .frame(width: 11, height: 6)
                    .offset(y: -1)
            }
        }
        // Unconditional fixedSize (both axes) so the bubble always hugs its
        // content tightly instead of stretching to whatever width its parent
        // happens to propose (e.g. the full window, via the root-level
        // GeometryReader) — long copy uses explicit "\n" breaks below rather
        // than automatic wrapping, so its width stays deterministic too.
        .fixedSize()
        .shadow(color: Color.black.opacity(0.22), radius: 8, y: 3)
        .allowsHitTesting(false)
    }
}

private struct FullscreenIconButton: View {
    let systemName: String
    let label: String
    let isDisabled: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.white.opacity(isDisabled ? 0.35 : 0.96))
                .frame(width: 34, height: 34)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .onHover { hovering in
            isHovered = hovering && !isDisabled
        }
        .overlay(alignment: .top) {
            if isHovered && !isDisabled {
                HoverTooltipBubble(label: label, textColor: .white)
                    .offset(y: -44)
                    .transition(.opacity)
            }
        }
    }
}

struct FittedFullscreenImage: View {
    let image: NSImage

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .scaledToFit()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
    }
}

private func resolvedMagazineLayoutVariant(
    photoCount: Int,
    portraitCount: Int,
    landscapeCount: Int,
    uniformTieBreakSeed: Int,
    manualOverride: Int?
) -> Int {
    let mixed = portraitCount > 0 && landscapeCount > 0
    let uniformTieBreak = ((uniformTieBreakSeed % 2) + 2) % 2

    let defaultVariant: Int
    let totalVariants: Int

    switch photoCount {
    case 2:
        totalVariants = 2
        defaultVariant = mixed ? 0 : 1

    case 3:
        totalVariants = 3
        defaultVariant = portraitCount >= 2 ? 0 : (mixed ? 1 : 2)

    case 4:
        totalVariants = 4
        defaultVariant = portraitCount >= 2 ? 0 : (mixed ? 1 : (uniformTieBreak == 0 ? 2 : 3))

    case 5:
        totalVariants = 3
        defaultVariant = portraitCount >= 2 ? 0 : (mixed ? 1 : 2)

    default:
        totalVariants = 5
        defaultVariant = portraitCount >= 3
            ? 0
            : (portraitCount == 2 ? 1 : (portraitCount == 1 ? 2 : (uniformTieBreak == 0 ? 3 : 4)))
    }

    guard let manualOverride else {
        return defaultVariant
    }

    let normalized = manualOverride % totalVariants
    return normalized >= 0 ? normalized : normalized + totalVariants
}

private func magazineLayoutVariantCount(photoCount: Int) -> Int {
    switch photoCount {
    case 2: return 2
    case 3: return 3
    case 4: return 4
    case 5: return 3
    default: return 5
    }
}

// Enlarging a strict-4:3 grid beyond its safe "shrink (or stay) to fit"
// scale was tried a few different ways (a flat factor, then a per-split
// cap on how much of an edge cell's width it could lose) — every version
// that actually reached a noticeably bigger size did so by clipping into
// whichever edge cell was narrowest, and for a mixed row (e.g. one portrait
// cell next to wider landscape cells) that reads as that photo being cut
// off, not just "zoomed in." Since every cell must both stay exactly
// 4:3/3:4 AND remain fully visible (no cell's content clipped by the
// canvas edge), a single row that already spans the full page width at
// scale 1 has no further room to grow — that natural size (whatever margin
// it leaves top/bottom) is already the largest that satisfies both
// requirements at once.

// Shared strict-4:3/3:4 grid geometry for the "Kousei 4:3"/"Kirigami 4:3"
// themes. Used by both the live SwiftUI preview (MagazinePreviewPage,
// OrigamiPreviewPage) and the Kousei CGContext export path so the exported
// video can't drift from what was previewed.
//
// Every cell is exactly 4:3 or 3:4 by construction (width = height * ratio),
// never cropped further — that's the one non-negotiable requirement. Each
// ROW gets its OWN height, sized so that row's cells exactly span the full
// page width on their own — that's what guarantees zero left/right margin
// on every single row, not just on the widest one (a shared row height,
// tried earlier, left any row with fewer/narrower cells short of the page
// edge). Rows are then stacked; if they don't stack to exactly the page
// height, the row split is re-picked to get as close as possible, and only
// as a last resort is the whole block scaled down uniformly (preserving
// every cell's ratio) to fit, which shows as one clean margin around the
// entire grid rather than a gap on one particular row.

private func strict43RowCompositions(photoCount: Int) -> [[Int]] {
    guard photoCount > 0 else { return [] }

    var candidates: [[Int]] = []
    let maxCellsPerRow = 6
    let maxRows = min(photoCount, 4)

    // A single row spanning every photo reads as "everything squeezed into
    // one thin strip" once there are more than a handful of photos — never
    // worth it once a real 2+ row grid is possible.
    let minRows = photoCount > 3 ? 2 : 1

    func extend(remaining: Int, rowsLeft: Int, current: [Int]) {
        if rowsLeft == 0 {
            if remaining == 0 {
                candidates.append(current)
            }
            return
        }

        let maxThisRow = min(maxCellsPerRow, remaining - (rowsLeft - 1))
        let minThisRow = max(1, remaining - (rowsLeft - 1) * maxCellsPerRow)

        guard minThisRow <= maxThisRow else { return }

        for count in minThisRow...maxThisRow {
            extend(remaining: remaining - count, rowsLeft: rowsLeft - 1, current: current + [count])
        }
    }

    for rows in minRows...maxRows {
        extend(remaining: photoCount, rowsLeft: rows, current: [])
    }

    return candidates
}

// The row-count arrangements a client can manually pick between via
// "Change Page Layout" (and the same list the automatic default is chosen
// from, in strict43BestRowCounts below) — a small, curated list rather than
// every mathematically valid strict43RowCompositions split. For 1-3 photos
// there's exactly one client-specified arrangement (see the matching rules
// in strict43BestRowCounts), so there's nothing to choose between — the
// button simply doesn't show for those pages. For 4, only these three:
// "1+3" (a mixed set of orientations), and "2+2" (used for either 4
// portraits or 4 landscapes stacked two-over-two) — every 3-row split
// (e.g. 1+1+2) was tried and read as too tall/stacked against a 16:9 page.
private func strict43ManualLayoutCandidates(photoCount: Int) -> [[Int]] {
    switch photoCount {
    case 1:
        return [[1]]
    case 2:
        return [[2]]
    case 3:
        return [[3]]
    case 4:
        return [[1, 3], [2, 2], [3, 1]]
    default:
        return strict43RowCompositions(photoCount: photoCount)
            .filter { counts in counts.contains { $0 > 1 } }
    }
}

// Natural (un-fit-to-page) height of each row when that row is built to
// exactly span `pageWidth` at its cells' exact 4:3/3:4 ratios.
private func strict43NaturalRowHeights(
    rowCounts: [Int],
    isLandscape: [Bool],
    pageWidth: CGFloat,
    gap: CGFloat
) -> [CGFloat] {
    var cursor = 0

    return rowCounts.map { rowCount in
        let ratios: [CGFloat] = (cursor..<(cursor + rowCount)).map { isLandscape[$0] ? 4.0 / 3.0 : 3.0 / 4.0 }
        cursor += rowCount

        let ratioSum = ratios.reduce(0, +)
        let usableWidth = max(1, pageWidth - gap * CGFloat(max(0, rowCount - 1)))

        return usableWidth / max(0.01, ratioSum)
    }
}

// Tries every reasonable row split (including uneven ones, e.g. 4-over-2)
// and keeps whichever, once every row is built to exactly span the full
// page width, stacks up closest to the page height WITHOUT exceeding it —
// that's the split that needs the smallest (or zero) top/bottom margin and
// never needs a shrink-to-fit pass. If every split overshoots the page
// height, the one that overshoots least is used instead (it'll get a
// gentle uniform shrink in strict43GridLayout).
private func strict43BestRowCounts(
    isLandscape: [Bool],
    pageWidth: CGFloat,
    pageHeight: CGFloat,
    gap: CGFloat
) -> [Int] {
    let count = isLandscape.count

    guard count > 0, pageWidth > 0, pageHeight > 0 else { return [] }

    // Two photos, any orientation mix, always read as one side-by-side row
    // — client-specified rule, not scored against alternatives.
    if count == 2 {
        return [2]
    }

    // Three horizontal photos read as three thin strips squeezed into one
    // row — always break them into one photo centered on top with the
    // other two side by side below it instead (handled one level up, in
    // strict43GridLayout, via strict43ThreeLandscapeRects — this redundant
    // copy is only a fallback for the rare case that call returns nil). Any
    // other 3-photo mix (all portrait, or portrait+landscape) always reads
    // as one row instead — client-specified rule, not scored against
    // row-stack alternatives like every photo in its own row.
    if count == 3 {
        return isLandscape[0] && isLandscape[1] && isLandscape[2] ? [1, 2] : [3]
    }

    // Four vertical photos in a 2-over-2 grid are each so narrow that the
    // grid needs a big shrink-to-fit against a 16:9 page, leaving thick
    // black bars on both sides — a single row of four fits the width
    // better and only ever costs a smaller top/bottom margin instead.
    if count == 4, !isLandscape[0], !isLandscape[1], !isLandscape[2], !isLandscape[3] {
        return [4]
    }

    var bestSplit = [count]
    var bestScore = CGFloat.greatestFiniteMagnitude

    for counts in strict43ManualLayoutCandidates(photoCount: count) {
        let rowHeights = strict43NaturalRowHeights(
            rowCounts: counts,
            isLandscape: isLandscape,
            pageWidth: pageWidth,
            gap: gap
        )

        let totalHeight = rowHeights.reduce(0, +) + gap * CGFloat(max(0, counts.count - 1))
        let margin = pageHeight - totalHeight

        // Among non-overshooting splits (margin >= 0), the SMALLEST margin
        // wins (0 = a perfect, edge-to-edge fit). An overshooting split
        // (margin < 0, would need cropping to fit) is only used if nothing
        // else fits at all, and even then the smallest overshoot wins.
        let score = margin >= 0 ? margin : (abs(margin) + pageHeight)

        if score < bestScore {
            bestScore = score
            bestSplit = counts
        }
    }

    return bestSplit
}

// The plain row-stack layout: every cell exactly 4:3/3:4, every row spans
// the full page width on its own. Returns the achieved rects plus how much
// top/bottom margin (or, once shrunk to fit, all-around margin) is left —
// the margin is what strict43GridLayout compares against the "hero cell"
// layout below to decide which actually fills the page better.
private func strict43PlainGridRects(
    isLandscape: [Bool],
    pageWidth: CGFloat,
    pageHeight: CGFloat,
    gap: CGFloat,
    manualVariant: Int? = nil
) -> (rects: [CGRect], margin: CGFloat)? {
    guard !isLandscape.isEmpty, pageWidth > 0, pageHeight > 0 else {
        return nil
    }

    let rowCounts: [Int]

    if let manualVariant {
        // Manual mode: pick a specific row-count arrangement out of the
        // curated candidate list (same one strict43LayoutVariantCount
        // reports the size of) instead of auto-scoring for the naturally
        // best-fitting one.
        let candidates = strict43ManualLayoutCandidates(photoCount: isLandscape.count)

        guard !candidates.isEmpty else { return nil }

        let index = ((manualVariant % candidates.count) + candidates.count) % candidates.count
        rowCounts = candidates[index]
    } else {
        rowCounts = strict43BestRowCounts(
            isLandscape: isLandscape,
            pageWidth: pageWidth,
            pageHeight: pageHeight,
            gap: gap
        )
    }

    guard !rowCounts.isEmpty else { return nil }

    var rowsOfRatios: [[CGFloat]] = []
    var cursor = 0

    for rowCount in rowCounts {
        let ratios: [CGFloat] = (cursor..<(cursor + rowCount)).map { isLandscape[$0] ? 4.0 / 3.0 : 3.0 / 4.0 }
        rowsOfRatios.append(ratios)
        cursor += rowCount
    }

    let naturalRowHeights = strict43NaturalRowHeights(
        rowCounts: rowCounts,
        isLandscape: isLandscape,
        pageWidth: pageWidth,
        gap: gap
    )

    let naturalTotalHeight = naturalRowHeights.reduce(0, +) + gap * CGFloat(max(0, rowCounts.count - 1))

    guard naturalTotalHeight > 0 else { return nil }

    // Every row already spans pageWidth exactly at scale 1 (by
    // construction), so only ever scale DOWN, uniformly, if the stacked
    // rows are taller than the page — never up (see the comment above this
    // function for why: there's no room left to grow without clipping a
    // whole cell's content, once a row already spans the full page width).
    let scale = min(1, pageHeight / naturalTotalHeight)
    let scaledGap = gap * scale
    let scaledRowHeights = naturalRowHeights.map { $0 * scale }
    let scaledTotalHeight = scaledRowHeights.reduce(0, +) + scaledGap * CGFloat(max(0, rowCounts.count - 1))

    var rects: [CGRect] = []
    var y = (pageHeight - scaledTotalHeight) / 2

    for (rowIndex, ratios) in rowsOfRatios.enumerated() {
        let rowHeight = scaledRowHeights[rowIndex]
        let widths = ratios.map { $0 * rowHeight }
        let rowWidth = widths.reduce(0, +) + scaledGap * CGFloat(max(0, ratios.count - 1))
        var x = (pageWidth - rowWidth) / 2

        for width in widths {
            rects.append(CGRect(x: x, y: y, width: width, height: rowHeight))
            x += width + scaledGap
        }

        y += rowHeight + scaledGap
    }

    return (rects, abs(pageHeight - scaledTotalHeight))
}

// One PORTRAIT photo becomes a full-page-height "hero" column on the left,
// still exactly 3:4, and everything else packs into the remaining width as
// its own row-stack — for photo counts/orientation mixes where the plain
// row-stack always leaves a gap sized roughly like "one more photo," this
// is what actually closes it, by letting that one photo be a different
// size instead of leaving the space blank.
//
// Only a portrait photo is eligible: a LANDSCAPE photo stretched to the
// full page height turns into an extremely wide column (a 4:3 photo at
// full 900pt height is already 1200pt wide — most of a 1600pt-wide page),
// which crushes everything else into a sliver instead of helping. A 3:4
// portrait at the same height is only 675pt wide, which is what actually
// leaves a usable width for the rest of the grid. A cap on top of that
// keeps the hero from ever dominating the page even for tall/narrow pages.
private func strict43LSplitRects(
    isLandscape: [Bool],
    pageWidth: CGFloat,
    pageHeight: CGFloat,
    gap: CGFloat
) -> (rects: [CGRect], margin: CGFloat)? {
    let count = isLandscape.count

    guard count >= 4, pageWidth > 0, pageHeight > 0 else { return nil }

    let portraitIndexes = (0..<count).filter { !isLandscape[$0] }

    guard !portraitIndexes.isEmpty else { return nil }

    var best: (rects: [CGRect], margin: CGFloat)?
    let maxHeroWidth = pageWidth * 0.45

    for heroIndex in Set([portraitIndexes.first!, portraitIndexes.last!]) {
        let heroWidth = pageHeight * (3.0 / 4.0)

        guard heroWidth > 0, heroWidth <= maxHeroWidth, heroWidth < pageWidth - gap * 2 else { continue }

        let remainingWidth = pageWidth - heroWidth - gap
        var remainingIsLandscape = isLandscape
        remainingIsLandscape.remove(at: heroIndex)

        guard let (subRects, margin) = strict43PlainGridRects(
            isLandscape: remainingIsLandscape,
            pageWidth: remainingWidth,
            pageHeight: pageHeight,
            gap: gap
        ) else {
            continue
        }

        let heroRect = CGRect(x: 0, y: 0, width: heroWidth, height: pageHeight)

        var fullRects = [CGRect](repeating: .zero, count: count)
        fullRects[heroIndex] = heroRect

        var subIndex = 0
        for originalIndex in 0..<count where originalIndex != heroIndex {
            var rect = subRects[subIndex]
            rect.origin.x += heroWidth + gap
            fullRects[originalIndex] = rect
            subIndex += 1
        }

        if best == nil || margin < best!.margin {
            best = (fullRects, margin)
        }
    }

    return best
}

// Three landscape photos, one centered on top and two side by side below
// it, all three the SAME size — unlike the generic row-stack (which forces
// every row to span the full page width on its own, making the lone top
// cell twice as tall as each bottom cell). Sizing all three cells to match
// the bottom pair keeps them visually equal; the top cell is then just
// centered above the gap between the bottom two, even though that leaves
// empty space on either side of it rather than spanning the full width.
private func strict43ThreeLandscapeRects(
    pageWidth: CGFloat,
    pageHeight: CGFloat,
    gap: CGFloat
) -> (rects: [CGRect], margin: CGFloat)? {
    guard pageWidth > 0, pageHeight > 0 else { return nil }

    let cellWidth = (pageWidth - gap) / 2
    guard cellWidth > 0 else { return nil }

    let cellHeight = cellWidth * (3.0 / 4.0)
    let naturalTotalHeight = cellHeight * 2 + gap
    guard naturalTotalHeight > 0 else { return nil }

    // Only ever shrink to fit, never grow, and center whatever margin is
    // left — same convention as the row-stack layout above.
    let scale = min(1, pageHeight / naturalTotalHeight)
    let scaledCellWidth = cellWidth * scale
    let scaledCellHeight = cellHeight * scale
    let scaledGap = gap * scale
    let scaledTotalHeight = scaledCellHeight * 2 + scaledGap
    let bottomRowWidth = scaledCellWidth * 2 + scaledGap

    let y = (pageHeight - scaledTotalHeight) / 2
    let bottomX = (pageWidth - bottomRowWidth) / 2

    let topRect = CGRect(
        x: (pageWidth - scaledCellWidth) / 2,
        y: y,
        width: scaledCellWidth,
        height: scaledCellHeight
    )

    let bottomLeftRect = CGRect(
        x: bottomX,
        y: y + scaledCellHeight + scaledGap,
        width: scaledCellWidth,
        height: scaledCellHeight
    )

    let bottomRightRect = CGRect(
        x: bottomX + scaledCellWidth + scaledGap,
        y: y + scaledCellHeight + scaledGap,
        width: scaledCellWidth,
        height: scaledCellHeight
    )

    return ([topRect, bottomLeftRect, bottomRightRect], pageHeight - scaledTotalHeight)
}

// A client-chosen manualVariant picks a specific row-count arrangement
// directly (see strict43PlainGridRects), skipping the auto-scoring — that
// includes skipping the 3-all-landscape special case and the hero L-split
// comparison below, both of which exist only to pick the naturally
// best-fitting AUTOMATIC layout, not to be cycled through themselves.
private func strict43GridLayout(
    isLandscape: [Bool],
    pageWidth: CGFloat,
    pageHeight: CGFloat,
    gap: CGFloat,
    manualVariant: Int? = nil
) -> [CGRect] {
    if let manualVariant {
        return strict43PlainGridRects(
            isLandscape: isLandscape,
            pageWidth: pageWidth,
            pageHeight: pageHeight,
            gap: gap,
            manualVariant: manualVariant
        )?.rects ?? []
    }

    if isLandscape.count == 3, isLandscape[0], isLandscape[1], isLandscape[2],
       let three = strict43ThreeLandscapeRects(pageWidth: pageWidth, pageHeight: pageHeight, gap: gap) {
        return three.rects
    }

    let plain = strict43PlainGridRects(
        isLandscape: isLandscape,
        pageWidth: pageWidth,
        pageHeight: pageHeight,
        gap: gap
    )

    let lSplit = strict43LSplitRects(
        isLandscape: isLandscape,
        pageWidth: pageWidth,
        pageHeight: pageHeight,
        gap: gap
    )

    switch (plain, lSplit) {
    case let (.some(plain), .some(lSplit)):
        // A small tolerance so the plain grid (simpler, more familiar look)
        // wins ties instead of the hero layout flip-flopping in for a
        // barely-measurable improvement.
        return lSplit.margin + 1 < plain.margin ? lSplit.rects : plain.rects
    case let (.some(plain), nil):
        return plain.rects
    case let (nil, .some(lSplit)):
        return lSplit.rects
    case (nil, nil):
        return []
    }
}

// Total number of manually-selectable row arrangements for a given photo
// count — same candidate list strict43PlainGridRects picks from when a
// manualVariant is supplied. Always at least 1 (a single photo, or any
// count with no valid composition, has nothing to cycle through).
private func strict43LayoutVariantCount(photoCount: Int) -> Int {
    max(1, strict43ManualLayoutCandidates(photoCount: photoCount).count)
}

struct MagazinePreviewPage: View {
    let images: [NSImage]
    let theme: SlideshowVisualTheme
    let activePhotoName: String
    let activePhotoIndex: Int
    let transitionProgress: Double
    let imageFadeSeconds: Double
    let imageDelaySeconds: Double
    let revealStyle: SlideshowTransitionStyle
    let layoutSeed: Int
    let cropByImageIdentity: [ObjectIdentifier: MagazinePhotoCrop]
    var manualLayoutVariant: Int? = nil
    // Only wired up by the Kousei crop editor's page preview — every other
    // caller leaves this nil and tiles render exactly as they did before.
    var onCropChange: ((NSImage, MagazinePhotoCrop) -> Void)? = nil

    private enum PhotoShape {
        case landscape
        case portrait
        case square
    }

    private enum MagazineSlotShape {
        case wide
        case tall
        case flex
    }

    private var pageImages: [NSImage] {
        // Both themes can now reach 6 (magazine43's all-landscape 4->6 bump
        // needs the extra headroom here to actually show the extra photos).
        Array(images.prefix(6))
    }

    private var pagePhotoCount: Int {
        pageImages.count
    }

    private var resolvedVariant: Int {
        resolvedMagazineLayoutVariant(
            photoCount: pagePhotoCount,
            portraitCount: portraitIndexes.count,
            landscapeCount: landscapeIndexes.count,
            uniformTieBreakSeed: layoutSeed,
            manualOverride: manualLayoutVariant
        )
    }

    private var portraitIndexes: [Int] {
        pageImages.indices.filter { shapeForImage(at: $0) == .portrait }
    }

    private var landscapeIndexes: [Int] {
        pageImages.indices.filter { shapeForImage(at: $0) == .landscape }
    }

    private var squareIndexes: [Int] {
        pageImages.indices.filter { shapeForImage(at: $0) == .square }
    }

    private var hasMixedLandscapeAndPortrait: Bool {
        !portraitIndexes.isEmpty && !landscapeIndexes.isEmpty
    }

    private var slotShapesForCurrentLayout: [MagazineSlotShape] {
        switch (pagePhotoCount, resolvedVariant) {
        case (2, 0):
            return [.wide, .tall]
        case (2, _):
            return [.flex, .flex]

        case (3, 0):
            return [.tall, .tall, .flex]
        case (3, 1):
            return [.wide, .wide, .tall]
        case (3, _):
            return [.wide, .flex, .flex]

        case (4, 0):
            return [.tall, .tall, .wide, .wide]
        case (4, 1):
            return [.tall, .wide, .wide, .wide]
        case (4, _):
            return [.wide, .wide, .wide, .wide]

        case (5, 0):
            return [.tall, .tall, .wide, .wide, .wide]
        case (5, 1):
            return [.tall, .wide, .wide, .wide, .wide]
        case (5, _):
            return [.wide, .wide, .wide, .wide, .wide]

        default:
            switch resolvedVariant {
            case 0:
                return [.tall, .tall, .tall, .wide, .wide, .wide]
            case 1:
                return [.wide, .wide, .wide, .tall, .wide, .tall]
            case 2:
                return [.tall, .wide, .wide, .wide, .wide, .wide]
            default:
                return [.wide, .wide, .wide, .wide, .wide, .wide]
            }
        }
    }

    private var orderedPageIndexes: [Int] {
        var used = Set<Int>()
        var result: [Int] = []
        let allIndexes = Array(pageImages.indices)

        func candidates(for slotShape: MagazineSlotShape) -> [Int] {
            switch slotShape {
            case .wide:
                return landscapeIndexes + squareIndexes + portraitIndexes
            case .tall:
                return portraitIndexes + squareIndexes + landscapeIndexes
            case .flex:
                return allIndexes
            }
        }

        func appendFirst(from candidates: [Int]) {
            if let next = candidates.first(where: { !used.contains($0) }) {
                used.insert(next)
                result.append(next)
            }
        }

        func appendAny() {
            appendFirst(from: allIndexes)
        }

        for slotShape in slotShapesForCurrentLayout.prefix(pagePhotoCount) {
            appendFirst(from: candidates(for: slotShape))
        }

        while result.count < pagePhotoCount {
            appendAny()
        }

        return result
    }

    var body: some View {
        GeometryReader { proxy in
            let isCinemaSize = proxy.size.width > 900 || proxy.size.height > 520
            let reservedControlsHeight: CGFloat = isCinemaSize ? 150 : 0
            let availableWidth = max(360, proxy.size.width - 56)
            let availableHeight = max(220, proxy.size.height - 48 - reservedControlsHeight)
            let pageWidth = min(availableWidth, availableHeight * 16 / 9)
            let pageHeight = pageWidth * 9 / 16
            let gap: CGFloat = max(10, min(20, pageWidth * 0.012))
            let pagePadding: CGFloat = gap

            ZStack {
                Color.black
                    .ignoresSafeArea()

                magazineTemplate(
                    width: pageWidth - pagePadding * 2,
                    height: pageHeight - pagePadding * 2,
                    gap: gap
                )
                .padding(pagePadding)
                .frame(width: pageWidth, height: pageHeight)
                .background(Color.black)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }

    @ViewBuilder
    private func magazineTemplate(width: CGFloat, height: CGFloat, gap: CGFloat) -> some View {
        if theme == .magazine43 {
            strict43MagazineTemplate(width: width, height: height, gap: gap)
        } else {
            switch pagePhotoCount {
            case 0:
                Color.black

            case 1:
                tile(slot: 0, revealOrder: 0)

            case 2:
                twoImageMagazineTemplate(width: width, height: height, gap: gap)

            case 3:
                threeImageMagazineTemplate(width: width, height: height, gap: gap)

            case 4:
                fourImageMagazineTemplate(width: width, height: height, gap: gap)

            case 5:
                fiveImageMagazineTemplate(width: width, height: height, gap: gap)

            default:
                sixImageMagazineTemplate(width: width, height: height, gap: gap)
            }
        }
    }

    @ViewBuilder
    private func strict43MagazineTemplate(width: CGFloat, height: CGFloat, gap: CGFloat) -> some View {
        let isLandscape = pageImages.map { $0.size.width >= $0.size.height }
        let rects = strict43GridLayout(
            isLandscape: isLandscape,
            pageWidth: width,
            pageHeight: height,
            gap: gap,
            manualVariant: manualLayoutVariant
        )

        ZStack(alignment: .topLeading) {
            ForEach(Array(pageImages.prefix(rects.count).enumerated()), id: \.offset) { index, image in
                let rect = rects[index]

                MagazineImageTile(
                    image: image,
                    appearAmount: appearAmount(forRevealOrder: index),
                    crop: cropByImageIdentity[ObjectIdentifier(image)] ?? .default,
                    onCropChange: onCropChange.map { callback in
                        { newCrop in callback(image, newCrop) }
                    }
                )
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
            }
        }
        .frame(width: width, height: height)
        .clipped()
    }

    @ViewBuilder
    private func twoImageMagazineTemplate(width: CGFloat, height: CGFloat, gap: CGFloat) -> some View {
        if resolvedVariant == 0 {
            HStack(spacing: gap) {
                tile(slot: 0, revealOrder: 0)
                    .frame(width: (width - gap) * 0.64)

                tile(slot: 1, revealOrder: 1)
            }
        } else {
            HStack(spacing: gap) {
                tile(slot: 0, revealOrder: 0)
                tile(slot: 1, revealOrder: 1)
            }
        }
    }

    @ViewBuilder
    private func threeImageMagazineTemplate(width: CGFloat, height: CGFloat, gap: CGFloat) -> some View {
        if resolvedVariant == 0 {
            HStack(spacing: gap) {
                tile(slot: 0, revealOrder: 0)
                tile(slot: 1, revealOrder: 1)
                tile(slot: 2, revealOrder: 2)
            }
        } else if resolvedVariant == 1 {
            HStack(spacing: gap) {
                VStack(spacing: gap) {
                    tile(slot: 0, revealOrder: 0)
                    tile(slot: 1, revealOrder: 1)
                }
                .frame(width: (width - gap) * 0.62)

                tile(slot: 2, revealOrder: 2)
            }
        } else {
            HStack(spacing: gap) {
                tile(slot: 0, revealOrder: 0)
                    .frame(width: (width - gap) * 0.62)

                VStack(spacing: gap) {
                    tile(slot: 1, revealOrder: 1)
                    tile(slot: 2, revealOrder: 2)
                }
            }
        }
    }

    @ViewBuilder
    private func fourImageMagazineTemplate(width: CGFloat, height: CGFloat, gap: CGFloat) -> some View {
        if resolvedVariant == 0 {
            HStack(spacing: gap) {
                tile(slot: 0, revealOrder: 0)
                tile(slot: 1, revealOrder: 1)

                VStack(spacing: gap) {
                    tile(slot: 2, revealOrder: 2)
                    tile(slot: 3, revealOrder: 3)
                }
                .frame(width: (width - gap * 2) * 0.44)
            }
        } else if resolvedVariant == 1 {
            HStack(spacing: gap) {
                tile(slot: 0, revealOrder: 0)
                    .frame(width: (width - gap) * 0.34)

                VStack(spacing: gap) {
                    tile(slot: 1, revealOrder: 1)
                    tile(slot: 2, revealOrder: 2)
                    tile(slot: 3, revealOrder: 3)
                }
            }
        } else if resolvedVariant == 2 {
            HStack(spacing: gap) {
                tile(slot: 0, revealOrder: 0)
                    .frame(width: (width - gap) * 0.62)

                VStack(spacing: gap) {
                    tile(slot: 1, revealOrder: 1)
                    tile(slot: 2, revealOrder: 2)
                    tile(slot: 3, revealOrder: 3)
                }
            }
        } else {
            VStack(spacing: gap) {
                HStack(spacing: gap) {
                    tile(slot: 0, revealOrder: 0)
                    tile(slot: 1, revealOrder: 1)
                }

                HStack(spacing: gap) {
                    tile(slot: 2, revealOrder: 2)
                    tile(slot: 3, revealOrder: 3)
                }
            }
        }
    }

    @ViewBuilder
    private func fiveImageMagazineTemplate(width: CGFloat, height: CGFloat, gap: CGFloat) -> some View {
        if resolvedVariant == 0 {
            HStack(spacing: gap) {
                tile(slot: 0, revealOrder: 0)
                    .frame(width: (width - gap * 2) * 0.26)

                tile(slot: 1, revealOrder: 1)
                    .frame(width: (width - gap * 2) * 0.26)

                VStack(spacing: gap) {
                    tile(slot: 2, revealOrder: 2)

                    HStack(spacing: gap) {
                        tile(slot: 3, revealOrder: 3)
                        tile(slot: 4, revealOrder: 4)
                    }
                }
            }
        } else if resolvedVariant == 1 {
            HStack(spacing: gap) {
                tile(slot: 0, revealOrder: 0)
                    .frame(width: (width - gap) * 0.34)

                VStack(spacing: gap) {
                    HStack(spacing: gap) {
                        tile(slot: 1, revealOrder: 1)
                        tile(slot: 2, revealOrder: 2)
                    }

                    HStack(spacing: gap) {
                        tile(slot: 3, revealOrder: 3)
                        tile(slot: 4, revealOrder: 4)
                    }
                }
            }
        } else {
            VStack(spacing: gap) {
                HStack(spacing: gap) {
                    tile(slot: 0, revealOrder: 0)
                    tile(slot: 1, revealOrder: 1)
                    tile(slot: 2, revealOrder: 2)
                }
                .frame(height: (height - gap) * 0.48)

                HStack(spacing: gap) {
                    tile(slot: 3, revealOrder: 3)
                    tile(slot: 4, revealOrder: 4)
                }
            }
        }
    }

    @ViewBuilder
    private func sixImageMagazineTemplate(width: CGFloat, height: CGFloat, gap: CGFloat) -> some View {
        if resolvedVariant == 0 {
            HStack(spacing: gap) {
                tile(slot: 0, revealOrder: 0)
                tile(slot: 1, revealOrder: 1)
                tile(slot: 2, revealOrder: 2)

                VStack(spacing: gap) {
                    tile(slot: 3, revealOrder: 3)
                    tile(slot: 4, revealOrder: 4)
                    tile(slot: 5, revealOrder: 5)
                }
                .frame(width: (width - gap * 3) * 0.34)
            }
        } else if resolvedVariant == 1 {
            VStack(spacing: gap) {
                HStack(spacing: gap) {
                    tile(slot: 0, revealOrder: 0)
                    tile(slot: 1, revealOrder: 1)
                    tile(slot: 2, revealOrder: 2)
                }
                .frame(height: (height - gap) * 0.48)

                HStack(spacing: gap) {
                    tile(slot: 3, revealOrder: 3)
                        .frame(width: (width - gap * 2) * 0.25)

                    tile(slot: 4, revealOrder: 4)

                    tile(slot: 5, revealOrder: 5)
                        .frame(width: (width - gap * 2) * 0.25)
                }
            }
        } else if resolvedVariant == 2 {
            HStack(spacing: gap) {
                tile(slot: 0, revealOrder: 0)
                    .frame(width: (width - gap) * 0.28)

                VStack(spacing: gap) {
                    HStack(spacing: gap) {
                        tile(slot: 1, revealOrder: 1)
                        tile(slot: 2, revealOrder: 2)
                    }

                    HStack(spacing: gap) {
                        tile(slot: 3, revealOrder: 3)
                        tile(slot: 4, revealOrder: 4)
                        tile(slot: 5, revealOrder: 5)
                    }
                }
            }
        } else if resolvedVariant == 3 {
            VStack(spacing: gap) {
                HStack(spacing: gap) {
                    tile(slot: 0, revealOrder: 0)
                    tile(slot: 1, revealOrder: 1)
                    tile(slot: 2, revealOrder: 2)
                    tile(slot: 3, revealOrder: 3)
                }
                .frame(height: (height - gap) * 0.35)

                HStack(spacing: gap) {
                    tile(slot: 4, revealOrder: 4)
                    tile(slot: 5, revealOrder: 5)
                }
            }
        } else {
            HStack(spacing: gap) {
                tile(slot: 0, revealOrder: 0)
                    .frame(width: (width - gap) * 0.58)

                VStack(spacing: gap) {
                    tile(slot: 1, revealOrder: 1)

                    HStack(spacing: gap) {
                        tile(slot: 2, revealOrder: 2)
                        tile(slot: 3, revealOrder: 3)
                    }

                    HStack(spacing: gap) {
                        tile(slot: 4, revealOrder: 4)
                        tile(slot: 5, revealOrder: 5)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func tile(slot: Int, revealOrder: Int) -> some View {
        if let image = imageForSlot(slot) {
            MagazineImageTile(
                image: image,
                appearAmount: appearAmount(forRevealOrder: revealOrder),
                crop: cropByImageIdentity[ObjectIdentifier(image)] ?? .default,
                onCropChange: onCropChange.map { callback in
                    { newCrop in callback(image, newCrop) }
                }
            )
        } else {
            Color.black
        }
    }

    private func imageForSlot(_ slot: Int) -> NSImage? {
        guard orderedPageIndexes.indices.contains(slot) else {
            return nil
        }

        let imageIndex = orderedPageIndexes[slot]

        guard pageImages.indices.contains(imageIndex) else {
            return nil
        }

        return pageImages[imageIndex]
    }

    private func shapeForImage(at index: Int) -> PhotoShape {
        guard pageImages.indices.contains(index) else {
            return .landscape
        }

        let size = pageImages[index].size
        guard size.width > 0, size.height > 0 else {
            return .landscape
        }

        let ratio = size.width / size.height

        if ratio > 1.18 {
            return .landscape
        }

        if ratio < 0.82 {
            return .portrait
        }

        return .square
    }

    private func appearAmount(forRevealOrder order: Int) -> Double {
        let fadeSeconds = max(0.05, imageFadeSeconds)
        let delaySeconds = max(0, imageDelaySeconds)
        let revealOnlySeconds = max(fadeSeconds, fadeSeconds + (delaySeconds * 5))
        let startSeconds = Double(order) * delaySeconds
        let elapsedSeconds = (transitionProgress * revealOnlySeconds) - startSeconds

        if revealStyle == .blink {
            return elapsedSeconds >= 0 ? 1 : 0
        }

        return min(1, max(0, elapsedSeconds / fadeSeconds))
    }
}

struct MagazineImageTile: View {
    let image: NSImage
    let appearAmount: Double
    let crop: MagazinePhotoCrop
    // Only set by the Kousei crop editor's page preview, so every other
    // caller (slideshow playback, export rendering) keeps rendering this
    // tile exactly as before with no gesture attached.
    var onCropChange: ((MagazinePhotoCrop) -> Void)? = nil

    @State private var dragTranslation: CGSize = .zero

    private var revealShadowOpacity: Double {
        0.085 + (1 - appearAmount) * 0.34
    }

    private var revealShadowRadius: Double {
        1.4 + (1 - appearAmount) * 3.0
    }

    private var revealShadowXOffset: Double {
        -2.2 - ((1 - appearAmount) * 8.5)
    }

    private var revealShadowYOffset: Double {
        -0.8 - ((1 - appearAmount) * 2.4)
    }

    private var tileContent: some View {
        GeometryReader { proxy in
            let baseOffset = magazineCropOffset(
                imageSize: image.size,
                frameSize: proxy.size,
                crop: crop
            )

            ZStack {
                Color.black

                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .scaleEffect(max(1, crop.zoom))
                    .offset(
                        CGSize(
                            width: baseOffset.width + dragTranslation.width,
                            height: baseOffset.height + dragTranslation.height
                        )
                    )
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
            .opacity(appearAmount)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        dragTranslation = value.translation
                    }
                    .onEnded { value in
                        commitDrag(
                            translation: value.translation,
                            imageSize: image.size,
                            frameSize: proxy.size
                        )
                        dragTranslation = .zero
                    },
                including: onCropChange != nil ? .all : .subviews
            )
        }
        .clipped()
    }

    private func commitDrag(translation: CGSize, imageSize: CGSize, frameSize: CGSize) {
        guard let onCropChange else {
            return
        }

        let renderedSize = magazineCropRenderSize(
            imageSize: imageSize,
            frameSize: frameSize,
            zoom: CGFloat(crop.zoom)
        )

        let overflowX = renderedSize.width - frameSize.width
        let overflowY = renderedSize.height - frameSize.height

        let currentOffset = magazineCropOffset(
            imageSize: imageSize,
            frameSize: frameSize,
            crop: crop
        )

        var newCrop = crop

        if overflowX > 1 {
            let newOffsetX = currentOffset.width + translation.width
            newCrop.focusX = min(1, max(0, 0.5 - newOffsetX / overflowX))
        }

        if overflowY > 1 {
            let newOffsetY = currentOffset.height + translation.height
            newCrop.focusY = min(1, max(0, 0.5 - newOffsetY / overflowY))
        }

        onCropChange(newCrop)
    }

    var body: some View {
        // The drop shadow only matters while the photo is fading in; once
        // fully revealed, skipping it removes a continuous blur-compositing
        // cost that adds up across a full page of tiles on weaker GPUs.
        if appearAmount < 1 {
            tileContent
                .shadow(
                    color: Color.black.opacity(revealShadowOpacity),
                    radius: revealShadowRadius,
                    x: revealShadowXOffset,
                    y: revealShadowYOffset
                )
        } else {
            tileContent
        }
    }
}

// Renders a single Kirigami slot's photo at rest (no fold/swap animation).
// Broken out as its own View so each slot gets independent @State for its
// own drag-to-reposition gesture rather than one shared across the whole page.
private struct OrigamiCropImage: View {
    let image: NSImage
    let crop: MagazinePhotoCrop
    var onCropChange: ((MagazinePhotoCrop) -> Void)? = nil

    @State private var dragTranslation: CGSize = .zero

    var body: some View {
        GeometryReader { proxy in
            let baseOffset = magazineCropOffset(
                imageSize: image.size,
                frameSize: proxy.size,
                crop: crop
            )

            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: proxy.size.width, height: proxy.size.height)
                .scaleEffect(max(1, crop.zoom))
                .offset(
                    CGSize(
                        width: baseOffset.width + dragTranslation.width,
                        height: baseOffset.height + dragTranslation.height
                    )
                )
                .frame(width: proxy.size.width, height: proxy.size.height)
                .clipped()
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 2)
                        .onChanged { value in
                            dragTranslation = value.translation
                        }
                        .onEnded { value in
                            commitDrag(translation: value.translation, frameSize: proxy.size)
                            dragTranslation = .zero
                        },
                    including: onCropChange != nil ? .all : .subviews
                )
        }
    }

    private func commitDrag(translation: CGSize, frameSize: CGSize) {
        guard let onCropChange else {
            return
        }

        let renderedSize = magazineCropRenderSize(
            imageSize: image.size,
            frameSize: frameSize,
            zoom: CGFloat(crop.zoom)
        )

        let overflowX = renderedSize.width - frameSize.width
        let overflowY = renderedSize.height - frameSize.height

        let currentOffset = magazineCropOffset(
            imageSize: image.size,
            frameSize: frameSize,
            crop: crop
        )

        var newCrop = crop

        if overflowX > 1 {
            let newOffsetX = currentOffset.width + translation.width
            newCrop.focusX = min(1, max(0, 0.5 - newOffsetX / overflowX))
        }

        if overflowY > 1 {
            let newOffsetY = currentOffset.height + translation.height
            newCrop.focusY = min(1, max(0, 0.5 - newOffsetY / overflowY))
        }

        onCropChange(newCrop)
    }
}

private func resolvedOrigamiLayoutVariant(
    photoCount: Int,
    portraitCount: Int,
    landscapeCount: Int,
    wideCount: Int,
    manualOverride: Int?
) -> Int {
    let defaultVariant: Int
    let totalVariants: Int

    switch photoCount {
    case 2:
        totalVariants = 4
        if portraitCount == 2 {
            defaultVariant = 0
        } else if wideCount == 2 {
            defaultVariant = 1
        } else if landscapeCount == 2 {
            defaultVariant = 2
        } else {
            defaultVariant = 3
        }

    case 3:
        totalVariants = 3
        if portraitCount == 3 {
            defaultVariant = 0
        } else if landscapeCount == 3 {
            defaultVariant = 1
        } else {
            defaultVariant = 2
        }

    case 4:
        totalVariants = 2
        defaultVariant = portraitCount >= 2 ? 0 : 1

    case 5:
        totalVariants = 2
        defaultVariant = portraitCount >= 1 ? 0 : 1

    default:
        totalVariants = 3
        defaultVariant = portraitCount >= 2 ? 0 : (portraitCount == 1 ? 1 : 2)
    }

    guard let manualOverride else {
        return defaultVariant
    }

    let normalized = manualOverride % totalVariants
    return normalized >= 0 ? normalized : normalized + totalVariants
}

private func origamiLayoutVariantCount(photoCount: Int) -> Int {
    switch photoCount {
    case 2: return 4
    case 3: return 3
    case 4: return 2
    case 5: return 2
    default: return 3
    }
}

struct OrigamiPreviewPage: View {
    let images: [NSImage]
    var theme: SlideshowVisualTheme = .origami
    let slotReplacementImages: [Int: NSImage]
    let activeSwapImages: [Int: NSImage]
    let activeSwapStyles: [Int: Int]
    let swapProgress: Double
    let activePhotoName: String
    let showsPhotoName: Bool
    let transitionProgress: Double
    let animationVariant: Int
    let cropByImageIdentity: [ObjectIdentifier: MagazinePhotoCrop]
    var manualLayoutVariant: Int? = nil
    // Only wired up by the Kirigami crop editor's page preview — every other
    // caller leaves this nil and tiles render exactly as they did before.
    var onCropChange: ((NSImage, MagazinePhotoCrop) -> Void)? = nil

    private func crop(for image: NSImage) -> MagazinePhotoCrop {
        cropByImageIdentity[ObjectIdentifier(image)] ?? .default
    }

    private enum OrigamiPhotoClass {
        case ultraPortrait
        case portrait
        case square
        case landscape
        case wide
        case ultraWide
    }

    private enum OrigamiLayout {
        case one
        case twoPortrait
        case twoLandscape
        case twoLandscapeModerate
        case twoMixed
        case threePortrait
        case threeLandscape
        case threeMixed
        case four
        case five
        case six
    }

    private var pageImages: [NSImage] {
        Array(images.prefix(theme == .origami43 ? 4 : 6))
    }

    private func aspectRatio(of image: NSImage) -> CGFloat {
        guard image.size.width > 0,
              image.size.height > 0 else {
            return 1
        }

        return image.size.width / image.size.height
    }

    private func photoClass(of image: NSImage) -> OrigamiPhotoClass {
        let ratio = aspectRatio(of: image)

        switch ratio {
        case ..<0.72:
            return .ultraPortrait

        case ..<0.90:
            return .portrait

        case ..<1.15:
            return .square

        case ..<1.70:
            return .landscape

        case ..<2.30:
            return .wide

        default:
            return .ultraWide
        }
    }

    private var pagePhotoClasses: [OrigamiPhotoClass] {
        pageImages.map(photoClass)
    }

    private var portraitCount: Int {
        pagePhotoClasses.filter {
            $0 == .portrait || $0 == .ultraPortrait
        }.count
    }

    private var landscapeCount: Int {
        pagePhotoClasses.filter {
            $0 == .landscape ||
            $0 == .wide ||
            $0 == .ultraWide
        }.count
    }

    private var wideCount: Int {
        pagePhotoClasses.filter {
            $0 == .wide || $0 == .ultraWide
        }.count
    }

    private func chooseLayout() -> OrigamiLayout {
        switch pageImages.count {
        case 1:
            return .one

        case 2:
            // Only stack into tall, ultra-wide slots when both
            // photos are actually wide/panoramic. Moderate
            // landscape shots (4:3, 3:2, and similar) belong
            // side by side, or a stacked layout would crop off
            // most of their width.
            switch resolvedOrigamiLayoutVariant(
                photoCount: 2,
                portraitCount: portraitCount,
                landscapeCount: landscapeCount,
                wideCount: wideCount,
                manualOverride: manualLayoutVariant
            ) {
            case 0:
                return .twoPortrait
            case 1:
                return .twoLandscape
            case 2:
                return .twoLandscapeModerate
            default:
                return .twoMixed
            }

        case 3:
            switch resolvedOrigamiLayoutVariant(
                photoCount: 3,
                portraitCount: portraitCount,
                landscapeCount: landscapeCount,
                wideCount: wideCount,
                manualOverride: manualLayoutVariant
            ) {
            case 0:
                return .threePortrait
            case 1:
                return .threeLandscape
            default:
                return .threeMixed
            }

        case 4:
            return .four

        case 5:
            return .five

        default:
            return .six
        }
    }

    private func mismatchScore(
        imageAspect: CGFloat,
        slotAspect: CGFloat
    ) -> CGFloat {
        let safeImageAspect = max(0.01, imageAspect)
        let safeSlotAspect = max(0.01, slotAspect)

        var score = max(
            safeImageAspect / safeSlotAspect,
            safeSlotAspect / safeImageAspect
        ) - 1

        let imageIsPortrait = safeImageAspect < 0.90
        let imageIsLandscape = safeImageAspect > 1.15

        let slotIsPortrait = safeSlotAspect < 0.90
        let slotIsLandscape = safeSlotAspect > 1.15

        // Strongly discourage putting horizontal photos
        // inside portrait slots, and vice versa.
        if imageIsPortrait && slotIsLandscape {
            score += 2.4
        }

        if imageIsLandscape && slotIsPortrait {
            score += 2.4
        }

        // Extra protection for panoramas.
        if safeImageAspect > 2.0 && safeSlotAspect < 1.25 {
            score += 1.4
        }

        // Extra protection for very tall portraits.
        if safeImageAspect < 0.65 && safeSlotAspect > 1.0 {
            score += 1.4
        }

        return score
    }

    private func bestImageOrder(
        for slotAspects: [CGFloat]
    ) -> [NSImage] {
        let count = min(pageImages.count, slotAspects.count)

        guard count > 1 else {
            return pageImages
        }

        var bestOrder = Array(0..<count)
        var bestScore = CGFloat.greatestFiniteMagnitude

        var currentOrder: [Int] = []
        var used = Array(
            repeating: false,
            count: count
        )

        func search(
            slotIndex: Int,
            runningScore: CGFloat
        ) {
            if runningScore >= bestScore {
                return
            }

            if slotIndex == count {
                bestScore = runningScore
                bestOrder = currentOrder
                return
            }

            let targetAspect = max(
                0.01,
                slotAspects[slotIndex]
            )

            for imageIndex in 0..<count {
                guard !used[imageIndex] else {
                    continue
                }

                let imageAspect = aspectRatio(
                    of: pageImages[imageIndex]
                )

                var score = mismatchScore(
                    imageAspect: imageAspect,
                    slotAspect: targetAspect
                )

                // Tiny tie-breaker keeps the original order
                // when two matches are almost identical.
                score += CGFloat(
                    abs(imageIndex - slotIndex)
                ) * 0.001

                used[imageIndex] = true
                currentOrder.append(imageIndex)

                search(
                    slotIndex: slotIndex + 1,
                    runningScore: runningScore + score
                )

                currentOrder.removeLast()
                used[imageIndex] = false
            }
        }

        search(
            slotIndex: 0,
            runningScore: 0
        )

        return bestOrder.map {
            pageImages[$0]
        }
    }

    private var normalizedAnimationVariant: Int {
        let variant = animationVariant % 3
        return variant >= 0 ? variant : variant + 3
    }

    private func tileSlot(for image: NSImage) -> Int {
        pageImages.firstIndex { candidate in
            candidate === image
        } ?? 0
    }

    private func revealOrder(for slot: Int) -> Int {
        let count = max(1, pageImages.count)

        switch normalizedAnimationVariant {
        case 0:
            // Left-to-right accordion.
            return slot

        case 1:
            // Reverse top/bottom fold.
            return max(0, count - 1 - slot)

        default:
            // Center-out cascade.
            let center = Double(count - 1) / 2
            return Int(
                abs(Double(slot) - center) * 2
            )
        }
    }

    private func tileAnimationProgress(
        for slot: Int
    ) -> Double {
        let safeGlobalProgress = min(
            1,
            max(0, transitionProgress)
        )

        let order = revealOrder(for: slot)
        let delay = Double(order) * 0.055
        let animationSpan = 0.72

        let rawProgress = (
            safeGlobalProgress - delay
        ) / animationSpan

        let clampedProgress = min(
            1,
            max(0, rawProgress)
        )

        // Smoothstep curve.
        return clampedProgress
            * clampedProgress
            * (3 - 2 * clampedProgress)
    }

    private func foldAxis(
        for slot: Int
    ) -> (
        x: CGFloat,
        y: CGFloat,
        z: CGFloat
    ) {
        switch normalizedAnimationVariant {
        case 0:
            return (
                x: 0,
                y: 1,
                z: 0
            )

        case 1:
            return (
                x: 1,
                y: 0,
                z: 0
            )

        default:
            if slot.isMultiple(of: 2) {
                return (
                    x: 0.30,
                    y: 1,
                    z: 0
                )
            }

            return (
                x: 1,
                y: 0.30,
                z: 0
            )
        }
    }

    private func foldAnchor(
        for slot: Int
    ) -> UnitPoint {
        switch normalizedAnimationVariant {
        case 0:
            return slot.isMultiple(of: 2)
                ? .leading
                : .trailing

        case 1:
            return slot.isMultiple(of: 2)
                ? .top
                : .bottom

        default:
            return .center
        }
    }

    private func foldAngle(
        for slot: Int,
        progress: Double
    ) -> Double {
        let remaining = 1 - progress
        let direction = slot.isMultiple(of: 2)
            ? -1.0
            : 1.0

        switch normalizedAnimationVariant {
        case 0:
            return direction
                * 88
                * remaining

        case 1:
            return direction
                * 82
                * remaining

        default:
            return direction
                * 70
                * remaining
        }
    }

    private func foldOffset(
        for slot: Int,
        progress: Double,
        size: CGSize
    ) -> CGSize {
        let remaining = CGFloat(1 - progress)
        let direction: CGFloat =
            slot.isMultiple(of: 2) ? -1 : 1

        switch normalizedAnimationVariant {
        case 0:
            return CGSize(
                width:
                    direction
                    * size.width
                    * 0.10
                    * remaining,
                height: 0
            )

        case 1:
            return CGSize(
                width: 0,
                height:
                    direction
                    * size.height
                    * 0.10
                    * remaining
            )

        default:
            let horizontalDirection: CGFloat =
                slot % 4 < 2 ? -1 : 1

            let verticalDirection: CGFloat =
                slot.isMultiple(of: 2) ? -1 : 1

            return CGSize(
                width:
                    horizontalDirection
                    * size.width
                    * 0.055
                    * remaining,
                height:
                    verticalDirection
                    * size.height
                    * 0.055
                    * remaining
            )
        }
    }

    private func foldScale(
        progress: Double
    ) -> CGFloat {
        guard normalizedAnimationVariant == 2 else {
            return 1
        }

        return 0.88
            + CGFloat(progress) * 0.12
    }

    private func swapSmoothStep(
        _ value: Double
    ) -> Double {
        let clamped = min(
            1,
            max(0, value)
        )

        return clamped
            * clamped
            * (3 - 2 * clamped)
    }

    @ViewBuilder
    private func foldPanel(
        image: NSImage,
        fullSize: CGSize,
        panelSize: CGSize,
        cropOffset: CGSize,
        zoom: Double = 1,
        position: CGPoint,
        anchor: UnitPoint,
        axis: (
            x: CGFloat,
            y: CGFloat,
            z: CGFloat
        ),
        angle: Double,
        opacity: Double
    ) -> some View {
        Image(nsImage: image)
            .resizable()
            .scaledToFill()
            .frame(
                width: fullSize.width,
                height: fullSize.height
            )
            .scaleEffect(max(1, zoom))
            .offset(
                x: cropOffset.width,
                y: cropOffset.height
            )
            .frame(
                width: panelSize.width,
                height: panelSize.height
            )
            .clipped()
            .rotation3DEffect(
                .degrees(angle),
                axis: axis,
                anchor: anchor,
                anchorZ: 0,
                perspective: 0.72
            )
            .opacity(opacity)
            .frame(
                width: panelSize.width,
                height: panelSize.height
            )
            .position(position)
    }

    @ViewBuilder
    private func halfFoldSwapTile(
        oldImage: NSImage,
        newImage: NSImage,
        progress: Double,
        size: CGSize
    ) -> some View {
        let width = max(1, size.width)
        let height = max(1, size.height)
        let halfWidth = width * 0.5

        let foldProgress =
            swapSmoothStep(
                progress / 0.84
            )

        let oldOpacity = max(
            0,
            1 - swapSmoothStep(
                (progress - 0.68) / 0.32
            )
        )

        let angle =
            94 * foldProgress

        // Match the static tile's manual crop so the image doesn't
        // visibly jump the instant the swap finishes.
        let oldCrop = crop(for: oldImage)
        let newCrop = crop(for: newImage)

        let oldCropOffset =
            magazineCropOffset(
                imageSize: oldImage.size,
                frameSize: size,
                crop: oldCrop
            )

        let newCropOffset =
            magazineCropOffset(
                imageSize: newImage.size,
                frameSize: size,
                crop: newCrop
            )

        ZStack {
            // New image stays behind the old image.
            Image(nsImage: newImage)
                .resizable()
                .scaledToFill()
                .frame(
                    width: width,
                    height: height
                )
                .scaleEffect(max(1, newCrop.zoom))
                .offset(newCropOffset)
                .frame(
                    width: width,
                    height: height
                )
                .clipped()

            foldPanel(
                image: oldImage,
                fullSize: size,
                panelSize: CGSize(
                    width: halfWidth,
                    height: height
                ),
                cropOffset: CGSize(
                    width: width * 0.25 + oldCropOffset.width,
                    height: oldCropOffset.height
                ),
                zoom: oldCrop.zoom,
                position: CGPoint(
                    x: width * 0.25,
                    y: height * 0.5
                ),
                anchor: .trailing,
                axis: (
                    x: 0,
                    y: 1,
                    z: 0
                ),
                angle: -angle,
                opacity: oldOpacity
            )

            foldPanel(
                image: oldImage,
                fullSize: size,
                panelSize: CGSize(
                    width: halfWidth,
                    height: height
                ),
                cropOffset: CGSize(
                    width: -width * 0.25 + oldCropOffset.width,
                    height: oldCropOffset.height
                ),
                zoom: oldCrop.zoom,
                position: CGPoint(
                    x: width * 0.75,
                    y: height * 0.5
                ),
                anchor: .leading,
                axis: (
                    x: 0,
                    y: 1,
                    z: 0
                ),
                angle: angle,
                opacity: oldOpacity
            )
        }
        .frame(
            width: width,
            height: height
        )
        .clipped()
    }

    @ViewBuilder
    private func quarterFoldSwapTile(
        oldImage: NSImage,
        newImage: NSImage,
        progress: Double,
        size: CGSize
    ) -> some View {
        let width = max(1, size.width)
        let height = max(1, size.height)

        let panelSize = CGSize(
            width: width * 0.5,
            height: height * 0.5
        )

        let foldProgress =
            swapSmoothStep(
                progress / 0.86
            )

        let oldOpacity = max(
            0,
            1 - swapSmoothStep(
                (progress - 0.68) / 0.32
            )
        )

        let angle =
            92 * foldProgress

        // Match the static tile's manual crop so the image doesn't
        // visibly jump the instant the swap finishes.
        let oldCrop = crop(for: oldImage)
        let newCrop = crop(for: newImage)

        let oldCropOffset =
            magazineCropOffset(
                imageSize: oldImage.size,
                frameSize: size,
                crop: oldCrop
            )

        let newCropOffset =
            magazineCropOffset(
                imageSize: newImage.size,
                frameSize: size,
                crop: newCrop
            )

        ZStack {
            // New image stays behind all four old quarters.
            Image(nsImage: newImage)
                .resizable()
                .scaledToFill()
                .frame(
                    width: width,
                    height: height
                )
                .scaleEffect(max(1, newCrop.zoom))
                .offset(newCropOffset)
                .frame(
                    width: width,
                    height: height
                )
                .clipped()

            foldPanel(
                image: oldImage,
                fullSize: size,
                panelSize: panelSize,
                cropOffset: CGSize(
                    width: width * 0.25 + oldCropOffset.width,
                    height: height * 0.25 + oldCropOffset.height
                ),
                zoom: oldCrop.zoom,
                position: CGPoint(
                    x: width * 0.25,
                    y: height * 0.25
                ),
                anchor: .bottomTrailing,
                axis: (
                    x: 1,
                    y: -1,
                    z: 0
                ),
                angle: -angle,
                opacity: oldOpacity
            )

            foldPanel(
                image: oldImage,
                fullSize: size,
                panelSize: panelSize,
                cropOffset: CGSize(
                    width: -width * 0.25 + oldCropOffset.width,
                    height: height * 0.25 + oldCropOffset.height
                ),
                zoom: oldCrop.zoom,
                position: CGPoint(
                    x: width * 0.75,
                    y: height * 0.25
                ),
                anchor: .bottomLeading,
                axis: (
                    x: 1,
                    y: 1,
                    z: 0
                ),
                angle: angle,
                opacity: oldOpacity
            )

            foldPanel(
                image: oldImage,
                fullSize: size,
                panelSize: panelSize,
                cropOffset: CGSize(
                    width: width * 0.25 + oldCropOffset.width,
                    height: -height * 0.25 + oldCropOffset.height
                ),
                zoom: oldCrop.zoom,
                position: CGPoint(
                    x: width * 0.25,
                    y: height * 0.75
                ),
                anchor: .topTrailing,
                axis: (
                    x: 1,
                    y: 1,
                    z: 0
                ),
                angle: angle,
                opacity: oldOpacity
            )

            foldPanel(
                image: oldImage,
                fullSize: size,
                panelSize: panelSize,
                cropOffset: CGSize(
                    width: -width * 0.25 + oldCropOffset.width,
                    height: -height * 0.25 + oldCropOffset.height
                ),
                zoom: oldCrop.zoom,
                position: CGPoint(
                    x: width * 0.75,
                    y: height * 0.75
                ),
                anchor: .topLeading,
                axis: (
                    x: 1,
                    y: -1,
                    z: 0
                ),
                angle: -angle,
                opacity: oldOpacity
            )
        }
        .frame(
            width: width,
            height: height
        )
        .clipped()
    }

    private func internalSwapTile(
        oldImage: NSImage,
        newImage: NSImage,
        style: Int,
        progress: Double,
        size: CGSize
    ) -> AnyView {
        if style.isMultiple(of: 2) {
            return AnyView(
                halfFoldSwapTile(
                    oldImage: oldImage,
                    newImage: newImage,
                    progress: progress,
                    size: size
                )
            )
        }

        return AnyView(
            quarterFoldSwapTile(
                oldImage: oldImage,
                newImage: newImage,
                progress: progress,
                size: size
            )
        )
    }

    private func tile(
        _ image: NSImage
    ) -> AnyView {
        AnyView(
            GeometryReader { proxy in
                let slot =
                    tileSlot(for: image)

                let displayedImage =
                    slotReplacementImages[slot]
                    ?? image

                let localProgress =
                    tileAnimationProgress(
                        for: slot
                    )

                let axis =
                    foldAxis(for: slot)

                let anchor =
                    foldAnchor(for: slot)

                let angle =
                    foldAngle(
                        for: slot,
                        progress: localProgress
                    )

                let offset =
                    foldOffset(
                        for: slot,
                        progress: localProgress,
                        size: proxy.size
                    )

                let opacity = min(
                    1,
                    max(
                        0,
                        localProgress * 3
                    )
                )

                AnyView(
                    ZStack {
                        if let incomingImage =
                            activeSwapImages[slot] {

                            internalSwapTile(
                                oldImage:
                                    displayedImage,
                                newImage:
                                    incomingImage,
                                style:
                                    activeSwapStyles[slot] ?? 0,
                                progress:
                                    swapProgress,
                                size:
                                    proxy.size
                            )
                        } else {
                            OrigamiCropImage(
                                image: displayedImage,
                                crop: crop(for: displayedImage),
                                onCropChange: onCropChange.map { callback in
                                    { newCrop in callback(displayedImage, newCrop) }
                                }
                            )
                        }
                    }
                    .frame(
                        width:
                            proxy.size.width,
                        height:
                            proxy.size.height
                    )
                    .clipped()
                    .scaleEffect(
                        foldScale(
                            progress:
                                localProgress
                        )
                    )
                    .rotation3DEffect(
                        .degrees(angle),
                        axis: axis,
                        anchor: anchor,
                        anchorZ: 0,
                        perspective: 0.72
                    )
                    .offset(
                        x: offset.width,
                        y: offset.height
                    )
                    .opacity(opacity)
                    .zIndex(
                        Double(
                            pageImages.count
                            - slot
                        )
                    )
                )
            }
            .clipped()
        )
    }

    @ViewBuilder
    private func collage(in size: CGSize) -> some View {
        if theme == .origami43 {
            strict43Collage(in: size)
        } else {
            switch pageImages.count {
            case 0:
                Color.black

            case 1:
                tile(pageImages[0])

            case 2:
                twoImageTemplate(in: size)

            case 3:
                threeImageTemplate(in: size)

            case 4:
                fourImageTemplate(in: size)

            case 5:
                fiveImageTemplate(in: size)

            default:
                sixImageTemplate(in: size)
            }
        }
    }

    @ViewBuilder
    private func strict43Collage(in size: CGSize) -> some View {
        let isLandscape = pageImages.map { $0.size.width >= $0.size.height }
        let rects = strict43GridLayout(
            isLandscape: isLandscape,
            pageWidth: size.width,
            pageHeight: size.height,
            gap: 0
        )

        ZStack(alignment: .topLeading) {
            ForEach(Array(pageImages.prefix(rects.count).enumerated()), id: \.offset) { index, image in
                let rect = rects[index]

                tile(image)
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
    }

    @ViewBuilder
    private func twoImageTemplate(in size: CGSize) -> some View {
        let canvasAspect =
            size.width / max(1, size.height)

        switch chooseLayout() {
        case .twoPortrait:
            let ordered = bestImageOrder(
                for: [
                    canvasAspect * 0.50,
                    canvasAspect * 0.50
                ]
            )

            HStack(spacing: 0) {
                tile(ordered[0])
                tile(ordered[1])
            }

        case .twoLandscape:
            let ordered = bestImageOrder(
                for: [
                    canvasAspect * 2.0,
                    canvasAspect * 2.0
                ]
            )

            VStack(spacing: 0) {
                tile(ordered[0])
                tile(ordered[1])
            }

        case .twoLandscapeModerate:
            // 4:3/3:2-style photos aren't wide enough for the
            // stacked layout above without losing most of their
            // width, so place them side by side instead.
            let ordered = bestImageOrder(
                for: [
                    canvasAspect * 0.50,
                    canvasAspect * 0.50
                ]
            )

            HStack(spacing: 0) {
                tile(ordered[0])
                tile(ordered[1])
            }

        default:
            let ordered = bestImageOrder(
                for: [
                    canvasAspect * 0.38,
                    canvasAspect * 0.62
                ]
            )

            HStack(spacing: 0) {
                tile(ordered[0])
                    .frame(width: size.width * 0.38)

                tile(ordered[1])
                    .frame(width: size.width * 0.62)
            }
        }
    }

    @ViewBuilder
    private func threeImageTemplate(in size: CGSize) -> some View {
        let canvasAspect =
            size.width / max(1, size.height)

        switch chooseLayout() {
        case .threePortrait:
            let ordered = bestImageOrder(
                for: [
                    canvasAspect / 3,
                    canvasAspect / 3,
                    canvasAspect / 3
                ]
            )

            HStack(spacing: 0) {
                tile(ordered[0])
                tile(ordered[1])
                tile(ordered[2])
            }

        case .threeLandscape:
            let ordered = bestImageOrder(
                for: [
                    canvasAspect * 0.60,
                    canvasAspect * 0.80,
                    canvasAspect * 0.80
                ]
            )

            HStack(spacing: 0) {
                tile(ordered[0])
                    .frame(width: size.width * 0.60)

                VStack(spacing: 0) {
                    tile(ordered[1])
                    tile(ordered[2])
                }
                .frame(width: size.width * 0.40)
            }

        default:
            let ordered = bestImageOrder(
                for: [
                    canvasAspect * 0.34,
                    canvasAspect * 1.32,
                    canvasAspect * 1.32
                ]
            )

            HStack(spacing: 0) {
                tile(ordered[0])
                    .frame(width: size.width * 0.34)

                VStack(spacing: 0) {
                    tile(ordered[1])
                    tile(ordered[2])
                }
                .frame(width: size.width * 0.66)
            }
        }
    }

    @ViewBuilder
    private func fourImageTemplate(in size: CGSize) -> some View {
        let canvasAspect =
            size.width / max(1, size.height)

        if resolvedOrigamiLayoutVariant(
            photoCount: 4,
            portraitCount: portraitCount,
            landscapeCount: landscapeCount,
            wideCount: wideCount,
            manualOverride: manualLayoutVariant
        ) == 0 {
            let ordered = bestImageOrder(
                for: [
                    canvasAspect * 0.24,
                    canvasAspect * 1.04,
                    canvasAspect * 1.04,
                    canvasAspect * 0.24
                ]
            )

            HStack(spacing: 0) {
                tile(ordered[0])
                    .frame(width: size.width * 0.24)

                VStack(spacing: 0) {
                    tile(ordered[1])
                    tile(ordered[2])
                }
                .frame(width: size.width * 0.52)

                tile(ordered[3])
                    .frame(width: size.width * 0.24)
            }
        } else {
            let ordered = bestImageOrder(
                for: [
                    canvasAspect,
                    canvasAspect,
                    canvasAspect,
                    canvasAspect
                ]
            )

            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    tile(ordered[0])
                    tile(ordered[1])
                }

                HStack(spacing: 0) {
                    tile(ordered[2])
                    tile(ordered[3])
                }
            }
        }
    }

    @ViewBuilder
    private func fiveImageTemplate(in size: CGSize) -> some View {
        let canvasAspect =
            size.width / max(1, size.height)

        if resolvedOrigamiLayoutVariant(
            photoCount: 5,
            portraitCount: portraitCount,
            landscapeCount: landscapeCount,
            wideCount: wideCount,
            manualOverride: manualLayoutVariant
        ) == 0 {
            // One tall portrait slot + four balanced slots.
            // This avoids stacking three horizontal images into
            // extremely shallow strips.
            let ordered = bestImageOrder(
                for: [
                    canvasAspect * 0.28,
                    canvasAspect * 0.72,
                    canvasAspect * 0.72,
                    canvasAspect * 0.72,
                    canvasAspect * 0.72
                ]
            )

            HStack(spacing: 0) {
                tile(ordered[0])
                    .frame(width: size.width * 0.28)

                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        tile(ordered[1])
                        tile(ordered[2])
                    }

                    HStack(spacing: 0) {
                        tile(ordered[3])
                        tile(ordered[4])
                    }
                }
                .frame(width: size.width * 0.72)
            }
        } else {
            // Landscape/square page:
            // two larger images above and three below.
            let ordered = bestImageOrder(
                for: [
                    canvasAspect * 0.806,
                    canvasAspect * 0.806,
                    canvasAspect * 0.877,
                    canvasAspect * 0.877,
                    canvasAspect * 0.877
                ]
            )

            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    tile(ordered[0])
                    tile(ordered[1])
                }
                .frame(height: size.height * 0.62)

                HStack(spacing: 0) {
                    tile(ordered[2])
                    tile(ordered[3])
                    tile(ordered[4])
                }
                .frame(height: size.height * 0.38)
            }
        }
    }

    @ViewBuilder
    private func sixImageTemplate(in size: CGSize) -> some View {
        let canvasAspect =
            size.width / max(1, size.height)

        let sixResolvedVariant = resolvedOrigamiLayoutVariant(
            photoCount: 6,
            portraitCount: portraitCount,
            landscapeCount: landscapeCount,
            wideCount: wideCount,
            manualOverride: manualLayoutVariant
        )

        if sixResolvedVariant == 0 {
            let ordered = bestImageOrder(
                for: [
                    canvasAspect * 0.22,
                    canvasAspect * 0.56,
                    canvasAspect * 0.56,
                    canvasAspect * 0.56,
                    canvasAspect * 0.56,
                    canvasAspect * 0.22
                ]
            )

            HStack(spacing: 0) {
                tile(ordered[0])
                    .frame(width: size.width * 0.22)

                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        tile(ordered[1])
                        tile(ordered[2])
                    }

                    HStack(spacing: 0) {
                        tile(ordered[3])
                        tile(ordered[4])
                    }
                }
                .frame(width: size.width * 0.56)

                tile(ordered[5])
                    .frame(width: size.width * 0.22)
            }
        } else if sixResolvedVariant == 1 {
            let ordered = bestImageOrder(
                for: [
                    canvasAspect * 0.26,
                    canvasAspect * 0.74,
                    canvasAspect * 0.74,
                    canvasAspect * 0.493,
                    canvasAspect * 0.493,
                    canvasAspect * 0.493
                ]
            )

            HStack(spacing: 0) {
                tile(ordered[0])
                    .frame(width: size.width * 0.26)

                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        tile(ordered[1])
                        tile(ordered[2])
                    }

                    HStack(spacing: 0) {
                        tile(ordered[3])
                        tile(ordered[4])
                        tile(ordered[5])
                    }
                }
                .frame(width: size.width * 0.74)
            }
        } else {
            let ordered = bestImageOrder(
                for: [
                    canvasAspect * 0.667,
                    canvasAspect * 0.667,
                    canvasAspect * 0.667,
                    canvasAspect * 0.667,
                    canvasAspect * 0.667,
                    canvasAspect * 0.667
                ]
            )

            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    tile(ordered[0])
                    tile(ordered[1])
                    tile(ordered[2])
                }

                HStack(spacing: 0) {
                    tile(ordered[3])
                    tile(ordered[4])
                    tile(ordered[5])
                }
            }
        }
    }

    var body: some View {
        GeometryReader { proxy in
            let availableWidth = max(1, proxy.size.width)
            let availableHeight = max(1, proxy.size.height)

            let pageWidth = min(
                availableWidth,
                availableHeight * 16 / 9
            )

            let pageHeight = pageWidth * 9 / 16
            let pageSize = CGSize(
                width: pageWidth,
                height: pageHeight
            )

            ZStack {
                Color.black

                ZStack {
                    collage(in: pageSize)
                        .frame(
                            width: pageWidth,
                            height: pageHeight
                        )
                        .clipped()

                    if showsPhotoName {
                        VStack {
                            Spacer()

                            HStack {
                                Text(activePhotoName)
                                    .font(
                                        .custom("Figtree", size: 11.5)
                                        .weight(.medium)
                                    )
                                    .foregroundColor(.white.opacity(0.92))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 7)
                                    .background(Color.black.opacity(0.40))
                                    .clipShape(Capsule())

                                Spacer()
                            }
                            .padding(16)
                        }
                        .frame(
                            width: pageWidth,
                            height: pageHeight
                        )
                    }
                }
                .frame(
                    width: pageWidth,
                    height: pageHeight
                )
                .clipped()
            }
            .frame(
                width: proxy.size.width,
                height: proxy.size.height
            )
        }
        .background(Color.black)
        .clipped()
    }
}

struct OrigamiWholePageHalfFoldOverlay: View {
    let images: [NSImage]
    var theme: SlideshowVisualTheme = .origami
    let slotReplacementImages: [Int: NSImage]
    let animationVariant: Int
    let progress: Double
    let cropByImageIdentity: [ObjectIdentifier: MagazinePhotoCrop]
    var manualLayoutVariant: Int? = nil

    private var safeProgress: Double {
        min(
            1,
            max(0, progress)
        )
    }

    private var easedProgress: Double {
        let value = safeProgress

        return value
            * value
            * (3 - 2 * value)
    }

    private var pageOpacity: Double {
        1
    }

    private func pageView(
        width: CGFloat,
        height: CGFloat
    ) -> AnyView {
        AnyView(
            OrigamiPreviewPage(
                images: images,
                theme: theme,
                slotReplacementImages:
                    slotReplacementImages,
                activeSwapImages: [:],
                activeSwapStyles: [:],
                swapProgress: 1,
                activePhotoName: "",
                showsPhotoName: false,
                transitionProgress: 1,
                animationVariant:
                    animationVariant,
                cropByImageIdentity:
                    cropByImageIdentity,
                manualLayoutVariant:
                    manualLayoutVariant
            )
            .frame(
                width: width,
                height: height
            )
            .background(Color.black)
        )
    }

    private var usesVerticalCenterFold: Bool {
        let normalizedVariant =
            animationVariant >= 0
            ? animationVariant
            : -animationVariant

        return normalizedVariant.isMultiple(of: 2) == false
    }

    var body: some View {
        GeometryReader { proxy in
            let availableWidth =
                max(1, proxy.size.width)

            let availableHeight =
                max(1, proxy.size.height)

            let canvasWidth = min(
                availableWidth,
                availableHeight * 16 / 9
            )

            let canvasHeight =
                canvasWidth * 9 / 16

            let halfWidth =
                canvasWidth * 0.5

            let halfHeight =
                canvasHeight * 0.5

            let angle =
                90 * easedProgress

            ZStack {
                if usesVerticalCenterFold {
                    leftHalf(
                        width: canvasWidth,
                        height: canvasHeight,
                        halfWidth: halfWidth,
                        angle: angle
                    )

                    rightHalf(
                        width: canvasWidth,
                        height: canvasHeight,
                        halfWidth: halfWidth,
                        angle: angle
                    )

                    Rectangle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.clear,
                                    Color.black.opacity(
                                        0.50
                                        * sin(
                                            easedProgress
                                            * .pi
                                        )
                                    ),
                                    Color.clear,
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(
                            width: 18,
                            height: canvasHeight
                        )
                        .position(
                            x: canvasWidth * 0.5,
                            y: canvasHeight * 0.5
                        )
                        .allowsHitTesting(false)
                } else {
                    topHalf(
                        width: canvasWidth,
                        height: canvasHeight,
                        halfHeight: halfHeight,
                        angle: angle
                    )

                    bottomHalf(
                        width: canvasWidth,
                        height: canvasHeight,
                        halfHeight: halfHeight,
                        angle: angle
                    )

                    Rectangle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.clear,
                                    Color.black.opacity(
                                        0.50
                                        * sin(
                                            easedProgress
                                            * .pi
                                        )
                                    ),
                                    Color.clear,
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(
                            width: canvasWidth,
                            height: 18
                        )
                        .position(
                            x: canvasWidth * 0.5,
                            y: canvasHeight * 0.5
                        )
                        .allowsHitTesting(false)
                }
            }
            .frame(
                width: canvasWidth,
                height: canvasHeight
            )
            .opacity(pageOpacity)
            .clipped()
            .position(
                x: availableWidth * 0.5,
                y: availableHeight * 0.5
            )
        }
    }

    private func leftHalf(
        width: CGFloat,
        height: CGFloat,
        halfWidth: CGFloat,
        angle: Double
    ) -> AnyView {
        AnyView(
            pageView(
                width: width,
                height: height
            )
            .offset(
                x: width * 0.25
            )
            .frame(
                width: halfWidth,
                height: height
            )
            .clipped()
            .rotation3DEffect(
                .degrees(angle),
                axis: (
                    x: 0,
                    y: 1,
                    z: 0
                ),
                anchor: .trailing,
                anchorZ: 0,
                perspective: 0.72
            )
            .shadow(
                color:
                    Color.black.opacity(
                        0.46
                        * sin(
                            easedProgress
                            * .pi
                        )
                    ),
                radius:
                    18
                    * sin(
                        easedProgress
                        * .pi
                    ),
                x: 8,
                y: 0
            )
            .frame(
                width: halfWidth,
                height: height
            )
            .position(
                x: halfWidth * 0.5,
                y: height * 0.5
            )
        )
    }

    private func rightHalf(
        width: CGFloat,
        height: CGFloat,
        halfWidth: CGFloat,
        angle: Double
    ) -> AnyView {
        AnyView(
            pageView(
                width: width,
                height: height
            )
            .offset(
                x: -width * 0.25
            )
            .frame(
                width: halfWidth,
                height: height
            )
            .clipped()
            .rotation3DEffect(
                .degrees(-angle),
                axis: (
                    x: 0,
                    y: 1,
                    z: 0
                ),
                anchor: .leading,
                anchorZ: 0,
                perspective: 0.72
            )
            .shadow(
                color:
                    Color.black.opacity(
                        0.46
                        * sin(
                            easedProgress
                            * .pi
                        )
                    ),
                radius:
                    18
                    * sin(
                        easedProgress
                        * .pi
                    ),
                x: -8,
                y: 0
            )
            .frame(
                width: halfWidth,
                height: height
            )
            .position(
                x:
                    halfWidth
                    + halfWidth * 0.5,
                y: height * 0.5
            )
        )
    }

    private func topHalf(
        width: CGFloat,
        height: CGFloat,
        halfHeight: CGFloat,
        angle: Double
    ) -> AnyView {
        AnyView(
            pageView(
                width: width,
                height: height
            )
            .offset(
                y: height * 0.25
            )
            .frame(
                width: width,
                height: halfHeight
            )
            .clipped()
            .rotation3DEffect(
                .degrees(-angle),
                axis: (
                    x: 1,
                    y: 0,
                    z: 0
                ),
                anchor: .bottom,
                anchorZ: 0,
                perspective: 0.72
            )
            .shadow(
                color:
                    Color.black.opacity(
                        0.46
                        * sin(
                            easedProgress
                            * .pi
                        )
                    ),
                radius:
                    18
                    * sin(
                        easedProgress
                        * .pi
                    ),
                x: 0,
                y: 8
            )
            .frame(
                width: width,
                height: halfHeight
            )
            .position(
                x: width * 0.5,
                y: halfHeight * 0.5
            )
        )
    }

    private func bottomHalf(
        width: CGFloat,
        height: CGFloat,
        halfHeight: CGFloat,
        angle: Double
    ) -> AnyView {
        AnyView(
            pageView(
                width: width,
                height: height
            )
            .offset(
                y: -height * 0.25
            )
            .frame(
                width: width,
                height: halfHeight
            )
            .clipped()
            .rotation3DEffect(
                .degrees(angle),
                axis: (
                    x: 1,
                    y: 0,
                    z: 0
                ),
                anchor: .top,
                anchorZ: 0,
                perspective: 0.72
            )
            .shadow(
                color:
                    Color.black.opacity(
                        0.46
                        * sin(
                            easedProgress
                            * .pi
                        )
                    ),
                radius:
                    18
                    * sin(
                        easedProgress
                        * .pi
                    ),
                x: 0,
                y: -8
            )
            .frame(
                width: width,
                height: halfHeight
            )
            .position(
                x: width * 0.5,
                y:
                    halfHeight
                    + halfHeight * 0.5
            )
        )
    }
}


struct OrigamiPanelShape: Shape {
    let index: Int

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let inset: CGFloat = 6
        let topShift: CGFloat = index.isMultiple(of: 2) ? 0 : 14
        let bottomShift: CGFloat = index.isMultiple(of: 2) ? 14 : 0

        path.move(to: CGPoint(x: rect.minX + inset, y: rect.minY + inset + topShift))
        path.addLine(to: CGPoint(x: rect.maxX - inset, y: rect.minY + inset))
        path.addLine(to: CGPoint(x: rect.maxX - inset, y: rect.maxY - inset - bottomShift))
        path.addLine(to: CGPoint(x: rect.minX + inset, y: rect.maxY - inset))
        path.closeSubpath()

        return path
    }
}

private struct ImaginationDustOverlay: View {
    let burstToken: Int

    private let particleCount = 90

    @State private var burstStartedAt = Date()

    var body: some View {
        GeometryReader { proxy in
            TimelineView(
                .animation(
                    minimumInterval: 1.0 / 30.0,
                    paused: false
                )
            ) { timeline in
                Canvas { context, size in
                    // Dust motion je 30% brži, ali ostaje
                    // potpuno neprekidan između page-eva.
                    let currentTime =
                        timeline.date
                            .timeIntervalSinceReferenceDate
                            * 1.30

                    let elapsedSinceBurst = max(
                        0,
                        timeline.date.timeIntervalSince(burstStartedAt)
                    )

                    // Jak početni nalet koji se smooth smanjuje.
                    // Nikada ne pada na nulu jer osnovni swirl ostaje.
                    let burstStrength = exp(
                        -elapsedSinceBurst * 0.78
                    )

                    for index in 0..<particleCount {
                        drawDustParticle(
                            index: index,
                            time: currentTime,
                            size: size,
                            burstStrength: burstStrength,
                            context: &context
                        )
                    }
                }
            }
            .frame(
                width: proxy.size.width,
                height: proxy.size.height
            )
            .allowsHitTesting(false)
            .onAppear {
                burstStartedAt = Date()
            }
            .onChange(of: burstToken) { _ in
                // Svaki novi page ponovo aktivira nalet vetra.
                burstStartedAt = Date()
            }
        }
    }

    private func drawDustParticle(
        index: Int,
        time: TimeInterval,
        size: CGSize,
        burstStrength: Double,
        context: inout GraphicsContext
    ) {
        guard size.width > 0, size.height > 0 else {
            return
        }

        let seed = Double(index + 1)

        let xSeed = random(seed * 12.9898)
        let ySeed = random(seed * 78.233)
        let speedSeed = random(seed * 41.719)
        let phaseSeed = random(seed * 27.113)
        let radiusSeed = random(seed * 63.771)
        let opacitySeed = random(seed * 94.331)
        let directionSeed = random(seed * 36.173)

        let baseX = xSeed * size.width
        let baseY = ySeed * size.height

        let phase = phaseSeed * Double.pi * 2.0

        // Stalno mirno lebdenje prašine.
        let baseSpeed =
            0.10 + speedSeed * 0.18

        let secondarySpeed =
            0.07 + random(seed * 17.477) * 0.14

        let horizontalRadius =
            6.0 + radiusSeed * 20.0

        let verticalRadius =
            5.0 + random(seed * 31.557) * 16.0

        let calmX =
            sin(time * baseSpeed + phase)
            * horizontalRadius
            + cos(
                time * secondarySpeed
                + phase * 0.7
            ) * 5.0

        let calmY =
            cos(
                time * baseSpeed * 0.83
                + phase
            ) * verticalRadius
            + sin(
                time * secondarySpeed * 1.17
                + phase * 1.2
            ) * 4.0

        // -------------------------------------------------
        // Nalet vetra na početku svakog novog page-a.
        // -------------------------------------------------

        let sideDirection: Double =
            burstToken.isMultiple(of: 2) ? -1.0 : 1.0

        // Čestice ne idu sve identično.
        let particleDirection =
            directionSeed > 0.35
            ? sideDirection
            : -sideDirection * 0.35

        let gustSpeed =
            1.8 + speedSeed * 2.8

        let gustDistance =
            burstStrength
            * (42.0 + radiusSeed * 76.0)

        let windX =
            sin(
                time * gustSpeed
                + phase
            )
            * gustDistance
            * particleDirection

        let windY =
            cos(
                time * (gustSpeed * 0.72)
                + phase * 1.4
            )
            * gustDistance
            * 0.38

        // Dodatni swirl pri najjačem naletu.
        let swirlRadius =
            burstStrength
            * (15.0 + radiusSeed * 42.0)

        let swirlSpeed =
            2.1 + speedSeed * 3.0

        let swirlX =
            cos(
                time * swirlSpeed
                + phase
            ) * swirlRadius

        let swirlY =
            sin(
                time * swirlSpeed
                + phase
            ) * swirlRadius * 0.72

        var x =
            baseX
            + calmX
            + windX
            + swirlX

        var y =
            baseY
            + calmY
            + windY
            + swirlY

        // Wrap čestica da nikada ne nestanu ili stanu.
        let margin = 30.0

        x = wrapped(
            x,
            minimum: -margin,
            maximum: size.width + margin
        )

        y = wrapped(
            y,
            minimum: -margin,
            maximum: size.height + margin
        )

        // Veličina ostaje mala kao ranije.
        let particleSize =
            0.7 + random(seed * 88.231) * 1.6

        // Tokom naleta su malo vidljivije,
        // ali ne postaju veće.
        let baseOpacity =
            0.12 + opacitySeed * 0.38

        let gustOpacityBoost =
            burstStrength * 0.16

        let finalOpacity = min(
            0.72,
            baseOpacity + gustOpacityBoost
        )

        let particleRect = CGRect(
            x: x - particleSize / 2,
            y: y - particleSize / 2,
            width: particleSize,
            height: particleSize
        )

        context.opacity = finalOpacity

        context.fill(
            Path(ellipseIn: particleRect),
            with: .color(.white)
        )
    }

    private func wrapped(
        _ value: Double,
        minimum: Double,
        maximum: Double
    ) -> Double {
        let range = maximum - minimum

        guard range > 0 else {
            return value
        }

        var result =
            (value - minimum)
            .truncatingRemainder(dividingBy: range)

        if result < 0 {
            result += range
        }

        return result + minimum
    }

    private func random(_ value: Double) -> Double {
        let result =
            sin(value) * 43_758.545_312_3

        return result - floor(result)
    }
}




private struct ImaginationLensLightOverlay: View {
    let sceneToken: Int

    @State private var cycleStartedAt = Date()

    var body: some View {
        GeometryReader { proxy in
            TimelineView(
                .animation(
                    minimumInterval: 1.0 / 30.0,
                    paused: false
                )
            ) { timeline in
                let elapsed = max(
                    0,
                    timeline.date
                        .timeIntervalSince(cycleStartedAt)
                )

                // Glavna Imagination fotografija počinje
                // snažno da usporava oko 1.5 sekundi.
                //
                // Flare tada počinje brzo da nestaje
                // i potpuno izlazi iz scene.
                // Flare movement je 40% sporiji.
                let flareDuration = 6.72

                let rawProgress = min(
                    1,
                    elapsed / flareDuration
                )

                let movementProgress =
                    rawProgress
                    * rawProgress
                    * (
                        3
                        - 2 * rawProgress
                    )

                let fadeIn = min(
                    1,
                    elapsed / 0.22
                )

                // Flare više ne nestaje kada fotografija
                // uspori. Ostaje vidljiv dok njegova
                // putanja fizički ne izađe iz kadra.
                let visibility =
                    fadeIn

                let width = proxy.size.width
                let height = proxy.size.height

                let variant =
                    abs(sceneToken) % 4

                let startX: CGFloat
                let endX: CGFloat
                let flareTargetX: CGFloat
                let flareTargetY: CGFloat

                switch variant {
                case 0:
                    // Gore desno, zatim potpuno van leve ivice.
                    startX = width * 1.08
                    endX = -(width * 0.58)
                    flareTargetX = -(width * 0.34)
                    flareTargetY = height * 0.72

                case 1:
                    // Gore levo, zatim potpuno van desne ivice.
                    startX = -(width * 0.08)
                    endX = width * 1.58
                    flareTargetX = width * 1.34
                    flareTargetY = height * 0.74

                case 2:
                    // Desna strana prolazi kroz kadar
                    // i izlazi duboko van leve ivice.
                    startX = width * 0.96
                    endX = -(width * 0.50)
                    flareTargetX = -(width * 0.30)
                    flareTargetY = height * 0.82

                default:
                    // Leva strana prolazi kroz kadar
                    // i izlazi duboko van desne ivice.
                    startX = width * 0.04
                    endX = width * 1.52
                    flareTargetX = width * 1.30
                    flareTargetY = height * 0.78
                }

                let sourceX =
                    interpolate(
                        from: startX,
                        to: endX,
                        progress:
                            CGFloat(movementProgress)
                    )

                // Svetlo je iznad gornje ivice,
                // kao sunce koje udara u objektiv.
                let sourcePoint = CGPoint(
                    x: sourceX,
                    y: -(height * 0.045)
                )

                let targetPoint = CGPoint(
                    x: flareTargetX,
                    y: flareTargetY
                )

                let pulseA =
                    0.5
                    + 0.5
                    * sin(
                        elapsed * 1.15
                        + Double(variant) * 0.63
                    )

                let pulseB =
                    0.5
                    + 0.5
                    * sin(
                        elapsed * 0.92
                        + 1.35
                        + Double(variant) * 0.31
                    )

                let pulseC =
                    0.5
                    + 0.5
                    * sin(
                        elapsed * 1.06
                        + 2.10
                        + Double(variant) * 0.22
                    )

                return AnyView(
                    ZStack {
                        // -----------------------------------------
                        // GLAVNI VELIKI KRUŽNI FLARE
                        // -----------------------------------------

                        roundFlare(
                            diameter:
                                width
                                * (
                                    0.50
                                    + 0.16 * pulseA
                                ),
                            opacity:
                                0.54 * visibility,
                            blur: 30
                        )
                        .position(
                            pointOnLine(
                                from: sourcePoint,
                                to: targetPoint,
                                progress: 0.26,
                                xOffset:
                                    width * 0.018,
                                yOffset: 0
                            )
                        )

                        // -----------------------------------------
                        // SREDNJI KRUŽNI FLARE
                        // -----------------------------------------

                        roundFlare(
                            diameter:
                                width
                                * (
                                    0.28
                                    + 0.10 * pulseB
                                ),
                            opacity:
                                0.46 * visibility,
                            blur: 19
                        )
                        .position(
                            pointOnLine(
                                from: sourcePoint,
                                to: targetPoint,
                                progress: 0.50,
                                xOffset:
                                    -(width * 0.025),
                                yOffset:
                                    height * 0.012
                            )
                        )

                        // -----------------------------------------
                        // TREĆI MANJI, ALI JASNIJI FLARE
                        // -----------------------------------------

                        roundFlare(
                            diameter:
                                width
                                * (
                                    0.15
                                    + 0.065 * pulseC
                                ),
                            opacity:
                                0.58 * visibility,
                            blur: 11
                        )
                        .position(
                            pointOnLine(
                                from: sourcePoint,
                                to: targetPoint,
                                progress: 0.72,
                                xOffset:
                                    width * 0.018,
                                yOffset:
                                    -(height * 0.008)
                            )
                        )
                    }
                    .blendMode(.screen)
                    .compositingGroup()
                )
            }
            .frame(
                width: proxy.size.width,
                height: proxy.size.height
            )
            .clipped()
            .allowsHitTesting(false)
            .onAppear {
                cycleStartedAt = Date()
            }
            .onChange(of: sceneToken) { _ in
                // Svaki novi Imagination page dobija
                // novi flare prolaz i novi variant.
                cycleStartedAt = Date()
            }
        }
    }

    private func interpolate(
        from start: CGFloat,
        to end: CGFloat,
        progress: CGFloat
    ) -> CGFloat {
        start + (end - start) * progress
    }

    private func pointOnLine(
        from source: CGPoint,
        to target: CGPoint,
        progress: CGFloat,
        xOffset: CGFloat,
        yOffset: CGFloat
    ) -> CGPoint {
        CGPoint(
            x:
                source.x
                + (
                    target.x - source.x
                ) * progress
                + xOffset,
            y:
                source.y
                + (
                    target.y - source.y
                ) * progress
                + yOffset
        )
    }

    private func roundFlare(
        diameter: CGFloat,
        opacity: Double,
        blur: CGFloat
    ) -> some View {
        Circle()
            .fill(
                RadialGradient(
                    stops: [
                        .init(
                            color:
                                Color.white.opacity(
                                    0.10
                                ),
                            location: 0
                        ),
                        .init(
                            color:
                                Color(
                                    red: 1.0,
                                    green: 0.78,
                                    blue: 0.46
                                )
                                .opacity(0.24),
                            location: 0.40
                        ),
                        .init(
                            color:
                                Color(
                                    red: 0.68,
                                    green: 0.82,
                                    blue: 1.0
                                )
                                .opacity(0.11),
                            location: 0.68
                        ),
                        .init(
                            color:
                                Color.white.opacity(
                                    0.07
                                ),
                            location: 0.86
                        ),
                        .init(
                            color: Color.clear,
                            location: 1
                        )
                    ],
                    center: .center,
                    startRadius: 0,
                    endRadius:
                        diameter * 0.50
                )
            )
            .overlay(
                Circle()
                    .stroke(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.15),
                                Color(
                                    red: 1.0,
                                    green: 0.72,
                                    blue: 0.42
                                )
                                .opacity(0.11),
                                Color.white.opacity(0.04)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1.8
                    )
                    .blur(radius: 3)
            )
            .frame(
                width: diameter,
                height: diameter
            )
            .blur(radius: blur)
            .opacity(opacity)
    }
}


struct ImaginationCardPage: View {
    let activeImage: NSImage?
    let secondaryImage: NSImage?
    let activePhotoIndex: Int
    let transitionProgress: Double
    let isPreviewPlaying: Bool
    let playbackRestartToken: Int
    let introOutroOverlayOpacity: Double

    @State private var revealScale: CGFloat = 2.20
    @State private var revealBlur: CGFloat = 30
    @State private var revealSaturation: Double = 0
    @State private var revealBrightness: Double = 0.12
    @State private var revealContrast: Double = 1.12
    @State private var revealOffsetX: CGFloat = 0
    @State private var revealOffsetY: CGFloat = 0
    @State private var revealTiltX: Double = 0
    @State private var revealTiltY: Double = 0
    @State private var revealRotationZ: Double = 0

    // Dodatna manja fotografija za novu two-photo scenu.
    @State private var secondaryScale: CGFloat = 1.34
    @State private var secondaryBlur: CGFloat = 30
    @State private var secondarySaturation: Double = 0
    @State private var secondaryBrightness: Double = 0.12
    @State private var secondaryContrast: Double = 1.12
    @State private var secondaryOffsetX: CGFloat = 0
    @State private var secondaryOffsetY: CGFloat = 0
    @State private var secondaryTiltX: Double = 0
    @State private var secondaryTiltY: Double = 0
    @State private var secondaryRotationZ: Double = 0

    // Blurry kopija dodatne fotografije.
    @State private var secondaryDistantScale: CGFloat = 1.48
    @State private var secondaryDistantOffsetX: CGFloat = 0
    @State private var secondaryDistantOffsetY: CGFloat = 0
    @State private var secondaryDistantTiltY: Double = 0
    @State private var secondaryDistantRotationZ: Double = 0

    // Tamna blurry kopija u dijagonalno suprotnom uglu.
    @State private var distantScale: CGFloat = 1.56156
    @State private var distantOffsetX: CGFloat = 0
    @State private var distantOffsetY: CGFloat = 0
    @State private var distantTiltY: Double = 0
    @State private var distantRotationZ: Double = 0

    @State private var sideIsRight: Bool = false
    @State private var lastSeenIndex: Int = -1
    @State private var hasStartedCurrentPhoto: Bool = false
    @State private var lastPlaybackRestartToken: Int = -1

    private var isAlternatingTwinScene: Bool {
        guard secondaryImage != nil else {
            return false
        }

        // Redosled početnih indeksa:
        // 0 = single
        // 1 = twin, koristi 1 i 2
        // 3 = single
        // 4 = twin, koristi 4 i 5
        // 6 = single
        // 7 = twin, koristi 7 i 8
        return activePhotoIndex % 3 == 1
    }

    private var twinSceneVariant: Int {
        guard isAlternatingTwinScene else {
            return 0
        }

        // Tri postojeća twin izgleda kruže redom.
        return (activePhotoIndex / 3) % 3
    }

    private var usesSecondTwinScene: Bool {
        isAlternatingTwinScene
            && twinSceneVariant == 1
    }

    private var usesThirdTwinLeftScene: Bool {
        isAlternatingTwinScene
            && twinSceneVariant == 2
    }

    private var usesAngledTwinScene: Bool {
        usesSecondTwinScene
            || usesThirdTwinLeftScene
    }

    private var usesTwoPhotoScene: Bool {
        isAlternatingTwinScene
    }

    private var blackOverlayOpacity: Double {
        guard isPreviewPlaying else {
            return 1
        }

        let p = min(1, max(0, transitionProgress))
        return 1 - abs(1 - 2 * p)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black

                if let activeImage {
                    let imageRatio = max(
                        0.01,
                        activeImage.size.width / max(1, activeImage.size.height)
                    )

                    let availableWidth = proxy.size.width * 0.72
                    let availableHeight = proxy.size.height * 0.76

                    let cardSize: CGSize = {
                        let availableRatio =
                            availableWidth / availableHeight

                        if imageRatio > availableRatio {
                            return CGSize(
                                width: availableWidth,
                                height: availableWidth / imageRatio
                            )
                        } else {
                            return CGSize(
                                width: availableHeight * imageRatio,
                                height: availableHeight
                            )
                        }
                    }()

                    let secondaryCardSize: CGSize? = {
                        guard let secondaryImage else {
                            return nil
                        }

                        let secondaryRatio = max(
                            0.01,
                            secondaryImage.size.width
                                / max(
                                    1,
                                    secondaryImage.size.height
                                )
                        )

                        let secondaryAvailableWidth =
                            proxy.size.width * 0.48

                        let secondaryAvailableHeight =
                            proxy.size.height * 0.54

                        let secondaryAvailableRatio =
                            secondaryAvailableWidth
                                / secondaryAvailableHeight

                        if secondaryRatio
                            > secondaryAvailableRatio {

                            return CGSize(
                                width: secondaryAvailableWidth,
                                height:
                                    secondaryAvailableWidth
                                    / secondaryRatio
                            )
                        }

                        return CGSize(
                            width:
                                secondaryAvailableHeight
                                * secondaryRatio,
                            height: secondaryAvailableHeight
                        )
                    }()

                    // ---------------------------------------------
                    // TAMNA BLURRY KOPIJA — SUPROTAN UGAO
                    // ---------------------------------------------

                    ZStack {
                        Image(nsImage: activeImage)
                            .resizable()
                            .scaledToFill()
                            .frame(
                                width: cardSize.width,
                                height: cardSize.height
                            )
                            .clipped()
                            .blur(radius: 16)
                            .saturation(0)
                            .brightness(-0.08)
                            .contrast(0.92)

                        Color.black
                            .opacity(0.20)
                    }
                    .frame(
                        width: cardSize.width,
                        height: cardSize.height
                    )
                    .clipShape(
                        RoundedRectangle(
                            cornerRadius: 22,
                            style: .continuous
                        )
                    )
                    .mask(
                        RoundedRectangle(
                            cornerRadius: 18,
                            style: .continuous
                        )
                        .fill(Color.white.opacity(0.80))
                        .padding(30)
                        .blur(radius: 24)
                    )
                    .compositingGroup()
                    .rotation3DEffect(
                        .degrees(distantTiltY),
                        axis: (x: 0, y: 1, z: 0),
                        perspective: 0.55
                    )
                    .rotationEffect(
                        .degrees(distantRotationZ)
                    )
                    .scaleEffect(distantScale)
                    .offset(
                        x: distantOffsetX,
                        y: distantOffsetY
                    )
                    .opacity(0.62)
                    .zIndex(5)

                    // ---------------------------------------------
                    // NOVA TWO-PHOTO SCENA
                    // ---------------------------------------------

                    if usesTwoPhotoScene,
                       let secondaryImage,
                       let secondaryCardSize {

                        // Blurry kopija druge fotografije nalazi se
                        // dijagonalno nasuprot njenom originalu.
                        ZStack {
                            Image(nsImage: secondaryImage)
                                .resizable()
                                .scaledToFill()
                                .frame(
                                    width:
                                        secondaryCardSize.width
                                        * (
                                            usesSecondTwinScene
                                            ? 1.55
                                            : 1.0
                                        ),
                                    height:
                                        secondaryCardSize.height
                                        * (
                                            usesSecondTwinScene
                                            ? 1.55
                                            : 1.0
                                        )
                                )
                                .clipped()
                                .blur(radius: 16)
                                .saturation(0)
                                .brightness(-0.08)
                                .contrast(0.92)

                            Color.black
                                .opacity(0.20)
                        }
                        .frame(
                            width: secondaryCardSize.width
                                        * (
                                            usesSecondTwinScene
                                            ? 1.55
                                            : 1.0
                                        ),
                            height: secondaryCardSize.height
                                        * (
                                            usesSecondTwinScene
                                            ? 1.55
                                            : 1.0
                                        )
                        )
                        .clipShape(
                            RoundedRectangle(
                                cornerRadius: 22,
                                style: .continuous
                            )
                        )
                        .mask(
                            RoundedRectangle(
                                cornerRadius: 18,
                                style: .continuous
                            )
                            .fill(
                                Color.white.opacity(0.80)
                            )
                            .padding(30)
                            .blur(radius: 24)
                        )
                        .compositingGroup()
                        .rotation3DEffect(
                            .degrees(
                                secondaryDistantTiltY
                            ),
                            axis: (x: 0, y: 1, z: 0),
                            perspective: 0.55
                        )
                        .rotationEffect(
                            .degrees(
                                secondaryDistantRotationZ
                            )
                        )
                        .scaleEffect(
                            secondaryDistantScale
                        )
                        .offset(
                            x:
                                secondaryDistantOffsetX,
                            y:
                                secondaryDistantOffsetY
                        )
                        .opacity(0.62)
                        .zIndex(6)

                        // Manji, drugačije rotiran original.
                        ZStack {
                            Image(nsImage: secondaryImage)
                                .resizable()
                                .scaledToFill()
                                .frame(
                                    width:
                                        secondaryCardSize.width
                                        * (
                                            usesSecondTwinScene
                                            ? 1.55
                                            : 1.0
                                        ),
                                    height:
                                        secondaryCardSize.height
                                        * (
                                            usesSecondTwinScene
                                            ? 1.55
                                            : 1.0
                                        )
                                )
                                .clipped()
                                .saturation(
                                    secondarySaturation
                                )
                                .brightness(
                                    secondaryBrightness
                                )
                                .contrast(
                                    secondaryContrast
                                )
                                .blur(
                                    radius: secondaryBlur
                                )
                        }
                        .frame(
                            width:
                                secondaryCardSize.width
                                * (
                                    usesSecondTwinScene
                                    ? 1.55
                                    : 1.0
                                ),
                            height:
                                secondaryCardSize.height
                                * (
                                    usesSecondTwinScene
                                    ? 1.55
                                    : 1.0
                                )
                        )
                        .clipShape(
                            RoundedRectangle(
                                cornerRadius: 22,
                                style: .continuous
                            )
                        )
                        .compositingGroup()
                        .rotation3DEffect(
                            .degrees(secondaryTiltY),
                            axis: (x: 0, y: 1, z: 0),
                            perspective: 0.55
                        )
                        .rotation3DEffect(
                            .degrees(secondaryTiltX),
                            axis: (x: 1, y: 0, z: 0),
                            perspective: 0.55
                        )
                        .rotationEffect(
                            .degrees(secondaryRotationZ)
                        )
                        .scaleEffect(
                            secondaryScale
                            * (
                                secondaryCardSize.height
                                    > secondaryCardSize.width
                                ? 1.50
                                : 1.0
                            )
                        )
                        .offset(
                            x: secondaryOffsetX,
                            y: secondaryOffsetY
                        )
                        .zIndex(12)
                    }

                    // ---------------------------------------------
                    // POSTOJEĆA GLAVNA FOTOGRAFIJA
                    // ---------------------------------------------

                    ZStack {
                        Image(nsImage: activeImage)
                            .resizable()
                            .scaledToFill()
                            .frame(
                                width:
                                    cardSize.width
                                    * (
                                        usesSecondTwinScene
                                        ? 0.70
                                        : 1.0
                                    ),
                                height:
                                    cardSize.height
                                    * (
                                        usesSecondTwinScene
                                        ? 0.70
                                        : 1.0
                                    )
                            )
                            .clipped()
                            .saturation(revealSaturation)
                            .brightness(revealBrightness)
                            .contrast(revealContrast)
                            .blur(radius: revealBlur)
                    }
                    .frame(
                        width:
                            cardSize.width
                            * (
                                usesSecondTwinScene
                                ? 0.70
                                : 1.0
                            ),
                        height:
                            cardSize.height
                            * (
                                usesSecondTwinScene
                                ? 0.70
                                : 1.0
                            )
                    )
                    .clipShape(
                        RoundedRectangle(
                            cornerRadius: 22,
                            style: .continuous
                        )
                    )
                    .compositingGroup()
                    .rotation3DEffect(
                        .degrees(revealTiltY),
                        axis: (x: 0, y: 1, z: 0),
                        perspective: 0.55
                    )
                    .rotation3DEffect(
                        .degrees(revealTiltX),
                        axis: (x: 1, y: 0, z: 0),
                        perspective: 0.55
                    )
                    .rotationEffect(
                        .degrees(revealRotationZ)
                    )
                    .scaleEffect(
                        revealScale
                        * (
                            cardSize.height
                                > cardSize.width
                            ? (
                                usesTwoPhotoScene
                                ? 1.50
                                : 1.10
                            )
                            : 1.0
                        )
                    )
                    .offset(
                        x: revealOffsetX,
                        y: revealOffsetY
                    )
                    .zIndex(10)
                }

                ImaginationLensLightOverlay(
                    sceneToken: activePhotoIndex
                )
                .frame(
                    width: proxy.size.width,
                    height: proxy.size.height
                )
                .allowsHitTesting(false)
                .zIndex(18)

                ImaginationDustOverlay(
                    burstToken: activePhotoIndex
                )
                .opacity(0.95)
                .frame(
                    width: proxy.size.width,
                    height: proxy.size.height
                )
                .zIndex(20)

                ImaginationDustOverlay(
                    burstToken: activePhotoIndex
                )
                .scaleEffect(1.08)
                .offset(y: 24)
                .opacity(0.65)
                .frame(
                    width: proxy.size.width,
                    height: proxy.size.height
                )
                .zIndex(21)

                Color.black
                    .opacity(blackOverlayOpacity)
                    .allowsHitTesting(false)
                    .zIndex(100)

                Color.black
                    .opacity(introOutroOverlayOpacity)
                    .allowsHitTesting(false)
                    .zIndex(200)
            }
            .frame(
                width: proxy.size.width,
                height: proxy.size.height
            )
            .clipped()
            .onAppear {
                lastSeenIndex = activePhotoIndex
                lastPlaybackRestartToken =
                    playbackRestartToken

                guard isPreviewPlaying else {
                    return
                }

                hasStartedCurrentPhoto = true

                triggerReveal(
                    sceneSize: proxy.size
                )
            }
            .onChange(of: activePhotoIndex) { newValue in
                guard newValue != lastSeenIndex else {
                    return
                }

                lastSeenIndex = newValue
                hasStartedCurrentPhoto = false

                guard isPreviewPlaying else {
                    return
                }

                hasStartedCurrentPhoto = true

                triggerReveal(
                    sceneSize: proxy.size
                )
            }
            .onChange(of: isPreviewPlaying) { playing in
                guard playing,
                      !hasStartedCurrentPhoto
                else {
                    return
                }

                hasStartedCurrentPhoto = true

                triggerReveal(
                    sceneSize: proxy.size
                )
            }
            .onChange(
                of: playbackRestartToken
            ) { newToken in
                guard newToken
                        != lastPlaybackRestartToken
                else {
                    return
                }

                lastPlaybackRestartToken = newToken

                guard isPreviewPlaying else {
                    hasStartedCurrentPhoto = false
                    return
                }

                hasStartedCurrentPhoto = true

                triggerReveal(
                    sceneSize: proxy.size
                )
            }
        }
    }

    private func triggerReveal(
        sceneSize: CGSize
    ) {
        let startsOnRight =
            activePhotoIndex.isMultiple(of: 2)

        let sideOffset: CGFloat =
            startsOnRight ? 190 : -190

        // Pseudo-random redosled svih sedam postojećih
        // Imagination motion stilova.
        //
        // Množenje sa 3 prolazi kroz svih 7 slotova
        // bez ponavljanja pre nego što ciklus krene ponovo.
        // playbackRestartToken menja početak redosleda
        // posle svakog Play From Beginning.
        let motionSlot =
            (
                activePhotoIndex * 3
                + playbackRestartToken
            ) % 7

        let movementStyle =
            motionSlot % 3

        // Sve postojeće animacije ostaju sačuvane.
        let usesThrownCornerMotion =
            motionSlot == 5

        let usesDiagonalThrownMotion =
            motionSlot == 6

        let usesTopCornerMotion =
            motionSlot == 4

        let usesCrossTiltMotion =
            motionSlot == 3

        let startingOffsetX: CGFloat =
            usesTwoPhotoScene
            ? (
                // Obe twin scene dolaze sa svojih
                // suprotnih spoljnih strana.
                startsOnRight
                ? sceneSize.width
                    * (
                        usesSecondTwinScene
                        ? 0.66
                        : 0.54
                    )
                : -(sceneSize.width
                    * (
                        usesSecondTwinScene
                        ? 0.66
                        : 0.54
                    ))
            )
            : (
                usesThrownCornerMotion
                ? (
                    startsOnRight
                    ? sceneSize.width * 0.52
                    : -(sceneSize.width * 0.52)
                )
                : (
                    usesDiagonalThrownMotion
                    ? (
                        startsOnRight
                        ? -(sceneSize.width * 0.34)
                        : sceneSize.width * 0.34
                    )
                    : (
                        usesTopCornerMotion
                        ? (
                            startsOnRight
                            ? sceneSize.width * 0.38
                            : -(sceneSize.width * 0.38)
                        )
                        : sideOffset
                    )
                )
            )

        let endingOffsetX: CGFloat =
            usesTwoPhotoScene
            ? (
                startsOnRight
                ? sceneSize.width
                    * (
                        usesSecondTwinScene
                        ? 0.25
                        : 0.19
                    )
                : -(sceneSize.width
                    * (
                        usesSecondTwinScene
                        ? 0.25
                        : 0.19
                    ))
            )
            : sideOffset

        let startingOffsetY: CGFloat
        let endingOffsetY: CGFloat

        if usesSecondTwinScene {
            // Drugi twin stil:
            // glavna desna fotografija ostaje malo niže
            // kako se kartice ne bi sudarale.
            startingOffsetY =
                sceneSize.height * 0.07

            endingOffsetY =
                sceneSize.height * 0.035
        } else if usesThrownCornerMotion {
            // Snažno bacanje iz gornjeg spoljnog ugla.
            startingOffsetY =
                -(sceneSize.height * 0.36)

            endingOffsetY = 18
        } else if usesDiagonalThrownMotion {
            // Dijagonalno presecanje scene iz suprotnog ugla.
            startingOffsetY =
                -(sceneSize.height * 0.28)

            endingOffsetY = -26
        } else if usesTopCornerMotion {
            // Fotografija počinje iznad scene i dijagonalno
            // se spušta ka svom bočnom položaju.
            startingOffsetY =
                -(sceneSize.height * 0.46)

            endingOffsetY = 28
        } else if usesCrossTiltMotion {
            // Početak je malo niže, a zatim se gornji
            // deo fotografije povlači dublje u scenu.
            startingOffsetY = 72
            endingOffsetY = -34
        } else {
            switch movementStyle {
            case 1:
                // Glavna fotografija počinje gore.
                startingOffsetY = -115
                endingOffsetY = 45

            case 2:
                // Glavna fotografija počinje dole.
                startingOffsetY = 115
                endingOffsetY = -45

            default:
                startingOffsetY = 0
                endingOffsetY = 0
            }
        }

        let startingTiltX: Double =
            usesSecondTwinScene
            ? -5.0
            : (
                usesThrownCornerMotion
                ? -10.0
            : (
                usesDiagonalThrownMotion
                ? -6.5
                : (
                    usesTopCornerMotion
                    ? -8.0
                    : (
                        usesCrossTiltMotion
                        ? -1.5
                        : 0
                    )
                )
            )

        )

        let endingTiltX: Double =
            usesSecondTwinScene
            ? 0.5
            : (
                usesThrownCornerMotion
                ? 2.5
            : (
                usesDiagonalThrownMotion
                ? 4.0
                : (
                    usesTopCornerMotion
                    ? 1.5
                    : (
                        usesCrossTiltMotion
                        ? 6.5
                        : 0
                    )
                )
            )

        )

        let startingTiltY: Double =
            usesSecondTwinScene
            ? -9.0
            : (
                usesThrownCornerMotion
                ? (
                startsOnRight
                ? -18.0
                : 18.0
            )
            : (
                usesDiagonalThrownMotion
                ? (
                    startsOnRight
                    ? 15.0
                    : -15.0
                )
                : (
                    usesTopCornerMotion
                    ? (
                        startsOnRight
                        ? -13.0
                        : 13.0
                    )
                    : (
                        usesCrossTiltMotion
                        ? -12.0
                        : (
                            startsOnRight
                            ? -9.0
                            : 9.0
                        )
                    )
                )
            )

        )

        let endingTiltY: Double =
            usesSecondTwinScene
            ? -1.2
            : (
                usesThrownCornerMotion
                ? (
                startsOnRight
                ? -2.5
                : 2.5
            )
            : (
                usesDiagonalThrownMotion
                ? (
                    startsOnRight
                    ? -5.0
                    : 5.0
                )
                : (
                    usesTopCornerMotion
                    ? (
                        startsOnRight
                        ? -3.0
                        : 3.0
                    )
                    : (
                        usesCrossTiltMotion
                        ? 7.0
                        : (
                            startsOnRight
                            ? -4.0
                            : 4.0
                        )
                    )
                )
            )

        )

        let startingRotationZ: Double =
            usesSecondTwinScene
            ? 8.0
            : (
                usesThrownCornerMotion
                ? (
                startsOnRight
                ? 9.0
                : -9.0
            )
            : (
                usesDiagonalThrownMotion
                ? (
                    startsOnRight
                    ? -8.0
                    : 8.0
                )
                : (
                    usesTopCornerMotion
                    ? (
                        startsOnRight
                        ? 6.0
                        : -6.0
                    )
                    : (
                        usesCrossTiltMotion
                        ? 3.2
                        : (
                            startsOnRight
                            ? 2.4
                            : -2.4
                        )
                    )
                )
            )

        )

        let endingRotationZ: Double =
            usesSecondTwinScene
            ? 0.8
            : (
                usesThrownCornerMotion
                ? (
                startsOnRight
                ? 0.6
                : -0.6
            )
            : (
                usesDiagonalThrownMotion
                ? (
                    startsOnRight
                    ? 1.4
                    : -1.4
                )
                : (
                    usesTopCornerMotion
                    ? (
                        startsOnRight
                        ? 1.0
                        : -1.0
                    )
                    : (
                        usesCrossTiltMotion
                        ? -1.8
                        : (
                            startsOnRight
                            ? 1.0
                            : -1.0
                        )
                    )
                )
            )

        )

        // Blurry fotografija dobija stvarno suprotan X znak.
        let distantStartingX: CGFloat =
            startsOnRight
            ? -(sceneSize.width * 0.425)
            : sceneSize.width * 0.425

        // Blurry fotografija dobija stvarno suprotan Y znak.
        let distantStartingY: CGFloat

        if startingOffsetY > 0 {
            // Glavna je dole -> blurry mora gore.
            distantStartingY =
                -(sceneSize.height * 0.34)
        } else if startingOffsetY < 0 {
            // Glavna je gore -> blurry mora dole.
            distantStartingY =
                sceneSize.height * 0.34
        } else {
            // Kada je glavna vertikalno u sredini,
            // ugao se menja po page-u.
            distantStartingY =
                activePhotoIndex.isMultiple(of: 4)
                ? -(sceneSize.height * 0.34)
                : sceneSize.height * 0.34
        }

        let distantStartingTiltY: Double =
            startsOnRight ? 5.0 : -5.0

        let distantEndingTiltY: Double =
            startsOnRight ? 3.0 : -3.0

        let distantStartingRotationZ: Double =
            startsOnRight ? -7.0 : 7.0

        let distantEndingRotationZ: Double =
            startsOnRight ? -5.0 : 5.0

        // Kreće još malo prema spolja, nikada prema glavnoj slici.
        let distantEndingX: CGFloat =
            distantStartingX
            + (distantStartingX > 0 ? 22 : -22)

        let distantEndingY: CGFloat =
            distantStartingY
            + (distantStartingY > 0 ? 16 : -16)

        // Two-photo motion postoji potpuno odvojeno
        // od sedam postojećih motion stilova.
        let secondaryStartsOnRight =
            !startsOnRight

        let secondaryStartingX: CGFloat =
            usesSecondTwinScene
            ? (
                secondaryStartsOnRight
                ? sceneSize.width * 0.62
                : -(sceneSize.width * 0.62)
            )
            : (
                secondaryStartsOnRight
                ? sceneSize.width * 0.54
                : -(sceneSize.width * 0.54)
            )

        let secondaryEndingX: CGFloat =
            usesSecondTwinScene
            ? (
                secondaryStartsOnRight
                ? sceneSize.width * 0.25
                : -(sceneSize.width * 0.25)
            )
            : (
                secondaryStartsOnRight
                ? sceneSize.width * 0.255
                : -(sceneSize.width * 0.255)
            )

        let secondaryStartingY: CGFloat =
            usesSecondTwinScene
            ? -(sceneSize.height * 0.16)
            : (
                startsOnRight
                ? sceneSize.height * 0.20
                : -(sceneSize.height * 0.18)
            )

        let secondaryEndingY: CGFloat =
            usesSecondTwinScene
            ? -(sceneSize.height * 0.055)
            : (
                startsOnRight
                ? sceneSize.height * 0.13
                : -(sceneSize.height * 0.12)
            )

        let secondaryStartingTiltX: Double =
            usesSecondTwinScene
            ? 19.0
            : (
                startsOnRight ? 7.0 : -7.0
            )

        let secondaryEndingTiltX: Double =
            usesSecondTwinScene
            ? 5.0
            : (
                startsOnRight ? 2.5 : -2.5
            )

        let secondaryStartingTiltY: Double =
            usesSecondTwinScene
            ? 36.0
            : (
                secondaryStartsOnRight
                ? -15.0
                : 15.0
            )

        let secondaryEndingTiltY: Double =
            usesSecondTwinScene
            ? 12.0
            : (
                secondaryStartsOnRight
                ? -4.5
                : 4.5
            )

        let secondaryStartingRotationZ: Double =
            usesSecondTwinScene
            ? -40.0
            : (
                secondaryStartsOnRight
                ? 10.0
                : -10.0
            )

        let secondaryEndingRotationZ: Double =
            usesSecondTwinScene
            ? -4.0
            : (
                secondaryStartsOnRight
                ? 4.8
                : -4.8
            )

        // Njena blurry kopija je sa suprotnim X i Y znakom.
        let secondaryDistantStartingX: CGFloat =
            secondaryStartsOnRight
            ? -(sceneSize.width * 0.43)
            : sceneSize.width * 0.43

        let secondaryDistantStartingY: CGFloat =
            secondaryStartingY > 0
            ? -(sceneSize.height * 0.31)
            : sceneSize.height * 0.31

        let secondaryDistantEndingX: CGFloat =
            secondaryDistantStartingX
            + (
                secondaryDistantStartingX > 0
                ? 20
                : -20
            )

        let secondaryDistantEndingY: CGFloat =
            secondaryDistantStartingY
            + (
                secondaryDistantStartingY > 0
                ? 15
                : -15
            )

        var resetTransaction = Transaction()
        resetTransaction.animation = nil

        withTransaction(resetTransaction) {
            sideIsRight = startsOnRight

            revealScale =
                usesSecondTwinScene
                ? 1.45
                : (
                    usesTwoPhotoScene
                    ? 1.08
                    : 1.50
                )

            revealBlur = 30
            revealSaturation = 0
            revealBrightness = 0.12
            revealContrast = 1.12
            revealOffsetX = startingOffsetX
            revealOffsetY = startingOffsetY
            revealTiltX = startingTiltX
            revealTiltY = startingTiltY
            revealRotationZ = startingRotationZ

            secondaryScale =
                usesSecondTwinScene
                ? 0.62
                : 1.02

            secondaryBlur = 30
            secondarySaturation = 0
            secondaryBrightness = 0.12
            secondaryContrast = 1.12
            secondaryOffsetX = secondaryStartingX
            secondaryOffsetY = secondaryStartingY
            secondaryTiltX = secondaryStartingTiltX
            secondaryTiltY = secondaryStartingTiltY
            secondaryRotationZ =
                secondaryStartingRotationZ

            secondaryDistantScale = 1.20
            secondaryDistantOffsetX =
                secondaryDistantStartingX
            secondaryDistantOffsetY =
                secondaryDistantStartingY
            secondaryDistantTiltY =
                secondaryStartsOnRight ? 5.0 : -5.0
            secondaryDistantRotationZ =
                secondaryStartsOnRight ? -7.0 : 7.0

            distantScale = 1.56156
            distantOffsetX = distantStartingX
            distantOffsetY = distantStartingY
            distantTiltY = distantStartingTiltY
            distantRotationZ = distantStartingRotationZ
        }

        // Blur završava prvi, malo sporije kako bi
        // početni cinematic reveal trajao nešto duže.
        withAnimation(.easeOut(duration: 1.35)) {
            revealBlur = 0

            if usesTwoPhotoScene {
                secondaryBlur = 0
            }
        }

        // Fotografija ostaje black and white tokom
        // kompletnog blur fade-outa od 1.35 sekundi.
        //
        // Nakon toga automatski prelazi ka potpuno
        // originalnoj fotografiji tokom 1.5 sekundi.
        let colorRevealAnimation =
            Animation
                .easeInOut(duration: 1.5)
                .delay(1.35)

        withAnimation(colorRevealAnimation) {
            revealSaturation = 1
            revealBrightness = 0
            revealContrast = 1

            if usesTwoPhotoScene {
                secondarySaturation = 1
                secondaryBrightness = 0
                secondaryContrast = 1
            }
        }

        // Jedna neprekinuta animacija glavne fotografije.
        //
        // Kreće snažno i brzo kao da je fotografija bačena,
        // zatim posle približno 1.5 sekundi naglo usporava,
        // ali bez prekida nastavlja veoma sporo udaljavanje.
        let driftingAnimation = Animation.timingCurve(
            0.04,
            0.96,
            0.13,
            0.995,
            duration: 17.0
        )

        withAnimation(driftingAnimation) {
            revealScale =
                usesSecondTwinScene
                ? 1.05
                : (
                    usesTwoPhotoScene
                    ? 0.70
                    : 0.96
                )

            revealOffsetX = endingOffsetX
            revealOffsetY = endingOffsetY
            revealTiltX = endingTiltX
            revealTiltY = endingTiltY
            revealRotationZ = endingRotationZ

            if usesTwoPhotoScene {
                secondaryScale =
                    usesSecondTwinScene
                    ? 0.42
                    : 0.68
                secondaryOffsetX = secondaryEndingX
                secondaryOffsetY = secondaryEndingY
                secondaryTiltX = secondaryEndingTiltX
                secondaryTiltY = secondaryEndingTiltY
                secondaryRotationZ =
                    secondaryEndingRotationZ
            }
        }

        let distantAnimation = Animation.timingCurve(
            0.22,
            0.62,
            0.32,
            1.0,
            duration: 24.2
        )

        withAnimation(distantAnimation) {
            distantScale = 1.20666
            distantOffsetX = distantEndingX
            distantOffsetY = distantEndingY
            distantTiltY = distantEndingTiltY
            distantRotationZ = distantEndingRotationZ

            if usesTwoPhotoScene {
                secondaryDistantScale = 0.92
                secondaryDistantOffsetX =
                    secondaryDistantEndingX
                secondaryDistantOffsetY =
                    secondaryDistantEndingY
                secondaryDistantTiltY =
                    secondaryStartsOnRight ? 3.0 : -3.0
                secondaryDistantRotationZ =
                    secondaryStartsOnRight ? -5.0 : 5.0
            }
        }
    }
}

// Three-way toggle shown in the top-right corner of the Preview card:
// live playback at 30fps, live playback at 60fps (default), or a
// pre-rendered 1080p video that plays back via AVKit instead of real-time
// SwiftUI compositing. Hover any button to see what it does.
// A thin NSViewRepresentable over AppKit's own AVPlayerView, used instead of
// SwiftUI's VideoPlayer. VideoPlayer's generic SwiftUI/AVKit bridging metadata
// reliably crashed at first construction in this Xcode/macOS combination
// (a Swift runtime fatal error deep in framework code, in both Debug and
// Release builds, with zero app frames involved) — AVPlayerView sidesteps
// that code path entirely while still giving the same floating transport
// controls (play/pause/scrub).
struct AVPlayerViewRepresentable: NSViewRepresentable {
    let player: AVPlayer?

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.player = player
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player {
            nsView.player = player
        }
    }
}

struct PreviewRenderModeButtons: View {
    let mode: PreviewRenderMode
    let onSelect: (PreviewRenderMode) -> Void

    @State private var isFPS30Hovered = false
    @State private var isFPS60Hovered = false
    @State private var isVideoHovered = false
    @State private var isVideo4KHovered = false
    private let fps30TooltipID = UUID()
    private let fps60TooltipID = UUID()
    private let videoTooltipID = UUID()
    private let video4KTooltipID = UUID()

    var body: some View {
        HStack(spacing: 6) {
            pill(
                .liveFPS30,
                label: "30",
                help: "Live preview at 30fps. Lighter on older or weaker\nMacs, at the cost of slightly less fluid motion.",
                isHovered: $isFPS30Hovered,
                tooltipID: fps30TooltipID
            )

            pill(
                .liveFPS60,
                label: "60",
                help: "Live preview at 60fps (default). The smoothest\nmotion, but can stutter on weaker hardware.",
                isHovered: $isFPS60Hovered,
                tooltipID: fps60TooltipID
            )

            pill(
                .renderedVideo,
                systemImage: "film",
                help: "Prepares the slideshow as a real 1080p video once,\nthen plays that back. Never stutters, even on weak\nhardware — takes a moment to prepare before it\nstarts playing.",
                isHovered: $isVideoHovered,
                tooltipID: videoTooltipID
            )

            pill(
                .renderedVideo4K,
                label: "4K",
                help: "Prepares the slideshow as a real 4K video once,\nthen plays that back. Sharper detail than the\n1080p preview, but takes longer to prepare and\nuses more disk space.",
                isHovered: $isVideo4KHovered,
                tooltipID: video4KTooltipID
            )
        }
    }

    @ViewBuilder
    private func pill(_ target: PreviewRenderMode, label: String, help: String, isHovered: Binding<Bool>, tooltipID: UUID) -> some View {
        pillButton(target: target, help: help, isHovered: isHovered, tooltipID: tooltipID) {
            Text(label)
                .font(.custom("Figtree", size: 11).weight(.bold))
        }
    }

    @ViewBuilder
    private func pill(_ target: PreviewRenderMode, systemImage: String, help: String, isHovered: Binding<Bool>, tooltipID: UUID) -> some View {
        pillButton(target: target, help: help, isHovered: isHovered, tooltipID: tooltipID) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .bold))
        }
    }

    @ViewBuilder
    private func pillButton<Label: View>(
        target: PreviewRenderMode,
        help: String,
        isHovered: Binding<Bool>,
        tooltipID: UUID,
        @ViewBuilder label: () -> Label
    ) -> some View {
        let isActive = mode == target

        Button {
            onSelect(target)
        } label: {
            label()
                .frame(width: 26, height: 20)
        }
        .buttonStyle(.plain)
        .foregroundColor(isActive ? AppColors.panel : AppColors.inkSecondary)
        .background(isActive ? AppColors.ink : AppColors.panel)
        .clipShape(RoundedRectangle(cornerRadius: 999))
        .overlay(
            RoundedRectangle(cornerRadius: 999)
                .stroke(AppColors.ink.opacity(isActive ? 0 : 0.35), lineWidth: 1.2)
        )
        .onHover { hovering in
            isHovered.wrappedValue = hovering
        }
        .anchorPreference(key: PreviewTooltipPreferenceKey.self, value: .bounds) { anchor in
            isHovered.wrappedValue ? [PreviewTooltipAnchor(id: tooltipID, label: help, anchor: anchor, placement: .below)] : []
        }
    }
}

struct CenterPreviewPanel: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    let activePreviewImage: NSImage?
    let previousPreviewImage: NSImage?
    let activePhotoName: String
    let activePhotoIndex: Int
    let photoCount: Int
    let previewImages: [NSImage]
    let origamiSlotReplacementImages: [Int: NSImage]
    let origamiActiveSwapImages: [Int: NSImage]
    let origamiActiveSwapStyles: [Int: Int]
    let origamiSwapProgress: Double
    let previousOrigamiPageImages: [NSImage]
    let previousOrigamiPageReplacements: [Int: NSImage]
    let previousOrigamiPageAnimationVariant: Int
    let origamiWholePageFoldProgress: Double
    let origamiBlackOverlayOpacity: Double
    let magazineBlackOverlayOpacity: Double
    let visualTheme: SlideshowVisualTheme
    let isPreparingPhotos: Bool
    let preparedPhotoCount: Int
    let selectedMusicURL: URL?
    let selectedMusicURLs: [URL]
    let selectedMusicCount: Int
    let timeCounterText: String
    let transitionStyle: SlideshowTransitionStyle
    let transitionProgress: Double
    let magazineImageFadeSeconds: Double
    let magazineImageDelaySeconds: Double
    let magazineLayoutSeed: Int
    let photoCropByImageIdentity: [ObjectIdentifier: MagazinePhotoCrop]
    let magazinePageSlotCount: Int
    let origamiAnimationSeed: Int
    var manualMagazineLayoutOverrides: [Int: Int] = [:]
    var manualOrigamiLayoutOverrides: [Int: Int] = [:]
    let isPreviewPlaying: Bool
    let imaginationPlaybackRestartToken: Int
    let imaginationIntroOutroOpacity: Double
    let onAddPhotos: () -> Void
    let onAddMusic: (Int) -> Void
    let onDropPhotos: ([URL]) -> Void
    let onDropMusic: ([URL]) -> Void
    let onTogglePreview: () -> Void
    let onStartFromBeginning: () -> Void
    let onOpenFullScreen: () -> Void
    let previewRenderMode: PreviewRenderMode
    let previewVideoPlayer: AVPlayer?
    let isPreparingPreviewVideo: Bool
    let previewVideoPrepareProgress: Double
    let previewVideoPrepareError: String?
    let onSelectPreviewRenderMode: (PreviewRenderMode) -> Void

    @State private var isPhotosCardHovered = false

    private var usesMagazinePreview: Bool {
        visualTheme == .magazine || visualTheme == .magazine43 || visualTheme == .magazineFamily || visualTheme == .magazineCouples
    }

    private var themedPreviewImages: [NSImage] {
        guard !previewImages.isEmpty else {
            return activePreviewImage.map { [$0] } ?? []
        }

        let safeIndex = previewImages.indices.contains(activePhotoIndex) ? activePhotoIndex : 0
        let slotCount = max(1, min(6, magazinePageSlotCount))
        return Array(previewImages[safeIndex...].prefix(slotCount))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    PanelTitle(title: "Preview", subtitle: "Your slideshow will appear here")
                    Spacer()
                    PreviewRenderModeButtons(mode: previewRenderMode, onSelect: onSelectPreviewRenderMode)
                }
                ZStack {
                    RoundedRectangle(cornerRadius: 34)
                        .fill(activePreviewImage == nil && !isPreparingPhotos ? AppColors.panel : Color.black)

                    // Always mounted (never conditionally inserted/removed) so its
                    // NSViewRepresentable identity stays stable across mode
                    // switches — swapping it in/out of the tree via if/else during
                    // an animated transition is what triggered a SwiftUI/AVKit
                    // metadata crash the first time the video became ready.
                    AVPlayerViewRepresentable(player: previewVideoPlayer)
                        .clipShape(RoundedRectangle(cornerRadius: 34))
                        .opacity(previewRenderMode.isRenderedVideo && previewVideoPlayer != nil ? 1 : 0)
                        .allowsHitTesting(previewRenderMode.isRenderedVideo && previewVideoPlayer != nil)

                    if previewRenderMode.isRenderedVideo {
                        if previewVideoPlayer != nil {
                            EmptyView()
                        } else if isPreparingPreviewVideo {
                            VStack(spacing: 12) {
                                ProgressView(value: previewVideoPrepareProgress)
                                    .frame(width: 180)

                                Text("Preparing \(previewRenderMode.videoResolutionName) preview video… \(Int(previewVideoPrepareProgress * 100))%")
                                    .font(.custom("Figtree", size: 12).weight(.medium))
                                    .foregroundColor(.white.opacity(0.75))
                            }
                        } else if let previewVideoPrepareError {
                            VStack(spacing: 8) {
                                Image(systemName: "exclamationmark.triangle")
                                    .font(.system(size: 28, weight: .light))
                                    .foregroundColor(.white.opacity(0.6))

                                Text("Couldn't prepare preview video: \(previewVideoPrepareError)")
                                    .font(.custom("Figtree", size: 12).weight(.medium))
                                    .foregroundColor(.white.opacity(0.75))
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal, 24)
                            }
                        } else {
                            VStack(spacing: 16) {
                                Image(systemName: "film")
                                    .font(.system(size: 42, weight: .light))
                                    .foregroundColor(AppColors.muted.opacity(0.55))

                                Text("Video preview mode")
                                    .font(.custom("Figtree", size: 13).weight(.semibold))
                                    .foregroundColor(AppColors.ink)

                                Text("Add photos to prepare a \(previewRenderMode.videoResolutionName) preview video.")
                                    .font(.custom("Figtree", size: 14).weight(.medium))
                                    .foregroundColor(AppColors.muted)
                            }
                        }
                    } else if let activePreviewImage {
                        if usesMagazinePreview {
                            ZStack {
                                MagazinePreviewPage(
                                    images: themedPreviewImages,
                                    theme: visualTheme,
                                    activePhotoName: activePhotoName,
                                    activePhotoIndex: activePhotoIndex,
                                    transitionProgress: transitionProgress,
                                    imageFadeSeconds: magazineImageFadeSeconds,
                                    imageDelaySeconds: magazineImageDelaySeconds,
                                    revealStyle: transitionStyle,
                                    layoutSeed: magazineLayoutSeed,
                                    cropByImageIdentity: photoCropByImageIdentity,
                                    manualLayoutVariant: manualMagazineLayoutOverrides[magazineLayoutSeed]
                                )

                                Color.black
                                    .opacity(
                                        magazineBlackOverlayOpacity
                                    )
                                    .allowsHitTesting(false)
                                    .zIndex(500)
                            }
                            .clipShape(
                                RoundedRectangle(
                                    cornerRadius: 28
                                )
                            )
                            .drawingGroup()
                        } else if visualTheme == .origami || visualTheme == .origami43 {
                            ZStack {
                                OrigamiPreviewPage(
                                    images: themedPreviewImages,
                                    theme: visualTheme,
                                    slotReplacementImages: origamiSlotReplacementImages,
                                    activeSwapImages: origamiActiveSwapImages,
                                    activeSwapStyles: origamiActiveSwapStyles,
                                    swapProgress: origamiSwapProgress,
                                    activePhotoName: activePhotoName,
                                    showsPhotoName: true,
                                    transitionProgress: transitionProgress,
                                    animationVariant: origamiAnimationSeed,
                                    cropByImageIdentity: photoCropByImageIdentity,
                                    manualLayoutVariant: manualOrigamiLayoutOverrides[origamiAnimationSeed]
                                )

                                if !previousOrigamiPageImages.isEmpty {
                                    OrigamiWholePageHalfFoldOverlay(
                                        images: previousOrigamiPageImages,
                                        theme: visualTheme,
                                        slotReplacementImages:
                                            previousOrigamiPageReplacements,
                                        animationVariant:
                                            previousOrigamiPageAnimationVariant,
                                        progress:
                                            origamiWholePageFoldProgress,
                                        cropByImageIdentity: photoCropByImageIdentity,
                                        manualLayoutVariant: manualOrigamiLayoutOverrides[previousOrigamiPageAnimationVariant]
                                    )
                                    .allowsHitTesting(false)
                                    .zIndex(100)
                                }

                                Color.black
                                    .opacity(
                                        origamiBlackOverlayOpacity
                                    )
                                    .allowsHitTesting(false)
                                    .zIndex(500)
                            }
                            .clipShape(
                                RoundedRectangle(
                                    cornerRadius: 28
                                )
                            )
                            .drawingGroup()
                        } else if visualTheme == .imagination {
                            ImaginationCardPage(
                                activeImage: activePreviewImage,
                                secondaryImage:
                                    previewImages.indices.contains(
                                        activePhotoIndex + 1
                                    )
                                    ? previewImages[
                                        activePhotoIndex + 1
                                    ]
                                    : nil,
                                activePhotoIndex: activePhotoIndex,
                                transitionProgress:
                                    transitionProgress,
                                isPreviewPlaying:
                                    isPreviewPlaying,
                                playbackRestartToken:
                                    imaginationPlaybackRestartToken,
                                introOutroOverlayOpacity:
                                    imaginationIntroOutroOpacity
                            )
                            .id(activePhotoIndex)
                            .clipShape(
                                RoundedRectangle(
                                    cornerRadius: 28
                                )
                            )
                            .allowsHitTesting(false)
                        } else {
                            if transitionStyle == .fade, let previousPreviewImage {
                                Image(nsImage: previousPreviewImage)
                                    .resizable()
                                    .scaledToFit()
                                    .opacity(max(0, 1 - transitionProgress))
                                    .clipShape(RoundedRectangle(cornerRadius: 28))
                            }

                            Image(nsImage: activePreviewImage)
                                .resizable()
                                .scaledToFit()
                                .opacity(transitionStyle == .fade && previousPreviewImage != nil ? transitionProgress : 1)
                                .clipShape(RoundedRectangle(cornerRadius: 28))

                            VStack {
                                Spacer()

                                HStack {
                                    Text(activePhotoName)
                                        .font(.custom("Figtree", size: 12).weight(.medium))
                                        .foregroundColor(.white.opacity(0.88))
                                        .lineLimit(1)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 7)
                                        .background(Color.black.opacity(0.42))
                                        .clipShape(RoundedRectangle(cornerRadius: 999))

                                    Spacer()
                                }
                                .padding(16)
                            }
                        }
                    } else if isPreparingPhotos {
                        VStack(spacing: 14) {
                            ProgressView()
                                .controlSize(.large)
                                .scaleEffect(0.9)

                            Text("Preparing photo previews… \(preparedPhotoCount) / \(photoCount)")
                                .font(.custom("Figtree", size: 13).weight(.semibold))
                                .foregroundColor(.white)

                            Text("Optimizing images for smooth playback.")
                                .font(.custom("Figtree", size: 13).weight(.medium))
                                .foregroundColor(.white.opacity(0.65))
                        }
                    } else {
                        VStack(spacing: 16) {
                            Image(systemName: "photo.on.rectangle.angled")
                                .font(.system(size: 42, weight: .light))
                                .foregroundColor(AppColors.muted.opacity(0.55))

                            Text("No slideshow yet")
                                .font(.custom("Figtree", size: 13).weight(.semibold))
                                .foregroundColor(AppColors.ink)

                            Text("Add photos and music to generate a preview.")
                                .font(.custom("Figtree", size: 14).weight(.medium))
                                .foregroundColor(AppColors.muted)
                        }
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 220, maxHeight: 260)
                .clipShape(RoundedRectangle(cornerRadius: 34))
                .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                    loadDroppedFileURLs(from: providers) { urls in
                        let musicURLs = urls.filter { url in
                            UTType(filenameExtension: url.pathExtension)?.conforms(to: .audio) == true
                        }

                        let photoURLs = urls.filter { url in
                            UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
                        }

                        if !musicURLs.isEmpty {
                            onDropMusic(musicURLs)
                        } else if !photoURLs.isEmpty {
                            onDropPhotos(photoURLs)
                        }
                    }
                }

                HStack(spacing: 10) {
                    if !previewRenderMode.isRenderedVideo {
                        previewIconButton(
                            systemName: isPreviewPlaying ? "pause.fill" : "play.fill",
                            label: isPreviewPlaying ? "Stop Preview" : "Play Preview",
                            isDisabled: photoCount == 0 || isPreparingPhotos,
                            action: onTogglePreview
                        )

                        previewIconButton(
                            systemName: "arrow.counterclockwise",
                            label: "Play From Beginning",
                            isDisabled: photoCount == 0 || isPreparingPhotos,
                            action: onStartFromBeginning
                        )
                    }

                    previewIconButton(
                        systemName: "arrow.up.left.and.arrow.down.right",
                        label: "Full Screen",
                        isDisabled: photoCount == 0 || isPreparingPhotos,
                        action: onOpenFullScreen
                    )

                    Text(
                        previewRenderMode.isRenderedVideo
                            ? "Video mode uses the play/pause/scrub controls built into the player above."
                            : "Full Screen shows the true, exported look of your slideshow."
                    )
                        .font(.custom("Figtree", size: 10.5).weight(.regular))
                        .foregroundColor(AppColors.muted)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Spacer(minLength: 8)

                    if !previewRenderMode.isRenderedVideo {
                        Text(timeCounterText)
                            .font(.custom("Figtree", size: 12).weight(.regular))
                            .foregroundColor(AppColors.muted)
                            .lineLimit(1)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .top)
            .background(AppColors.background)
            .overlay(
                RoundedRectangle(cornerRadius: 34)
                    .stroke(AppColors.border, lineWidth: 4)
            )
            .clipShape(RoundedRectangle(cornerRadius: 34))

            HStack(spacing: 10) {
                Button(action: onAddPhotos) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            Image(systemName: "photo.on.rectangle.angled")
                                .font(.system(size: 19, weight: isPhotosCardHovered ? .semibold : .medium))
                                .foregroundColor(isPhotosCardHovered ? AppColors.hoverInk : AppColors.ink)
                                .scaleEffect(isPhotosCardHovered ? 1.08 : 1)

                            VStack(alignment: .leading, spacing: 2) {
                                Text("Photos")
                                    .font(.custom("Figtree", size: 13).weight(.medium))
                                    .fontWeight(isPhotosCardHovered ? .semibold : nil)
                                    .foregroundColor(isPhotosCardHovered ? AppColors.hoverInk : AppColors.ink)
                                    .scaleEffect(isPhotosCardHovered ? 1.025 : 1, anchor: .leading)

                                Text(photoStatusText)
                                    .font(.custom("Figtree", size: 10.5).weight(.regular))
                                    .fontWeight(isPhotosCardHovered ? .semibold : nil)
                                    .foregroundColor(isPhotosCardHovered ? AppColors.hoverInk.opacity(0.82) : AppColors.muted.opacity(0.72))
                                    .scaleEffect(isPhotosCardHovered ? 1.02 : 1, anchor: .leading)
                                    .lineLimit(1)
                            }

                            Spacer()
                        }

                        VStack(spacing: 6) {
                            PhotoImportInfoRow(
                                icon: "photo.stack",
                                title: "Select multiple photos",
                                isHovered: isPhotosCardHovered
                            )

                            PhotoImportInfoRow(
                                icon: "arrow.down.doc",
                                title: "Drag & drop supported",
                                isHovered: isPhotosCardHovered
                            )

                            PhotoImportInfoRow(
                                icon: "arrow.left.arrow.right",
                                title: "Reorder anytime in Timeline",
                                isHovered: isPhotosCardHovered
                            )
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(HoverScaleButtonStyle(isHovered: isPhotosCardHovered))
                .onHover { hovering in
                    withAnimation(.linear(duration: 0.10)) {
                        isPhotosCardHovered = hovering
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "music.note.list")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundColor(AppColors.ink)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Music Playlist")
                                .font(.custom("Figtree", size: 13).weight(.medium))
                                .foregroundColor(AppColors.ink)

                            Text("Up to 3 tracks • repeats until slideshow ends")
                                .font(.custom("Figtree", size: 10.5).weight(.regular))
                                .foregroundColor(AppColors.muted.opacity(0.72))
                                .lineLimit(1)
                        }

                        Spacer()
                    }

                    VStack(spacing: 6) {
                        ForEach(0..<3, id: \.self) { index in
                            MusicTrackRow(
                                index: index,
                                hasTrack: selectedMusicURLs.indices.contains(index),
                                subtitle:
                                    selectedMusicURLs.indices.contains(index)
                                        ? selectedMusicURLs[index].lastPathComponent
                                        : index == 0 ? "Add main track" : "Optional",
                                action: {
                                    onAddMusic(index)
                                }
                            )
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .contentShape(RoundedRectangle(cornerRadius: 34))
            .background(AppColors.background)
            .overlay(
                RoundedRectangle(cornerRadius: 34)
                    .stroke(AppColors.border, lineWidth: 4)
            )
            .clipShape(RoundedRectangle(cornerRadius: 34))
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                loadDroppedFileURLs(from: providers) { urls in
                    let musicURLs = urls.filter { url in
                        UTType(filenameExtension: url.pathExtension)?.conforms(to: .audio) == true
                    }

                    let photoURLs = urls.filter { url in
                        UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
                    }

                    if !musicURLs.isEmpty {
                        onDropMusic(musicURLs)
                    } else if !photoURLs.isEmpty {
                        onDropPhotos(photoURLs)
                    }
                }
            }
        
        }
    }

    private var photoStatusText: String {
        if isPreparingPhotos {
            return "Preparing previews… \(preparedPhotoCount) / \(photoCount)"
        }

        return photoCount == 0 ? "Choose multiple image files" : "\(photoCount) photo\(photoCount == 1 ? "" : "s") selected"
    }

    private var musicStatusText: String {
        selectedMusicURL?.lastPathComponent ?? "MP3, WAV or M4A soundtrack"
    }

    private func previewIconButton(
        systemName: String,
        label: String,
        isDisabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        PreviewIconButton(systemName: systemName, label: label, isDisabled: isDisabled, action: action)
    }
}

/// A VStack gives siblings no defined paint order when one overflows its own
/// bounds (unlike a ZStack, `.zIndex` has no effect there), so a tooltip that
/// pops up above its button can end up rendered behind an earlier sibling
/// (e.g. the preview photo card above the button row). Anchor preferences
/// sidestep that: each button reports its frame only while hovered, and the
/// tooltip is actually drawn once, in a single overlay attached higher up
/// (see `ContentView`'s root-level `.overlayPreferenceValue`), which is
/// guaranteed to paint above everything else in the window.
private enum PreviewTooltipPlacement {
    case above
    case below
}

private struct PreviewTooltipAnchor: Identifiable {
    let id: UUID
    let label: String
    let anchor: Anchor<CGRect>
    var placement: PreviewTooltipPlacement = .above
}

private struct PreviewTooltipPreferenceKey: PreferenceKey {
    static var defaultValue: [PreviewTooltipAnchor] = []

    static func reduce(value: inout [PreviewTooltipAnchor], nextValue: () -> [PreviewTooltipAnchor]) {
        value.append(contentsOf: nextValue())
    }
}

private struct PreviewIconButton: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    let systemName: String
    let label: String
    let isDisabled: Bool
    let action: () -> Void

    @State private var isHovered = false
    @State private var tooltipID = UUID()

    private var activeColor: Color {
        isHovered && !isDisabled ? AppColors.hoverInk : AppColors.ink
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: isHovered && !isDisabled ? .semibold : .medium))
                .foregroundColor(activeColor)
                .scaleEffect(isHovered && !isDisabled ? 1.08 : 1)
                .frame(width: 34, height: 34)
                .background(AppColors.panel)
                .overlay(
                    Circle()
                        .stroke(activeColor.opacity(isHovered && !isDisabled ? 1 : 0.7), lineWidth: isHovered && !isDisabled ? 2.2 : 1.6)
                )
                .clipShape(Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.55 : 1)
        .animation(.linear(duration: 0.10), value: isHovered)
        .onHover { hovering in
            isHovered = hovering && !isDisabled
        }
        .anchorPreference(key: PreviewTooltipPreferenceKey.self, value: .bounds) { anchor in
            (isHovered && !isDisabled) ? [PreviewTooltipAnchor(id: tooltipID, label: label, anchor: anchor)] : []
        }
    }
}

struct PhotoImportInfoRow: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    let icon: String
    let title: String
    let isHovered: Bool

    // A white overlay this opaque was tuned to read as a subtle lighter
    // card on top of the white/buttery backgrounds — on the dark theme's
    // near-black background, the same opacity reads as a jarring bright
    // gray box instead, so it needs much lower opacity there.
    private var isDarkTheme: Bool {
        themeManager.current == .dark
    }

    private var iconBackground: Color {
        Color.white.opacity(isDarkTheme ? 0.10 : 0.48)
    }

    private var rowBackground: Color {
        isDarkTheme
            ? Color.white.opacity(isHovered ? 0.09 : 0.05)
            : Color.white.opacity(isHovered ? 0.42 : 0.28)
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: isHovered ? .semibold : .semibold))
                .foregroundColor(isHovered ? AppColors.hoverInk : AppColors.ink.opacity(0.8))
                .frame(width: 18, height: 18)
                .background(iconBackground)
                .clipShape(Circle())
                .scaleEffect(isHovered ? 1.08 : 1)

            Text(title)
                .font(.custom("Figtree", size: 10.5).weight(.regular))
                .fontWeight(isHovered ? .semibold : nil)
                .foregroundColor(isHovered ? AppColors.hoverInk : AppColors.muted.opacity(0.78))
                .scaleEffect(isHovered ? 1.02 : 1, anchor: .leading)
                .lineLimit(1)

            Spacer()
        }
        .padding(.horizontal, 8)
        .frame(height: 34)
        .background(rowBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isHovered ? AppColors.hoverInk.opacity(0.8) : AppColors.border.opacity(0.8), lineWidth: isHovered ? 1.6 : 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .animation(.linear(duration: 0.10), value: isHovered)
    }
}

struct MusicTrackRow: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    let index: Int
    let hasTrack: Bool
    let subtitle: String
    let action: () -> Void

    @State private var isHovered = false

    // See the matching comment in PhotoImportInfoRow — the same white
    // overlay opacity reads far too bright against the dark theme.
    private var isDarkTheme: Bool {
        themeManager.current == .dark
    }

    private var iconBackground: Color {
        Color.white.opacity(isDarkTheme ? 0.10 : 0.48)
    }

    private var rowBackground: Color {
        isDarkTheme
            ? Color.white.opacity(isHovered ? 0.09 : 0.05)
            : Color.white.opacity(isHovered ? 0.42 : 0.28)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: hasTrack ? "music.note" : "plus")
                    .font(.system(size: 10, weight: isHovered ? .semibold : .semibold))
                    .foregroundColor(isHovered ? AppColors.hoverInk : AppColors.ink.opacity(0.8))
                    .frame(width: 18, height: 18)
                    .background(iconBackground)
                    .clipShape(Circle())
                    .scaleEffect(isHovered ? 1.08 : 1)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Track \(index + 1)")
                        .font(.custom("Figtree", size: 10).weight(.medium))
                        .fontWeight(isHovered ? .semibold : nil)
                        .foregroundColor(isHovered ? AppColors.hoverInk : AppColors.ink)
                        .scaleEffect(isHovered ? 1.03 : 1, anchor: .leading)

                    Text(subtitle)
                        .font(.custom("Figtree", size: 10.5).weight(.regular))
                        .fontWeight(isHovered ? .semibold : nil)
                        .foregroundColor(isHovered ? AppColors.hoverInk.opacity(0.82) : AppColors.muted.opacity(0.72))
                        .scaleEffect(isHovered ? 1.02 : 1, anchor: .leading)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()
            }
            .padding(.horizontal, 8)
            .frame(height: 34)
            .background(rowBackground)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isHovered ? AppColors.hoverInk.opacity(0.8) : AppColors.border.opacity(0.8), lineWidth: isHovered ? 1.6 : 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(HoverScaleButtonStyle(isHovered: isHovered))
        .animation(.linear(duration: 0.10), value: isHovered)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

struct RightExportPanel: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @Binding var selectedResolution: String
    @Binding var selectedFormat: String
    let selectedMusicURL: URL?
    let selectedMusicCount: Int
    let canExport: Bool
    let isExporting: Bool
    let exportProgress: Double
    let exportStatusText: String?
    let onExportVideo: () -> Void

    @State private var isShowingExportConfirmation: Bool = false

    private let resolutions = ["480p", "720p", "1080p", "4K", "Original"]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PanelTitle(title: "Export", subtitle: "Render your video")

            VStack(alignment: .leading, spacing: 10) {
                Text("Video Settings")
                    .font(.custom("Figtree", size: 13).weight(.medium))
                    .foregroundColor(AppColors.ink)

                SettingRow(label: "Format", value: selectedFormat)
                SettingRow(label: "Codec", value: selectedResolution == "Original" ? "H.265" : "H.264")
                SettingRow(label: "Resolution", value: selectedResolution)
                SettingRow(label: "FPS", value: "30")

                VStack(alignment: .leading, spacing: 7) {
                    Text("Export Size")
                        .font(.custom("Figtree", size: 12).weight(.regular))
                        .foregroundColor(AppColors.muted)

                    VStack(spacing: 8) {
                        HStack(spacing: 8) {
                            exportResolutionButton("480p")
                            exportResolutionButton("720p")
                        }

                        HStack(spacing: 8) {
                            exportResolutionButton("1080p")
                            exportResolutionButton("4K")
                        }

                        HStack(spacing: 8) {
                            exportResolutionButton("Original")
                        }
                    }
                }
                .padding(.top, 2)

                HStack(spacing: 8) {
                    Text(exportStatusText ?? exportHelperText)
                        .font(.custom("Figtree", size: 11).weight(.regular))
                        .foregroundColor(AppColors.muted.opacity(0.78))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if isExporting {
                        ProgressView(
                            value: max(
                                0,
                                min(1, exportProgress)
                            ),
                            total: 1
                        )
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                        .scaleEffect(0.7)
                        .frame(width: 16, height: 16)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AppColors.panel)
                .overlay(
                    RoundedRectangle(cornerRadius: 18)
                        .stroke(AppColors.border.opacity(0.85), lineWidth: 2)
                )
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .padding(.top, 2)

            }
            .padding(14)
            .background(AppColors.background)
            .overlay(
                RoundedRectangle(cornerRadius: 24)
                    .stroke(AppColors.border, lineWidth: 4)
            )
            .clipShape(RoundedRectangle(cornerRadius: 24))

        }
        .padding(14)
        .frame(width: 290)
        .background(AppColors.background)
        .overlay(
            RoundedRectangle(cornerRadius: 34)
                .stroke(AppColors.border, lineWidth: 4)
        )
        .clipShape(RoundedRectangle(cornerRadius: 34))
        .popover(isPresented: $isShowingExportConfirmation, arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Export Video")
                    .font(.custom("Figtree", size: 14).weight(.medium))
                    .foregroundColor(AppColors.ink)

                if selectedResolution == "Original" {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Important")
                            .font(.custom("Figtree", size: 11).weight(.semibold))
                            .foregroundColor(Color(red: 0.620, green: 0.180, blue: 0.160))

                        Text("Original export uses H.265/HEVC to keep full source size smooth. Newer Macs should export normally. Older Macs without HEVC support may not export Original smoothly — use 4K or 1080p instead.")
                            .font(.custom("Figtree", size: 10.5).weight(.regular))
                            .foregroundColor(Color(red: 0.390, green: 0.220, blue: 0.200).opacity(0.86))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 11)
                    .padding(.vertical, 9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(red: 1.000, green: 0.925, blue: 0.900))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(Color(red: 0.820, green: 0.300, blue: 0.240).opacity(0.42), lineWidth: 1.6)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                }

                VStack(alignment: .leading, spacing: 7) {
                    SettingRow(label: "Resolution", value: selectedResolution)
                    SettingRow(label: "Size", value: exportSizeText(for: selectedResolution))
                    SettingRow(label: "Audio", value: exportAudioText)
                }

                VStack(alignment: .leading, spacing: 7) {
                    Text("Format")
                        .font(.custom("Figtree", size: 12).weight(.regular))
                        .foregroundColor(AppColors.muted)

                    HStack(spacing: 8) {
                        exportFormatButton("MP4")
                        exportFormatButton("MOV")
                    }
                }

                Text("Choose where to save this \(selectedResolution) slideshow video.")
                    .font(.custom("Figtree", size: 11).weight(.regular))
                    .foregroundColor(AppColors.muted.opacity(0.78))
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Button("Cancel") {
                        isShowingExportConfirmation = false
                    }
                    .buttonStyle(.plain)
                    .font(.custom("Figtree", size: 11).weight(.medium))
                    .foregroundColor(AppColors.muted.opacity(0.78))
                    .padding(.horizontal, 13)
                    .padding(.vertical, 8)
                    .background(AppColors.panel)
                    .clipShape(RoundedRectangle(cornerRadius: 999))

                    Button {
                        isShowingExportConfirmation = false
                        onExportVideo()
                    } label: {
                        Text(isExporting ? "Exporting…" : "Export Video")
                            .font(.custom("Figtree", size: 11).weight(.medium))
                            .foregroundColor(AppColors.ink)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 8)
                            .background(AppColors.panel)
                            .overlay(
                                RoundedRectangle(cornerRadius: 999)
                                    .stroke(AppColors.border, lineWidth: 1.7)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 999))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canExport || isExporting)
                }
            }
            .padding(16)
            .frame(width: 260)
            .background(AppColors.background)
        }
        
    }

    private func exportResolutionButton(_ resolution: String) -> some View {
        TimingModeButton(
            title: resolution,
            isSelected: selectedResolution == resolution
        ) {
            selectedResolution = resolution

            if canExport && !isExporting {
                isShowingExportConfirmation = true
            }
        }
    }

    private func exportFormatButton(_ format: String) -> some View {
        TimingModeButton(
            title: format,
            isSelected: selectedFormat == format
        ) {
            selectedFormat = format
        }
    }

    private var exportAudioText: String {
        if selectedMusicCount > 1 {
            return "\(selectedMusicCount) tracks selected"
        }

        return selectedMusicURL?.lastPathComponent ?? "Silent for now"
    }

    private func exportSizeText(for resolution: String) -> String {
        switch resolution {
        case "480p":
            return "854 × 480"
        case "720p":
            return "1280 × 720"
        case "1080p":
            return "1920 × 1080"
        case "4K":
            return "3840 × 2160"
        case "Original":
            return "Source image size"
        default:
            return resolution
        }
    }

    private var exportHelperText: String {
        "Choose a smaller size for quick sharing, 4K for crisp video, or Original to use the source image size."
    }
}

struct TimelinePanel: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @Binding var photoURLs: [URL]
    @Binding var previewImages: [NSImage]
    let musicURL: URL?
    let musicCount: Int
    let isPreparingPhotos: Bool
    let onDropPhotos: ([URL]) -> Void
    let onDropMusic: ([URL]) -> Void
    let onClearImages: () -> Void
    @Binding var activePhotoIndex: Int

    @State private var draggedPhotoURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                PanelTitle(title: "Timeline", subtitle: timelineSubtitle)

                Spacer()

                HStack(spacing: 10) {
                    if isPreparingPhotos {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.75)
                            .frame(width: 18, height: 18)
                    }

                    if !photoURLs.isEmpty {
                        Button("Clear Images", action: onClearImages)
                            .buttonStyle(BrutalButtonStyle())
                    }
                }
                .padding(.top, 2)
            }

            if photoURLs.isEmpty {
                EmptyTimelineStoryboard()
            } else {
                ScrollView(.horizontal, showsIndicators: true) {
                    HStack(spacing: 12) {
                        ForEach(Array(photoURLs.enumerated()), id: \.element) { index, url in
                            TimelinePhotoThumb(
                                index: index,
                                url: url,
                                isActive: index == activePhotoIndex
                            )
                            .onDrag {
                                draggedPhotoURL = url
                                return NSItemProvider(object: url.absoluteString as NSString)
                            }
                            .onDrop(
                                of: [.text],
                                delegate: TimelinePhotoDropDelegate(
                                    targetURL: url,
                                    draggedPhotoURL: $draggedPhotoURL,
                                    photoURLs: $photoURLs,
                                    previewImages: $previewImages,
                                    activePhotoIndex: $activePhotoIndex
                                )
                            )
                        }

                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .padding(14)
        .background(AppColors.background)
        .overlay(
            RoundedRectangle(cornerRadius: 34)
                .stroke(AppColors.border, lineWidth: 4)
        )
        .clipShape(RoundedRectangle(cornerRadius: 34))
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            loadDroppedFileURLs(from: providers) { urls in
                let musicURLs = urls.filter { url in
                    UTType(filenameExtension: url.pathExtension)?.conforms(to: .audio) == true
                }

                let photoURLs = urls.filter { url in
                    UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
                }

                if !musicURLs.isEmpty {
                    onDropMusic(musicURLs)
                } else if !photoURLs.isEmpty {
                    onDropPhotos(photoURLs)
                }
            }
        }
        
    }

    private var timelineSubtitle: String {
        if let musicURL {
            return "Photos arranged with \(musicURL.lastPathComponent)"
        }

        return "Drag photos to rearrange your timeline"
    }
}


struct EmptyTimelineStoryboard: View {
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(0..<8, id: \.self) { _ in
                    EmptyTimelinePlaceholderThumb()
                }

                Spacer(minLength: 0)
            }
        }
        .frame(height: 66)
    }
}

struct EmptyTimelinePlaceholderThumb: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    var body: some View {
        RoundedRectangle(cornerRadius: 14)
            .fill(AppColors.panel)
            .frame(width: 92, height: 56)
            .overlay(
                Image(systemName: "photo")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundColor(AppColors.muted.opacity(0.55))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(AppColors.border.opacity(0.75), style: StrokeStyle(lineWidth: 1.6, dash: [4, 4]))
            )
    }
}

struct TimelinePhotoThumb: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    let index: Int
    let url: URL
    let isActive: Bool

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 14)
                .fill(AppColors.panel)

            if let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 92, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 18))
                    .foregroundColor(AppColors.muted.opacity(0.65))
                    .frame(width: 92, height: 56)
            }

            Text("\(index + 1)")
                .font(.custom("Figtree", size: 10).weight(.medium))
                .foregroundColor(.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(Color.black.opacity(0.45))
                .clipShape(RoundedRectangle(cornerRadius: 999))
                .padding(6)
        }
        .frame(width: 92, height: 56)
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(borderColor, lineWidth: isActive ? 4 : 3)
        )
    }

    private var borderColor: Color {
        isActive
            ? AppColors.hoverInk
            : AppColors.border.opacity(0.85)
    }
}


struct TimelinePhotoDropDelegate: DropDelegate {
    let targetURL: URL
    @Binding var draggedPhotoURL: URL?
    @Binding var photoURLs: [URL]
    @Binding var previewImages: [NSImage]
    @Binding var activePhotoIndex: Int

    func dropEntered(info: DropInfo) {
        // Keep timeline stable while dragging. Reorder only once on drop.
    }

    func performDrop(info: DropInfo) -> Bool {
        defer {
            draggedPhotoURL = nil
        }

        guard let draggedPhotoURL,
              draggedPhotoURL != targetURL,
              let fromIndex = photoURLs.firstIndex(of: draggedPhotoURL),
              let toIndex = photoURLs.firstIndex(of: targetURL)
        else {
            return true
        }

        let moveToOffset = toIndex > fromIndex ? toIndex + 1 : toIndex

        withAnimation(.easeInOut(duration: 0.14)) {
            photoURLs.move(
                fromOffsets: IndexSet(integer: fromIndex),
                toOffset: moveToOffset
            )

            if previewImages.indices.contains(fromIndex), previewImages.indices.contains(toIndex) {
                previewImages.move(
                    fromOffsets: IndexSet(integer: fromIndex),
                    toOffset: moveToOffset
                )
            }

            if let movedPhotoIndex = photoURLs.firstIndex(of: draggedPhotoURL) {
                activePhotoIndex = movedPhotoIndex
            } else {
                activePhotoIndex = min(toIndex, max(0, photoURLs.count - 1))
            }
        }

        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}

struct PanelTitle: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.custom("Figtree", size: 17).weight(.medium))
                .foregroundColor(AppColors.ink)

            Text(subtitle)
                .font(.custom("Figtree", size: 13).weight(.regular))
                .foregroundColor(AppColors.muted)
        }
    }
}

struct DropCard: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    let icon: String
    let title: String
    let subtitle: String
    var isLoading: Bool = false

    @State private var isHovered = false

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .regular))
                .foregroundColor(activeColor)

            VStack(spacing: 2) {
                Text(title)
                    .font(.custom("Figtree", size: 12).weight(.medium))
                    .foregroundColor(activeColor)
                    .scaleEffect(isHovered ? 1.035 : 1)

                HStack(spacing: 6) {
                    if isLoading {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.55)
                            .frame(width: 12, height: 12)
                    }

                    Text(subtitle)
                        .font(.custom("Figtree", size: 10).weight(.regular))
                        .foregroundColor(isHovered ? activeColor.opacity(0.82) : AppColors.muted)
                        .lineLimit(1)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 9)
        .background(isHovered ? AppColors.panel : AppColors.background)
        .overlay(
            RoundedRectangle(cornerRadius: 22)
                .stroke(isHovered ? activeColor : AppColors.border, lineWidth: isHovered ? 3.4 : 3)
        )
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .animation(.linear(duration: 0.10), value: isHovered)
        .onHover { hovering in
            isHovered = hovering
        }
    }

    private var activeColor: Color {
        isHovered ? AppColors.hoverInk : AppColors.ink
    }
}



struct TimingModeButton: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    let title: String
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.custom("Figtree", size: 11).weight(.medium))
                .fontWeight(isSelected || isHovered ? .semibold : nil)
                .foregroundColor(activeColor)
                .lineLimit(1)
                .scaleEffect(isSelected || isHovered ? 1.035 : 1)
                .animation(.linear(duration: 0.10), value: isHovered)
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity)
                .background(AppColors.panel)
                .overlay(
                    RoundedRectangle(cornerRadius: 999)
                        .stroke(borderColor.opacity(isSelected || isHovered ? 1 : 0.7), lineWidth: isSelected || isHovered ? 1.8 : 1.4)
                )
                .clipShape(RoundedRectangle(cornerRadius: 999))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }

    private var activeColor: Color {
        if isSelected || isHovered {
            return AppColors.hoverInk
        }

        return AppColors.ink
    }

    private var borderColor: Color {
        if isSelected || isHovered {
            return AppColors.hoverInk
        }

        return AppColors.border
    }
}

struct CompactStepperRow: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let suffix: String

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.custom("Figtree", size: 12).weight(.regular))
                .foregroundColor(AppColors.muted)

            Spacer()

            Stepper(
                value: $value,
                in: range,
                step: step
            ) {
                Text(formattedValue)
                    .font(.custom("Figtree", size: 12).weight(.regular))
                    .foregroundColor(AppColors.ink)
                    .frame(minWidth: 34, alignment: .trailing)
            }
            .frame(width: 104)
        }
    }

    private var formattedValue: String {
        if value.rounded() == value {
            return "\(Int(value))\(suffix)"
        }

        return String(format: "%.1f%@", value, suffix)
    }
}

struct SettingRow: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.custom("Figtree", size: 12).weight(.regular))
                .foregroundColor(AppColors.muted)

            Spacer()

            Text(value)
                .font(.custom("Figtree", size: 12).weight(.regular))
                .foregroundColor(AppColors.ink)
        }
    }
}

struct HoverScaleButtonStyle: ButtonStyle {
    let isHovered: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.linear(duration: 0.08), value: configuration.isPressed)
    }
}

struct HeaderLinkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HeaderLinkButtonLabel(configuration: configuration)
    }
}

struct HeaderLinkButtonLabel: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    let configuration: ButtonStyle.Configuration

    @State private var isHovered = false

    var body: some View {
        configuration.label
            .font(.custom("Figtree", size: 11).weight(.medium))
            .fontWeight(isHovered ? .semibold : nil)
            .foregroundColor(textColor)
            .lineLimit(1)
            .scaleEffect(configuration.isPressed ? 0.985 : (isHovered ? 1.1 : 1))
            .animation(.linear(duration: 0.10), value: isHovered)
            .animation(.linear(duration: 0.08), value: configuration.isPressed)
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .onHover { hovering in
                isHovered = hovering
            }
    }

    private var textColor: Color {
        isHovered
            ? AppColors.hoverInk
            : AppColors.ink
    }
}

struct BrutalButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverButtonLabel(
            configuration: configuration,
            isPrimary: false
        )
    }
}

struct PrimaryBrutalButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverButtonLabel(
            configuration: configuration,
            isPrimary: true
        )
    }
}

struct HoverButtonLabel: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    let configuration: ButtonStyle.Configuration
    let isPrimary: Bool

    @State private var isHovered = false

    var body: some View {
        configuration.label
            .font(.custom("Figtree", size: 11).weight(.medium))
            .fontWeight(isHovered ? .semibold : nil)
            .foregroundColor(textColor)
            .lineLimit(1)
            .scaleEffect(configuration.isPressed ? 0.985 : (isHovered ? 1.035 : 1))
            .animation(.linear(duration: 0.10), value: isHovered)
            .animation(.linear(duration: 0.08), value: configuration.isPressed)
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(AppColors.panel)
            .overlay(
                RoundedRectangle(cornerRadius: 999)
                    .stroke(borderColor, lineWidth: isHovered ? 1.8 : 1.4)
            )
            .clipShape(RoundedRectangle(cornerRadius: 999))
            .onHover { hovering in
                isHovered = hovering
            }
    }

    private var textColor: Color {
        isHovered
            ? AppColors.hoverInk
            : AppColors.ink
    }

    private var borderColor: Color {
        isHovered
            ? AppColors.hoverInk
            : AppColors.border
    }
}

// A left-to-right, wrapping row layout (unlike LazyVGrid, which forces
// every cell to the same width) — used by the Show screen's thumbnail
// grid so each photo keeps its own natural aspect ratio at a shared
// height: landscape photos read wider, portrait photos read narrower,
// with nothing cropped.
struct FlowLayout: Layout {
    var spacing: CGFloat = 16
    var lineSpacing: CGFloat = 26

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var totalWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)

            if x + size.width > maxWidth, x > 0 {
                totalHeight += rowHeight + lineSpacing
                totalWidth = max(totalWidth, x - spacing)
                x = 0
                rowHeight = 0
            }

            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }

        totalHeight += rowHeight
        totalWidth = max(totalWidth, x - spacing)

        return CGSize(width: maxWidth.isFinite ? maxWidth : totalWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)

            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + lineSpacing
                rowHeight = 0
            }

            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - ShowGrid (standalone photo review/culling screen)

// Owns the ShowGrid window's lifecycle as a singleton so both the header's
// "ShowGrid" button (from inside ContentView) and the Welcome screen's
// ShowGrid square (before ContentView even exists) can open/refocus the
// exact same window instead of each keeping their own separate
// NSWindowController and potentially opening duplicates.
final class ShowGridWindowController {
    static let shared = ShowGridWindowController()

    private var windowController: NSWindowController?

    private init() {}

    // Opens (or refocuses) the ShowGrid screen in its own standalone,
    // user-resizable/maximizable window instead of as an in-window
    // overlay — an in-window overlay would inherit ContentView's own
    // root layout, which is `.fixedSize(vertical: true)` and locked to
    // its ideal content height, cutting off anything meant to fill the
    // physical screen.
    func open(initialPhotoURLs: [URL] = []) {
        if let controller = windowController {
            controller.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "BriefShow"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 700, height: 480)
        window.center()

        let controller = NSWindowController(window: window)
        windowController = controller

        window.contentView = NSHostingView(
            rootView: PhotoShowSheet(initialPhotoURLs: initialPhotoURLs, onClose: { [weak self] in
                self?.close()
            })
        )

        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        windowController?.close()
        windowController = nil
    }

    // Lets the very first BriefShow/ShowGrid window — the one WindowGroup
    // itself creates at launch, which this controller never created and
    // so never knew about — register as "the" tracked window. Without
    // this, clicking "Browse" from the Slideshow editor had no existing
    // controller to find, so it always spawned a brand new second ShowGrid
    // window instead of returning to the original one.
    func registerIfNeeded(_ window: NSWindow) {
        guard windowController == nil else {
            return
        }

        windowController = NSWindowController(window: window)
    }
}

// Reads the NSWindow hosting a SwiftUI view — used only to hand that
// window to ShowGridWindowController so it can track a window it didn't
// create itself (see registerIfNeeded above).
private struct WindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()

        DispatchQueue.main.async {
            if let window = view.window {
                onResolve(window)
            }
        }

        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

// Owns the BriefShow editor window's lifecycle the same way
// ShowGridWindowController owns ShowGrid's — needed because ShowGrid's
// "BriefShow" header button must be able to open (or refocus) the main
// editor even when it isn't currently open (e.g. the Welcome window
// already closed after the user chose ShowGrid instead).
final class BriefShowWindowController {
    static let shared = BriefShowWindowController()

    private var windowController: NSWindowController?

    private init() {}

    // initialPhotoURLs is only used the first time this opens a fresh
    // window — if a BriefShow window is already open, this just refocuses
    // it rather than overwriting whatever session is already in progress
    // there.
    func open(initialPhotoURLs: [URL] = []) {
        if let controller = windowController {
            controller.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "BriefShow"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.center()

        let controller = NSWindowController(window: window)
        windowController = controller

        window.contentView = NSHostingView(rootView: ContentView(initialPhotoURLs: initialPhotoURLs))

        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        windowController?.close()
        windowController = nil
    }
}

// Opened from the "ShowGrid" header button, independent of the Kousei/Kirigami
// slideshow-creation flow: browse an entire photo batch on one page, mark
// favorites, and inspect one or up to five selected photos at a larger
// size — similar in spirit to Adobe Bridge's review workflow.
struct PhotoShowSheet: View {
    let onClose: () -> Void
    let initialPhotoURLs: [URL]

    init(initialPhotoURLs: [URL] = [], onClose: @escaping () -> Void) {
        self.initialPhotoURLs = initialPhotoURLs
        self.onClose = onClose
    }

    @State private var photoURLs: [URL] = []
    @State private var gridThumbnails: [URL: NSImage] = [:]
    @State private var loupeImages: [URL: NSImage] = [:]
    @State private var likedURLs: Set<URL> = []
    @State private var ratings: [URL: Int] = [:]
    @State private var selectedURLs: Set<URL> = []

    // Order photos were added to `selectedURLs`, oldest first — a Set has
    // no order of its own, and finding "the first 5 selected" (for the
    // Space-preview cap and the yellow-vs-white border below) needs one.
    // Always kept in sync with `selectedURLs` through replaceSelection/
    // toggleSelection/removeFromSelection rather than mutated directly.
    @State private var selectionOrder: [URL] = []
    @State private var thumbnailSize: CGFloat = 180
    @State private var loupeURLs: [URL]?

    // Set (never read back) whenever Left/Right-arrow navigation lands on a
    // new photo, so the grid can scroll that thumbnail into view even when
    // it's off-screen — see the ScrollViewReader in `thumbnailGrid`.
    @State private var scrollToPhotoURL: URL?
    @State private var isLoadingPhotos: Bool = false
    @State private var loadedThumbnailCount: Int = 0
    @State private var keyMonitor: Any?
    @State private var isDropTargeted: Bool = false
    @State private var isClearAllConfirmationPresented = false
    @State private var isShortcutsHovered = false

    // Brief "N Stars" confirmation shown over the loupe when a rating is
    // set with the 1-5 keys while previewing — the loupe has no visible
    // star row to click (unlike the grid), so without this a client
    // rating a photo there had no sign anything happened at all.
    @State private var ratingToastText: String?
    @State private var ratingToastDismissWorkItem: DispatchWorkItem?

    // Right-click "Add to Bin" on a photo (in the grid) or a folder (in the
    // sidebar) — held here until the confirmation dialog is answered, since
    // moving something to the Trash isn't easily undone from inside
    // BriefShow itself.
    @State private var pendingTrashPhotoURLs: [URL]?
    @State private var pendingTrashFolderNode: FolderNode?
    @State private var isTrashPhotoConfirmationPresented = false
    @State private var isTrashFolderConfirmationPresented = false

    // "Paste" always reads its actual content straight from
    // NSPasteboard.general (see pasteboardFileURLs) — that's what makes
    // pasting photos Copied in Finder, not just ones Cut/Copied inside
    // BriefShow itself, work. These two just remember whether BriefShow's
    // own last Cut/Copy is still the thing sitting on that pasteboard, so
    // Paste can tell a real "move it" Cut apart from a plain Finder Copy
    // (where nothing should ever be deleted) — see isPasteboardOurCut.
    @State private var clipboardURLs: [URL] = []
    @State private var clipboardIsCut = false

    // Left-hand folder tree, rooted at the client's Desktop — this is
    // ShowGrid's now-primary way of loading photos (picking a folder loads
    // whatever's inside it automatically), alongside the older manual
    // "Add Photos" picker and drag-and-drop.
    @State private var rootFolderNode: FolderNode?
    @State private var selectedFolderURL: URL?

    // Same footer links (RocketsBrief / Support / Fund Mission /
    // Disclaimer) that used to live on the now-retired Welcome screen —
    // kept reachable from the bottom of ShowGrid since it's the app's
    // first screen now.
    @State private var isRocketsBriefHovered = false
    @State private var isSupportHovered = false
    @State private var isFundMissionHovered = false
    @State private var isDisclaimerHovered = false
    @State private var isDisclaimerNoticePresented = false

    // ShowGrid follows the same White/Buttery/Dark theme as the main
    // BriefShow window (chosen from the Welcome screen's theme circles)
    // instead of always being dark — needs its own observation of
    // ThemeManager so this window re-renders when the theme changes.
    @ObservedObject private var themeManager = ThemeManager.shared

    // ShowGrid became the app's first (and, for most clients, only)
    // window when it replaced the old Welcome chooser — but the
    // update-required / account-lock overlays were left behind on
    // ContentView, the old first window that's now just the secondary
    // "BriefShow" editor most clients never open. That silently broke
    // remote update checks and the remote kill-switch for anyone who
    // never clicks through to the editor: bumping "Latest Version" in
    // the admin panel had nothing left to check it against. Observing
    // the same AppRemoteStatus/AccountManager singletons here and
    // showing the same overlays restores that for ShowGrid itself.
    @ObservedObject private var remoteStatus = AppRemoteStatus.shared
    @ObservedObject private var accountManager = AccountManager.shared

    // Selection itself is no longer capped — a client can select as many
    // photos as they want. This instead caps how many of them the Space
    // loupe actually previews (loupeGrid/loupeRows are laid out for at
    // most 5 photos) and how many get the yellow "will preview" border
    // below; see previewSelectedURLs.
    private let maxPreviewCount = 5
    private let maxRatingStars = 5
    private let minThumbnailSize: CGFloat = 90
    private let maxThumbnailSize: CGFloat = 320

    // Dark theme uses a soft, light yellow (rather than a saturated gold)
    // against its near-black background; White/Buttery use a mid-gray
    // instead of the generic theme hover accent's near-black tone, which
    // read too heavy against the stars/circle here.
    private var accentColor: Color {
        themeManager.current == .dark
            ? Color(red: 1.0, green: 0.94, blue: 0.62)
            : Color(red: 0.56, green: 0.56, blue: 0.58)
    }

    // First 5 selected photos, in selection order — the ones the Space
    // loupe will actually show and the ones the grid marks with a yellow
    // border. Anything selected beyond that (the 6th, 7th, ...) still
    // counts as selected everywhere else (ratings, like, copy/cut), just
    // not here.
    private var previewSelectedURLs: Set<URL> {
        Set(selectionOrder.prefix(maxPreviewCount))
    }

    var body: some View {
        ZStack {
            AppColors.background
                .ignoresSafeArea()

            HStack(spacing: 0) {
                if let rootFolderNode {
                    FolderTreeSidebar(
                        rootNode: rootFolderNode,
                        selectedURL: $selectedFolderURL,
                        isPasteAvailable: !pasteboardFileURLs().isEmpty,
                        onSetClipboard: { urls, isCut in
                            clipboardURLs = urls
                            clipboardIsCut = isCut
                        },
                        onPasteIntoFolder: { node in
                            pasteClipboard(into: node.url)
                        },
                        onNewFolder: { node in
                            createNewFolder(in: node.url)
                        },
                        onTrashFolder: requestTrashFolder
                    )
                        .frame(width: 260)

                    Divider()
                }

                VStack(spacing: 0) {
                    header

                    if photoURLs.isEmpty {
                        emptyState
                    } else {
                        thumbnailGrid
                    }

                    showGridFooter
                }
            }

            if let loupeURLs, !loupeURLs.isEmpty {
                loupeOverlay(for: loupeURLs)
            }

            // Photo import/folder loading runs on a background queue and
            // never blocks the UI, but with nothing on screen to say so, a
            // few hundred thumbnails decoding felt indistinguishable from
            // BriefShow having hung. This badge is the only visible sign
            // that it's working — non-interactive, so it never blocks
            // clicks on whatever's already loaded underneath it.
            if isLoadingPhotos {
                loadingIndicator
                    .transition(.opacity)
                    .allowsHitTesting(false)
                    .zIndex(250)
            }

            if isDropTargeted {
                RoundedRectangle(cornerRadius: 0)
                    .strokeBorder(AppColors.hoverInk.opacity(0.85), lineWidth: 4)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }

            // Rendered here at the top level (rather than as a local overlay
            // on the title text itself) so it always draws above the
            // thumbnail grid — a local overlay nested inside the header
            // gets painted UNDER the grid, since the grid is declared after
            // the header in the same VStack and both are siblings there.
            if isShortcutsHovered {
                VStack {
                    HStack {
                        // Leading padding accounts for the folder-tree
                        // sidebar's width (260) plus its divider, so this
                        // lands under the "BriefShow" wordmark in the main
                        // content area instead of covering the tree next
                        // to it, on the window's actual left edge.
                        ShowGridShortcutsHoverCard()
                            .padding(.leading, 284)
                            .padding(.top, 46)

                        Spacer()
                    }

                    Spacer()
                }
                .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .topLeading)))
                .allowsHitTesting(false)
                .zIndex(400)
            }

            // Same remote-config gate ContentView (the editor window) has
            // had all along — mirrored here since ShowGrid, not the
            // editor, is the window most clients actually see. See the
            // remoteStatus/accountManager doc comment above for why this
            // was missing.
            if remoteStatus.isUpdateAvailable {
                UpdateRequiredOverlay(
                    latestVersion: remoteStatus.config?.latestVersion ?? remoteStatus.currentVersion,
                    downloadURL: remoteStatus.config?.downloadUrl,
                    releaseNotes: remoteStatus.config?.releaseNotes
                )
                .ignoresSafeArea()
                .zIndex(20000)
                .transition(.opacity)
            } else if remoteStatus.isLocked && !accountManager.isSignedIn {
                LockedAccessOverlay(lockMessage: remoteStatus.config?.lockMessage)
                    .ignoresSafeArea()
                    .zIndex(19000)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .preferredColorScheme(themeManager.current == .dark ? .dark : .light)
        .sheet(isPresented: $isDisclaimerNoticePresented) {
            DisclaimerNoticeModal()
        }
        .confirmationDialog(
            pendingTrashPhotoURLs?.count == 1 ? "Move this photo to the Trash?" : "Move \(pendingTrashPhotoURLs?.count ?? 0) photos to the Trash?",
            isPresented: $isTrashPhotoConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                if let pendingTrashPhotoURLs {
                    trashPhotos(pendingTrashPhotoURLs)
                }
                pendingTrashPhotoURLs = nil
            }
            Button("Cancel", role: .cancel) {
                pendingTrashPhotoURLs = nil
            }
        } message: {
            Text("This moves the original photo file(s) to the Trash. You can restore them from there.")
        }
        .confirmationDialog(
            "Move \"\(pendingTrashFolderNode?.name ?? "")\" to the Trash?",
            isPresented: $isTrashFolderConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                if let pendingTrashFolderNode {
                    trashFolder(pendingTrashFolderNode)
                }
                pendingTrashFolderNode = nil
            }
            Button("Cancel", role: .cancel) {
                pendingTrashFolderNode = nil
            }
        } message: {
            Text("This moves the whole folder, with everything inside it, to the Trash. You can restore it from there.")
        }
        .onAppear {
            installKeyMonitor()
            Task { await ExportCounter.flushAll() }
            Task { await remoteStatus.refresh() }

            if photoURLs.isEmpty, !initialPhotoURLs.isEmpty {
                importShowPhotos(initialPhotoURLs)
            }

            requestRootFolderAccessIfNeeded()
        }
        .background(
            WindowAccessor { window in
                ShowGridWindowController.shared.registerIfNeeded(window)
            }
        )
        .onDisappear { removeKeyMonitor() }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            loadDroppedFileURLs(from: providers) { urls in
                // Dragging a single whole folder in opens it exactly like
                // clicking it in the tree would — sets it as the current
                // selection and lets the onChange below load its images,
                // rather than being silently ignored the way a bare
                // folder URL would be by the image-file filter below.
                if urls.count == 1,
                   let droppedFolderURL = urls.first,
                   (try? droppedFolderURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    selectedFolderURL = droppedFolderURL
                    return
                }

                let droppedPhotoURLs = urls.filter { url in
                    UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
                }

                guard !droppedPhotoURLs.isEmpty else {
                    return
                }

                importShowPhotos(droppedPhotoURLs)
            }
        }
        .onChange(of: selectedFolderURL) { newValue in
            guard let newValue else { return }
            loadImages(inFolder: newValue)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 8) {
                // Wordmark on its own row (rather than side-by-side with the
                // theme circles) so it always has the full header width to
                // itself and never gets squeezed into wrapping ("Show"
                // breaking onto its own line) now that the header shares
                // this row with the folder tree next to it.
                HStack(spacing: 0) {
                    Text("Brief")
                        .font(.custom("Unbounded", size: 20).weight(.black))
                        .tracking(-1.7)
                        .foregroundColor(AppColors.wordmarkBright)

                    Text("Show")
                        .font(.custom("Unbounded", size: 20).weight(.black))
                        .tracking(-1.7)
                        .foregroundColor(AppColors.inkSecondary)
                }
                .onHover { hovering in
                    withAnimation(.linear(duration: 0.12)) {
                        isShortcutsHovered = hovering
                    }
                }

                HStack(spacing: 8) {
                    ThemeToggleButton(theme: .white, selected: $themeManager.current)
                    ThemeToggleButton(theme: .buttery, selected: $themeManager.current)
                    ThemeToggleButton(theme: .dark, selected: $themeManager.current)
                }

                if !photoURLs.isEmpty {
                    Text("\(photoURLs.count) photos · \(likedURLs.count) liked")
                        .font(.custom("Figtree", size: 12).weight(.medium))
                        .foregroundColor(AppColors.muted)
                }
            }

            Spacer()

            Button {
                BriefShowWindowController.shared.open(initialPhotoURLs: photoURLs)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "film")
                    Text("Slideshow")
                }
            }
            .buttonStyle(ShowHeaderButtonStyle())
            .padding(.trailing, 10)

            // Opens Develop — a standalone, non-destructive photo editor in
            // its own window (see DevelopWindowController). Entirely
            // separate from this grid and from the slideshow pipeline
            // above: editing a photo here never touches the file on disk
            // and never changes what the slideshow renders.
            Button {
                DevelopWindowController.shared.open(
                    photoURLs: photoURLs,
                    initialSelection: selectedURLs.first ?? photoURLs.first
                )
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "slider.horizontal.3")
                    Text("Develop")
                }
            }
            .buttonStyle(ShowHeaderButtonStyle())
            .opacity(photoURLs.isEmpty ? 0.4 : 1)
            .disabled(photoURLs.isEmpty)
            .padding(.trailing, 14)

            if !photoURLs.isEmpty {
                headerZoomControl
                    .padding(.trailing, 10)

                Button {
                    exportLabeledPhotos()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "square.and.arrow.up")
                        Text("Export Labeled")
                    }
                }
                .buttonStyle(ShowHeaderButtonStyle())
                .opacity(likedURLs.isEmpty ? 0.4 : 1)
                .disabled(likedURLs.isEmpty)
                .padding(.trailing, 10)

                Button {
                    exportStarredPhotos()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "star.fill")
                        Text("Export Starred")
                    }
                }
                .buttonStyle(ShowHeaderButtonStyle())
                .opacity(hasStarredPhotos ? 1 : 0.4)
                .disabled(!hasStarredPhotos)
                .padding(.trailing, 10)

                Button {
                    openPhotoPickerForShow()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus")
                        Text("Add Photos")
                    }
                }
                .buttonStyle(ShowHeaderButtonStyle())
                .padding(.trailing, 10)

                Button {
                    isClearAllConfirmationPresented = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "xmark.circle")
                        Text("Clear All")
                    }
                }
                .buttonStyle(ShowHeaderButtonStyle())
                .opacity(hasLabelsOrRatings ? 1 : 0.4)
                .disabled(!hasLabelsOrRatings)
                .confirmationDialog(
                    "Clear every label and star rating?",
                    isPresented: $isClearAllConfirmationPresented,
                    titleVisibility: .visible
                ) {
                    Button("Clear All", role: .destructive) {
                        clearAllLabelsAndRatings()
                    }
                } message: {
                    Text("This removes the liked label and star rating from every photo. It doesn't touch the photo files themselves.")
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }

    private var hasStarredPhotos: Bool {
        ratings.values.contains { $0 > 0 }
    }

    private var hasLabelsOrRatings: Bool {
        !likedURLs.isEmpty || hasStarredPhotos
    }

    private var currentYear: Int {
        Calendar.current.component(.year, from: Date())
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "5.0"
    }

    // MARK: Footer

    // The RocketsBrief / Support / Fund Mission / Disclaimer links (with
    // their hover info cards) used to only live on the Welcome screen —
    // now that ShowGrid is the app's first screen, they're kept reachable
    // here instead of being lost. Hover cards open UPWARD (negative y
    // offset) since this bar sits at the bottom of the window, unlike the
    // Welcome screen's version of this row which opened them downward.
    private var showGridFooter: some View {
        HStack(spacing: 16) {
            Text("© \(String(currentYear)) RocketsBrief")
                .font(.custom("Figtree", size: 11).weight(.medium))
                .tracking(0.4)
                .foregroundColor(AppColors.muted.opacity(0.55))

            Text("v\(appVersion)")
                .font(.custom("Figtree", size: 11).weight(.medium))
                .tracking(0.4)
                .foregroundColor(AppColors.muted.opacity(0.4))

            Spacer()

            Button {
                if let url = URL(string: "https://www.rocketsbrief.com") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                HStack(spacing: 6) {
                    Image("RocketsBriefButtonLogo")
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 13, height: 13)

                    Text("RocketsBrief")
                }
                .frame(height: 13)
            }
            .buttonStyle(HeaderLinkButtonStyle())
            .overlay(alignment: .bottomTrailing) {
                if isRocketsBriefHovered {
                    RocketsBriefHoverCard()
                        .offset(x: 0, y: -44)
                        .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .bottomTrailing)))
                        .zIndex(300)
                }
            }
            .onHover { hovering in
                withAnimation(.linear(duration: 0.12)) {
                    isRocketsBriefHovered = hovering
                }
            }

            Button {
                if let url = URL(string: "https://www.rocketsbrief.com/support") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "bubble.left.and.bubble.right.fill")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 13, height: 13)

                    Text("Support")
                }
                .frame(height: 13)
            }
            .buttonStyle(HeaderLinkButtonStyle())
            .overlay(alignment: .bottomTrailing) {
                if isSupportHovered {
                    SupportHoverCard()
                        .offset(x: 0, y: -44)
                        .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .bottomTrailing)))
                        .zIndex(300)
                }
            }
            .onHover { hovering in
                withAnimation(.linear(duration: 0.12)) {
                    isSupportHovered = hovering
                }
            }

            Button {
                if let url = URL(string: "https://www.paypal.com/ncp/payment/GUZARDB67QEDU#checkoutModal") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Text("Fund Mission")
                    .frame(height: 13)
            }
            .buttonStyle(HeaderLinkButtonStyle())
            .overlay(alignment: .bottomTrailing) {
                if isFundMissionHovered {
                    FundMissionHoverCard()
                        .offset(x: 0, y: -44)
                        .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .bottomTrailing)))
                        .zIndex(300)
                }
            }
            .onHover { hovering in
                withAnimation(.linear(duration: 0.12)) {
                    isFundMissionHovered = hovering
                }
            }

            Button {
                isDisclaimerNoticePresented = true
            } label: {
                Text("Disclaimer")
                    .frame(height: 13)
            }
            .buttonStyle(HeaderLinkButtonStyle())
            .overlay(alignment: .bottomTrailing) {
                if isDisclaimerHovered {
                    DisclaimerHoverCard()
                        .offset(x: 0, y: -44)
                        .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .bottomTrailing)))
                        .zIndex(300)
                }
            }
            .onHover { hovering in
                withAnimation(.linear(duration: 0.12)) {
                    isDisclaimerHovered = hovering
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(AppColors.background)
        .overlay(Divider(), alignment: .top)
        .zIndex(300)
    }

    // MARK: Loading indicator

    // Small pinned HUD, bottom-trailing, so it never covers the header
    // buttons or the folder tree — just confirms photos are actively being
    // loaded, with a running count once photoURLs is known.
    private var loadingIndicator: some View {
        VStack {
            Spacer()

            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)

                Text(
                    photoURLs.isEmpty
                        ? "Loading images…"
                        : "Loading images… \(loadedThumbnailCount)/\(photoURLs.count)"
                )
                .font(.custom("Figtree", size: 12.5).weight(.medium))
                .foregroundColor(AppColors.ink)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(AppColors.background)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(AppColors.border.opacity(0.6), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.25), radius: 14, y: 4)
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 40))
                .foregroundColor(AppColors.muted.opacity(0.7))

            Text(
                rootFolderNode == nil
                    ? "Import photos to review and mark your favorites."
                    : "Pick a folder on the left, or import photos to review and mark your favorites."
            )
                .font(.custom("Figtree", size: 14).weight(.medium))
                .foregroundColor(AppColors.muted)
                .multilineTextAlignment(.center)

            Button {
                openPhotoPickerForShow()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                    Text("Import Photos")
                }
            }
            .buttonStyle(ShowHeaderButtonStyle())

            // Manual fallback for the automatic grant attempt in .onAppear
            // (see requestRootFolderAccessIfNeeded): that one fires the
            // moment the window appears, and on some Macs the modal
            // NSOpenPanel it presents can silently fail to show if the
            // window hasn't finished becoming key yet — no error, no log,
            // the client just never sees a prompt and the sidebar never
            // shows up. A button click is always on an already-key window,
            // so it can't hit that race — this reliably (re)triggers the
            // same grant flow on demand instead of leaving a client with
            // no folder tree and no way to ask for one again short of us
            // walking them through Terminal commands.
            if rootFolderNode == nil {
                Button {
                    requestRootFolderAccessIfNeeded()
                } label: {
                    Text("Grant Folder Access")
                }
                .buttonStyle(ShowHeaderButtonStyle())
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .contextMenu {
            gridBackgroundContextMenuItems
        }
    }

    // Requests the home-folder grant that powers the left folder tree
    // (see RootFolderAccess above). Deferred one runloop tick and
    // preceded by an explicit app/window activation: NSOpenPanel.runModal()
    // is an app-modal panel, and calling it synchronously from `.onAppear`
    // — i.e. mid-layout, before this window has actually become key — can
    // make it silently fail to appear on some Macs instead of showing.
    // There's no error or log in that case; RootFolderAccess.resolve()
    // just returns nil, indistinguishable from the client having clicked
    // Cancel. Activating first and giving SwiftUI a tick to finish
    // installing the window closes that race.
    private func requestRootFolderAccessIfNeeded() {
        guard rootFolderNode == nil else { return }

        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)

            if let homeURL = RootFolderAccess.resolve() {
                rootFolderNode = FolderNode(url: homeURL)
            }
        }
    }

    // MARK: Grid

    private var thumbnailGrid: some View {
        ScrollViewReader { proxy in
            ScrollView {
                FlowLayout(spacing: 16, lineSpacing: 26) {
                    ForEach(photoURLs, id: \.self) { url in
                        thumbnailCell(for: url)
                            .id(url)
                    }
                }
                .padding(24)
                .padding(.bottom, 70)
                // Stretched to the full scroll width (rather than just
                // hugging the flowed thumbnails), so there's no dead strip
                // down the right edge that the ScrollView won't scroll on.
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            // On the ScrollView itself, not a background layer behind it —
            // a ScrollView claims hit-testing for its ENTIRE frame (that's
            // how it can start a scroll-drag from anywhere in it, not just
            // over its content), so a separate "Paste" layer underneath it
            // never actually received right-clicks; every click inside the
            // grid's bounds stopped at the ScrollView first. A thumbnail's
            // own .contextMenu, being on a more specific child view, still
            // wins over this one when the click lands on a photo.
            .contextMenu {
                gridBackgroundContextMenuItems
            }
            // Keeps arrow-key navigation's new selection on screen even
            // when it lands outside the currently scrolled area.
            .onChange(of: scrollToPhotoURL) { newValue in
                guard let newValue else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
        }
    }

    // Every thumbnail shares the same HEIGHT (driven by the zoom slider);
    // width follows the photo's own aspect ratio instead of being force-
    // cropped to a square, so landscape photos read wider and portrait
    // photos read narrower, side by side in the same flowing row.
    private func thumbnailCell(for url: URL) -> some View {
        let isSelected = selectedURLs.contains(url)
        // Only the first 5 selected (the ones the Space loupe will
        // actually preview) get the yellow border; the 6th+ still show as
        // selected, just with a plain white border instead, so it's clear
        // they won't be part of the preview.
        let isPreviewSelected = previewSelectedURLs.contains(url)
        let selectionBorderColor: Color = isPreviewSelected ? accentColor : .white
        let image = gridThumbnails[url]
        let aspectRatio = image.map { max(0.2, $0.size.width / max(1, $0.size.height)) } ?? (4.0 / 3.0)
        let cellWidth = thumbnailSize * aspectRatio

        return VStack(spacing: 10) {
            ZStack {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: cellWidth, height: thumbnailSize)
                } else {
                    Rectangle()
                        .fill(AppColors.panel)
                        .frame(width: cellWidth, height: thumbnailSize)
                        .overlay(ProgressView().controlSize(.small))
                }
            }
            .frame(width: cellWidth, height: thumbnailSize)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? selectionBorderColor : AppColors.border.opacity(0.6), lineWidth: isSelected ? 3 : 1)
            )
            .shadow(color: isSelected ? selectionBorderColor.opacity(0.35) : .clear, radius: isSelected ? 10 : 0)
            .contentShape(Rectangle())
            // Double-tap gesture attached BEFORE the single-tap one below —
            // that ordering is what lets SwiftUI tell the two apart (a
            // single click waits briefly to see if a second one follows
            // before firing handleSelectTap). Opens straight into Develop
            // on this exact photo, same window/call DevelopWindowController
            // already uses for the header's own "Develop" button.
            .onTapGesture(count: 2) {
                DevelopWindowController.shared.open(photoURLs: photoURLs, initialSelection: url)
            }
            .onTapGesture {
                handleSelectTap(url)
            }
            .contextMenu {
                photoContextMenuItems(for: url)
            }
            .animation(.easeOut(duration: 0.12), value: isSelected)

            HStack(spacing: 0) {
                starRating(for: url)

                Spacer(minLength: 8)

                likeToggle(for: url)
                    .padding(.trailing, 12)
            }
            .frame(width: cellWidth)
        }
    }

    // Right-click menu on a grid thumbnail. Acts on the whole current
    // selection when the client right-clicks a photo that's already part
    // of a multi-selection (matching the Cmd-click multi-select above it),
    // or just the one photo under the pointer otherwise.
    @ViewBuilder
    private func photoContextMenuItems(for url: URL) -> some View {
        let targets = (selectedURLs.contains(url) && selectedURLs.count > 1)
            ? photoURLs.filter { selectedURLs.contains($0) }
            : [url]

        Button("Copy") {
            writeURLsToPasteboard(targets)
            clipboardURLs = targets
            clipboardIsCut = false
        }

        // Also sets BriefShow's own in-app clipboard (see clipboardURLs)
        // so "Paste" on a folder in the sidebar actually moves these files
        // there. The NSPasteboard write alongside it is only good for
        // Copy-style behavior once it leaves BriefShow — pasting into
        // Finder will always copy, never move, since a genuine cross-app
        // "cut" isn't something a third-party app can trigger through
        // public API; that bookkeeping is private to Finder's own
        // window-to-window moves.
        Button("Cut") {
            writeURLsToPasteboard(targets)
            clipboardURLs = targets
            clipboardIsCut = true
        }

        Divider()

        Button("Add to Bin", role: .destructive) {
            pendingTrashPhotoURLs = targets
            isTrashPhotoConfirmationPresented = true
        }
    }

    // Right-click on empty grid space (rather than on a specific
    // thumbnail) — the only useful action there is Paste.
    @ViewBuilder
    private var gridBackgroundContextMenuItems: some View {
        Group {
            // Only offered when a real folder is open — photos brought in
            // loose (Add Photos / drag-and-drop, nothing selected in the
            // sidebar) have no folder on disk to create this inside.
            if let selectedFolderURL {
                Button("New Folder") {
                    createNewFolder(in: selectedFolderURL)
                }

                Divider()
            }

            Button("Paste") {
                pasteIntoGrid()
            }
            .disabled(pasteboardFileURLs().isEmpty)
        }
    }

    // Up to 5 stars a client can click to rate a photo, independent of the
    // liked/labeled circle. Clicking the star that already matches the
    // current rating clears it back to 0, the standard star-rating toggle.
    private func starRating(for url: URL) -> some View {
        let rating = ratings[url] ?? 0

        return HStack(spacing: 3) {
            ForEach(1...maxRatingStars, id: \.self) { index in
                let isFilled = index <= rating

                Image(systemName: isFilled ? "star.fill" : "star")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isFilled ? accentColor : accentColor.opacity(0.55))
                    .shadow(color: isFilled ? accentColor.opacity(0.9) : .clear, radius: isFilled ? 3 : 0)
                    .contentShape(Rectangle().inset(by: -4))
                    .onTapGesture {
                        setRating(index, for: url)
                    }
            }
        }
        .animation(.easeOut(duration: 0.15), value: rating)
    }

    // A filled, glowing circle marks a liked photo; an empty outline
    // circle marks an unliked one. Independent of selection (the border
    // drawn around the thumbnail itself above) — both follow the current
    // theme's accent color (light yellow in Dark, gray in White/Buttery).
    private func likeToggle(for url: URL) -> some View {
        let isLiked = likedURLs.contains(url)

        return Circle()
            .fill(isLiked ? accentColor : Color.clear)
            .overlay(
                Circle()
                    .stroke(accentColor.opacity(isLiked ? 0 : 0.55), lineWidth: 1.5)
            )
            .frame(width: 15, height: 15)
            .shadow(color: isLiked ? accentColor.opacity(0.95) : .clear, radius: isLiked ? 3 : 0)
            .shadow(color: isLiked ? accentColor.opacity(0.55) : .clear, radius: isLiked ? 7 : 0)
            .contentShape(Circle().inset(by: -8))
            .onTapGesture {
                toggleLike(url)
            }
            .animation(.easeOut(duration: 0.15), value: isLiked)
    }

    // MARK: Zoom control

    // Lives in the header itself (top-right, before Export Labeled/Add
    // Photos) rather than pinned to the bottom of the screen — the bottom
    // edge of this window can end up past the visible screen area, making
    // a bottom-pinned control unreachable.
    private var headerZoomControl: some View {
        HStack(spacing: 10) {
            Image(systemName: "photo")
                .font(.system(size: 10))
                .foregroundColor(AppColors.muted)

            Slider(value: $thumbnailSize, in: minThumbnailSize...maxThumbnailSize)
                .frame(width: 110)

            Image(systemName: "photo.fill")
                .font(.system(size: 15))
                .foregroundColor(AppColors.muted)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: Loupe (enlarged multi-select preview)

    private func loupeOverlay(for urls: [URL]) -> some View {
        ZStack {
            Color.black.opacity(0.98)
                .ignoresSafeArea()
                .onTapGesture {
                    closeLoupe()
                }

            loupeGrid(for: urls)
                .padding(50)

            VStack {
                HStack {
                    Spacer()

                    Button {
                        closeLoupe()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 34, height: 34)
                            .background(Color.white.opacity(0.12))
                            .overlay(
                                RoundedRectangle(cornerRadius: 999)
                                    .stroke(Color.white.opacity(0.4), lineWidth: 1.5)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 999))
                    }
                    .buttonStyle(.plain)
                    .padding(24)
                }

                Spacer()
            }

            // "N Stars" confirmation for the 1-5 rating keys — see
            // showRatingToast. Non-interactive and pinned near the bottom
            // so it never sits on top of the photo itself.
            if let ratingToastText {
                VStack {
                    Spacer()

                    Text(ratingToastText)
                        .font(.custom("Figtree", size: 14).weight(.semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background(
                            Capsule().fill(Color.white.opacity(0.16))
                        )
                        .overlay(
                            Capsule().stroke(Color.white.opacity(0.4), lineWidth: 1.5)
                        )
                        .padding(.bottom, 40)
                }
                .allowsHitTesting(false)
                .transition(.opacity)
                .zIndex(2)
            }
        }
        .transition(.opacity)
        .zIndex(1)
    }

    // Arranges 1-5 selected photos as a proper contact-sheet layout instead
    // of squeezing them into a single row: 1-2 photos stay in one row, 3+
    // split into two rows with the smaller half on top (3 → 1 over 2,
    // 4 → 2 over 2, 5 → 2 over 3), each photo scaled to fit its own cell
    // at its natural aspect ratio.
    private func loupeGrid(for urls: [URL]) -> some View {
        GeometryReader { proxy in
            let rows = loupeRows(for: urls)
            let rowSpacing: CGFloat = 18
            let rowHeight = (proxy.size.height - rowSpacing * CGFloat(max(0, rows.count - 1)))
                / CGFloat(max(1, rows.count))

            VStack(spacing: rowSpacing) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, rowURLs in
                    HStack(spacing: 18) {
                        ForEach(rowURLs, id: \.self) { url in
                            loupeImageView(for: url)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .frame(height: rowHeight)
                }
            }
        }
    }

    private func loupeRows(for urls: [URL]) -> [[URL]] {
        guard urls.count > 2 else {
            return [urls]
        }

        let topCount = urls.count / 2
        return [Array(urls.prefix(topCount)), Array(urls.suffix(urls.count - topCount))]
    }

    // Clicking an enlarged photo here toggles its liked label directly,
    // same as clicking its circle back in the grid — a yellow border plus
    // a filled corner badge confirms the state at this larger size.
    private func loupeImageView(for url: URL) -> some View {
        let isLiked = likedURLs.contains(url)

        return ZStack {
            if let image = loupeImages[url] ?? gridThumbnails[url] {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                ProgressView()
                    .tint(.white)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(isLiked ? accentColor : Color.clear, lineWidth: 4)
        )
        .shadow(color: isLiked ? accentColor.opacity(0.5) : .clear, radius: isLiked ? 14 : 0)
        .overlay(alignment: .topLeading) {
            if isLiked {
                Circle()
                    .fill(accentColor)
                    .frame(width: 22, height: 22)
                    .shadow(color: accentColor.opacity(0.9), radius: 5)
                    .padding(12)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            toggleLike(url)
        }
        .animation(.easeOut(duration: 0.15), value: isLiked)
    }

    private func closeLoupe() {
        withAnimation(.easeOut(duration: 0.15)) {
            loupeURLs = nil
        }

        // So a stale "N Stars" doesn't flash back up if the loupe is
        // reopened before its own fade-out timer would've cleared it.
        ratingToastDismissWorkItem?.cancel()
        ratingToastText = nil
    }

    // MARK: Selection / like state

    // A plain click selects only that photo; Cmd-click toggles it in/out of
    // the multi-selection, matching the Adobe Bridge convention the client
    // asked for. The selection itself has no size limit — only the first 5
    // selected actually preview when Space is pressed (see
    // previewSelectedURLs), so selecting a 6th+ photo still works, it just
    // shows a white border instead of yellow in the grid.
    //
    // Reads the modifier flags off NSApp.currentEvent (the actual click
    // that triggered this) rather than the live NSEvent.modifierFlags
    // snapshot — the latter reflects whatever the hardware state happens
    // to be at the instant this line runs, which can still read Cmd as
    // held for a moment right after releasing it from a previous Cmd-click,
    // making a plain click on an already-selected photo silently fall into
    // the Cmd-click (toggle-out) branch instead of replacing the selection.
    private func handleSelectTap(_ url: URL) {
        let isCommandDown = NSApp.currentEvent?.modifierFlags.contains(.command) ?? false

        if isCommandDown {
            toggleSelection(url)
        } else {
            replaceSelection(with: [url])
        }
    }

    // The only three ways `selectedURLs` ever changes — routed through
    // here so `selectionOrder` (which tracks the first-5-selected for the
    // Space preview / yellow border) never drifts out of sync with it.
    private func replaceSelection(with urls: [URL]) {
        selectedURLs = Set(urls)
        selectionOrder = urls
    }

    private func toggleSelection(_ url: URL) {
        if selectedURLs.contains(url) {
            selectedURLs.remove(url)
            selectionOrder.removeAll { $0 == url }
        } else {
            selectedURLs.insert(url)
            selectionOrder.append(url)
        }
    }

    private func removeFromSelection(_ urls: Set<URL>) {
        selectedURLs.subtract(urls)
        selectionOrder.removeAll { urls.contains($0) }
    }

    private func toggleLike(_ url: URL) {
        if likedURLs.contains(url) {
            likedURLs.remove(url)
        } else {
            likedURLs.insert(url)
        }
        persistLabel(for: url)
    }

    private func setRating(_ rating: Int, for url: URL) {
        ratings[url] = (ratings[url] == rating) ? 0 : rating
        persistLabel(for: url)
    }

    // Shows "N Stars" over the loupe for a beat, then fades it back out —
    // takes the ACTUAL resulting rating (not just the key that was
    // pressed) since setRating toggles a rating off back to 0 when the
    // same key is pressed again, and the toast should say what happened,
    // not just repeat the keypress.
    private func showRatingToast(resultingIn appliedRating: Int) {
        let text = appliedRating == 0
            ? "Rating Cleared"
            : (appliedRating == 1 ? "1 Star" : "\(appliedRating) Stars")

        ratingToastDismissWorkItem?.cancel()

        withAnimation(.easeOut(duration: 0.12)) {
            ratingToastText = text
        }

        let dismissWorkItem = DispatchWorkItem {
            withAnimation(.easeOut(duration: 0.25)) {
                ratingToastText = nil
            }
        }
        ratingToastDismissWorkItem = dismissWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: dismissWorkItem)
    }

    private func clearAllLabelsAndRatings() {
        for url in photoURLs {
            PhotoLabelStore.clear(for: url)
        }
        likedURLs.removeAll()
        ratings.removeAll()
    }

    // Writes this one photo's current liked/rating state to the persisted
    // store (see PhotoLabelStore) right after a toggle, so a label survives
    // quitting BriefShow, and also shows up again on a copy of the same
    // file exported to a different folder.
    private func persistLabel(for url: URL) {
        PhotoLabelStore.setLiked(likedURLs.contains(url), for: url)
        PhotoLabelStore.setRating(ratings[url] ?? 0, for: url)
    }

    // MARK: Trash (right-click "Add to Bin")

    // Moves every URL to the macOS Trash (recoverable from there, same as
    // Finder's "Move to Trash") and drops it from every bit of in-memory
    // state that references it, so it disappears from the grid immediately
    // instead of leaving a broken thumbnail behind.
    private func trashPhotos(_ urls: [URL]) {
        let fileManager = FileManager.default

        for url in urls {
            try? fileManager.trashItem(at: url, resultingItemURL: nil)
            PhotoLabelStore.clear(for: url)
        }

        let trashedSet = Set(urls)
        photoURLs.removeAll { trashedSet.contains($0) }
        removeFromSelection(trashedSet)

        for url in urls {
            gridThumbnails.removeValue(forKey: url)
            loupeImages.removeValue(forKey: url)
            likedURLs.remove(url)
            ratings.removeValue(forKey: url)
        }
    }

    // Called from FolderTreeSidebar's "Add to Bin" — routed back through a
    // confirmation dialog here (rather than trashing immediately) since a
    // folder can hold a lot more than a single accidental click should be
    // able to remove.
    private func requestTrashFolder(_ node: FolderNode) {
        pendingTrashFolderNode = node
        isTrashFolderConfirmationPresented = true
    }

    private func trashFolder(_ node: FolderNode) {
        try? FileManager.default.trashItem(at: node.url, resultingItemURL: nil)

        // The trashed folder can't be browsed anymore, so if it was the one
        // open in the grid, clear the grid rather than leave it showing
        // photos that no longer exist at that path.
        if selectedFolderURL == node.url {
            selectedFolderURL = nil
            photoURLs = []
            likedURLs = []
            ratings = [:]
        }

        refreshFolderTree()
    }

    // MARK: New Folder (right-click "New Folder" on a sidebar folder,
    // including the root row, or on empty grid space)

    // Names it "New Folder", falling back to "New Folder 2", "New Folder
    // 3", ... on a collision — the same numbered-suffix handling
    // pasteClipboard uses for a same-named file. Immediately selects the
    // new folder (which also expands the sidebar tree down to it — see
    // expandPathToSelection) and opens it in the grid, so it shows up
    // right where the client right-clicked, the same instant feedback
    // Finder gives.
    private func createNewFolder(in parentFolder: URL) {
        let fileManager = FileManager.default
        var candidateURL = parentFolder.appendingPathComponent("New Folder")
        var suffix = 2
        while fileManager.fileExists(atPath: candidateURL.path) {
            candidateURL = parentFolder.appendingPathComponent("New Folder \(suffix)")
            suffix += 1
        }

        guard (try? fileManager.createDirectory(at: candidateURL, withIntermediateDirectories: false)) != nil else {
            return
        }

        refreshFolderTree()
        selectedFolderURL = candidateURL
        loadImages(inFolder: candidateURL)
    }

    // MARK: Paste (right-click "Paste" on a sidebar folder or empty grid space)

    // What Paste actually reads — every file URL currently sitting on the
    // system pasteboard, not just what BriefShow's own Copy/Cut put there.
    // That's the whole fix for Paste "not working": three photos Cmd-C'd
    // in Finder land here exactly the same as three photos Copied inside
    // BriefShow, because both write to the same NSPasteboard.general.
    private func pasteboardFileURLs() -> [URL] {
        let urls = (NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]) ?? []
        return urls.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    // True only when the pasteboard still holds exactly what BriefShow's
    // own last Cut put there — i.e. it's safe to actually move these files
    // rather than copy them. Without this check, cutting inside BriefShow
    // and then separately Copying something in Finder (without ever
    // pasting the cut) could otherwise leave a stale "this was a cut" flag
    // that deletes files the client only ever meant to copy.
    private var isPasteboardOurCut: Bool {
        clipboardIsCut && Set(pasteboardFileURLs()) == Set(clipboardURLs)
    }

    // Right-click Paste on empty grid space. When a folder from the
    // sidebar is open, this is a real folder on disk — paste writes the
    // file(s) into it, same as pasteClipboard(into:) below. Without one
    // (photos brought in loose, via Add Photos or drag-and-drop, with
    // nothing in the sidebar even shown), there's no folder to write into
    // on disk, so this just adds the pasted photos to the review set
    // directly, the same way Add Photos/drag-and-drop already do.
    private func pasteIntoGrid() {
        let urls = pasteboardFileURLs()
        guard !urls.isEmpty else {
            return
        }

        if let selectedFolderURL {
            pasteClipboard(into: selectedFolderURL)
            return
        }

        let imageURLs = urls.filter { url in
            UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
        }
        guard !imageURLs.isEmpty else {
            return
        }

        importShowPhotos(imageURLs)
    }

    // Copies (or, for a Cut still sitting on the pasteboard, actually
    // moves) whatever Paste found into destinationFolder. Because both
    // ends of a BriefShow-to-BriefShow paste are inside BriefShow, Cut can
    // do a real move here — unlike pasting into Finder via the system
    // pasteboard (see writeURLsToPasteboard), where there's no way to tell
    // Finder "this one should move, not copy."
    private func pasteClipboard(into destinationFolder: URL) {
        let sourceURLs = pasteboardFileURLs()
        guard !sourceURLs.isEmpty else {
            return
        }

        let isMove = isPasteboardOurCut
        let fileManager = FileManager.default

        var movedAwayURLs: [URL] = []
        var movedAwaySelectedFolder = false

        for sourceURL in sourceURLs {
            // Pasting a cut item back into the folder it's already in is a
            // no-op — skip it rather than let moveItem fail trying to move
            // something onto itself.
            if isMove, sourceURL.deletingLastPathComponent().standardizedFileURL == destinationFolder.standardizedFileURL {
                continue
            }

            var destinationURL = destinationFolder.appendingPathComponent(sourceURL.lastPathComponent)
            if fileManager.fileExists(atPath: destinationURL.path) {
                let baseName = sourceURL.deletingPathExtension().lastPathComponent
                let fileExtension = sourceURL.pathExtension
                var duplicateSuffix = 1
                while fileManager.fileExists(atPath: destinationURL.path) {
                    let candidateName = fileExtension.isEmpty
                        ? "\(baseName) \(duplicateSuffix)"
                        : "\(baseName) \(duplicateSuffix).\(fileExtension)"
                    destinationURL = destinationFolder.appendingPathComponent(candidateName)
                    duplicateSuffix += 1
                }
            }

            if isMove {
                guard (try? fileManager.moveItem(at: sourceURL, to: destinationURL)) != nil else {
                    continue
                }
                movedAwayURLs.append(sourceURL)
                if sourceURL == selectedFolderURL {
                    movedAwaySelectedFolder = true
                }
            } else {
                try? fileManager.copyItem(at: sourceURL, to: destinationURL)
            }
        }

        // A cut clipboard is consumed by its first paste, same as Finder —
        // pasting again would just fail since the originals are gone. A
        // copied clipboard stays put so it can be pasted into several
        // folders in a row.
        if isMove {
            clipboardURLs = []
            clipboardIsCut = false
        }

        if !movedAwayURLs.isEmpty {
            let movedSet = Set(movedAwayURLs)
            photoURLs.removeAll { movedSet.contains($0) }
            removeFromSelection(movedSet)
            for url in movedAwayURLs {
                gridThumbnails.removeValue(forKey: url)
                loupeImages.removeValue(forKey: url)
            }
        }

        refreshFolderTree()

        if movedAwaySelectedFolder {
            // The folder that was open in the grid just moved out from
            // under it — nothing left at that path to show.
            selectedFolderURL = nil
            photoURLs = []
            likedURLs = []
            ratings = [:]
        } else if selectedFolderURL == destinationFolder {
            // Client is currently looking at the folder just pasted into —
            // reload it so the new item(s) show up immediately instead of
            // only appearing the next time this folder is clicked.
            loadImages(inFolder: destinationFolder)
        }
    }

    // MARK: Keyboard (Space opens/closes the loupe, Escape closes it)

    // No existing keyboard-monitor pattern elsewhere in the app (every
    // other shortcut is a SwiftUI `.keyboardShortcut` on a specific
    // button), so this is a fresh local NSEvent monitor, installed only
    // while this screen is on screen and removed on disappear.
    private func installKeyMonitor() {
        guard keyMonitor == nil else {
            return
        }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Scoped to only fire while THIS (ShowGrid/"BriefShow") window
            // is key — local NSEvent monitors are app-wide, not per-window,
            // so without this check these shortcuts also fired while the
            // separate "Develop" window was frontmost (same reasoning as
            // Develop.swift's own installEditingKeyMonitor, which already
            // guards the other direction). That was a real, serious bug,
            // not just a theoretical one: Develop has its OWN Cmd+C/X/V for
            // its Selection tool's in-memory layer clipboard, but with no
            // guard here, THIS monitor fired at the same time and — since
            // nothing is ever selected in the (hidden, backgrounded)
            // ShowGrid grid while Develop is open — its copyCutTargets
            // fallback grabbed the ENTIRE currently open folder, and a
            // follow-up Cmd+V recursively copied that whole folder via
            // pasteClipboard(into:). Observed firsthand this session: the
            // app hammered clonefileat/mkdir/chmod at 80%+ CPU for minutes
            // and had to be force-quit — from a client just trying to
            // cut/copy a Selection inside Develop, never touching ShowGrid
            // at all.
            guard NSApp.keyWindow?.title == "BriefShow" else {
                return event
            }
            let spaceKeyCode: UInt16 = 49
            let escapeKeyCode: UInt16 = 53
            let character = event.charactersIgnoringModifiers?.lowercased()
            let isCommandDown = event.modifierFlags.contains(.command)

            // Cmd-C/Cmd-X/Cmd-V — the standard Copy/Cut/Paste shortcuts,
            // matching the right-click "Copy"/"Cut"/"Paste" menu items
            // exactly (same writeURLsToPasteboard/clipboardURLs/
            // pasteIntoGrid calls those use). Handled before every
            // Cmd-less shortcut below that happens to share the same
            // letter ("x" toggles a like, "v" clears all) — without the
            // isCommandDown check here, charactersIgnoringModifiers gives
            // back that same lowercase letter for the Cmd-held version too,
            // so Cmd-X was silently toggling a like instead of cutting, and
            // Cmd-V was silently popping the Clear-All confirmation instead
            // of pasting.
            //
            // !event.isARepeat matters here specifically for "v": without
            // it, holding Cmd+V for even a moment past the OS's key-repeat
            // threshold fires pasteIntoGrid() on every repeated keyDown —
            // and when nothing is selected, its copy/cut target falls back
            // to the WHOLE currently open folder (see copyCutTargets
            // below), so each repeat kicks off another full recursive
            // folder copy. This is the exact same class of bug as
            // Develop.swift's documented Cmd+V freeze (BRIEFSHOW_DEVELOP_
            // NOTES.md #15) — same missing guard, different key monitor —
            // observed firsthand this session (sustained 60-80% CPU
            // hammering clonefileat/mkdir/chmod for minutes after a single
            // Cmd+V, required force-quitting the app).
            if isCommandDown, let character, !event.isARepeat {
                // In the loupe, Copy/Cut act on whatever's being previewed;
                // back in the grid, on the current selection; with nothing
                // selected there, on the folder currently open — the same
                // "selection, else the open folder" fallback the grid's
                // own right-click Paste-target logic uses.
                let copyCutTargets: [URL]? = {
                    if let loupeURLs, !loupeURLs.isEmpty {
                        return loupeURLs
                    }
                    if !selectedURLs.isEmpty {
                        return photoURLs.filter { selectedURLs.contains($0) }
                    }
                    if let selectedFolderURL {
                        return [selectedFolderURL]
                    }
                    return nil
                }()

                if character == "c", let copyCutTargets {
                    writeURLsToPasteboard(copyCutTargets)
                    clipboardURLs = copyCutTargets
                    clipboardIsCut = false
                    return nil
                }

                if character == "x", let copyCutTargets {
                    writeURLsToPasteboard(copyCutTargets)
                    clipboardURLs = copyCutTargets
                    clipboardIsCut = true
                    return nil
                }

                if character == "v" {
                    pasteIntoGrid()
                    return nil
                }

                // Cmd-A selects every photo currently in the grid at once
                // (Finder/Photos convention) — only back in the grid itself,
                // not while the loupe is open (there's nothing to "select
                // all" inside a single-photo preview) and only when there's
                // at least one photo to select.
                if character == "a", loupeURLs == nil, !photoURLs.isEmpty {
                    replaceSelection(with: photoURLs)
                    return nil
                }
            }

            // "c" closes the loupe, same as Space/Escape — checked first
            // since it applies only while the loupe is open.
            if !isCommandDown, loupeURLs != nil, character == "c" {
                closeLoupe()
                return nil
            }

            let leftArrowKeyCode: UInt16 = 123
            let rightArrowKeyCode: UInt16 = 124
            let downArrowKeyCode: UInt16 = 125
            let upArrowKeyCode: UInt16 = 126
            let previousKeyCodes: Set<UInt16> = [leftArrowKeyCode, upArrowKeyCode]
            let nextKeyCodes: Set<UInt16> = [rightArrowKeyCode, downArrowKeyCode]

            // All four arrows step to the previous/next photo in the
            // current order (Left/Up back, Right/Down forward) — in the
            // loupe while it's showing a single photo, or back in the grid
            // while at most one photo is selected. The grid isn't a fixed
            // row/column layout (thumbnails flow at their own aspect
            // ratio), so Up/Down can't map to "the photo above/below" the
            // way they would in Finder's icon view — they instead move
            // through the photos the same one-at-a-time way Left/Right do.
            // Previously the only way to move to another photo was
            // clicking it with the mouse.
            if previousKeyCodes.contains(event.keyCode) || nextKeyCodes.contains(event.keyCode), !photoURLs.isEmpty {
                let direction = nextKeyCodes.contains(event.keyCode) ? 1 : -1

                if let loupeURLs, loupeURLs.count == 1 {
                    if let currentIndex = photoURLs.firstIndex(of: loupeURLs[0]) {
                        let newIndex = min(max(currentIndex + direction, 0), photoURLs.count - 1)
                        let newURL = photoURLs[newIndex]
                        replaceSelection(with: [newURL])
                        openLoupe(for: [newURL])
                    }
                    return nil
                }

                if loupeURLs == nil, selectedURLs.count <= 1 {
                    let currentIndex = selectedURLs.first.flatMap { photoURLs.firstIndex(of: $0) }
                    let newIndex: Int
                    if let currentIndex {
                        newIndex = min(max(currentIndex + direction, 0), photoURLs.count - 1)
                    } else {
                        newIndex = direction > 0 ? 0 : photoURLs.count - 1
                    }
                    let newURL = photoURLs[newIndex]
                    replaceSelection(with: [newURL])
                    scrollToPhotoURL = newURL
                    return nil
                }
            }

            // "1"-"5" sets that many stars — on every photo currently open
            // in the loupe if it's showing one, otherwise on the grid
            // selection. Unlike the label/clear-all shortcuts below, this
            // one is NOT restricted to loupeURLs == nil: reviewing a photo
            // enlarged is exactly when a client wants to rate it, and
            // there's no star row to click at all inside the loupe itself.
            let ratingTargets: [URL] = {
                if let loupeURLs, !loupeURLs.isEmpty {
                    return loupeURLs
                }
                return photoURLs.filter { selectedURLs.contains($0) }
            }()

            if !isCommandDown,
               !ratingTargets.isEmpty,
               let character,
               let rating = Int(character),
               (1...maxRatingStars).contains(rating) {
                for url in ratingTargets {
                    setRating(rating, for: url)
                }
                if loupeURLs != nil, let firstTarget = ratingTargets.first {
                    showRatingToast(resultingIn: ratings[firstTarget] ?? 0)
                }
                return nil
            }

            // The rest of the shortcuts (label toggle, clear all) only
            // apply back in the grid, not while previewing.
            if loupeURLs == nil {
                // "x" toggles the liked label on every currently selected
                // photo (same per-photo toggle as clicking its circle) —
                // checked by character rather than key code so it still
                // works under non-US keyboard layouts.
                if !isCommandDown, !selectedURLs.isEmpty, character == "x" {
                    for url in selectedURLs {
                        toggleLike(url)
                    }
                    return nil
                }

                // "v" clears every label and star rating, same as the
                // "Clear All" header button — still asks for confirmation
                // since it's a bulk, all-photos action.
                if !isCommandDown, character == "v", hasLabelsOrRatings {
                    isClearAllConfirmationPresented = true
                    return nil
                }
            }

            guard event.keyCode == spaceKeyCode || event.keyCode == escapeKeyCode else {
                return event
            }

            if loupeURLs != nil {
                closeLoupe()
                return nil
            }

            guard event.keyCode == spaceKeyCode, !selectedURLs.isEmpty else {
                return event
            }

            // Only the first 5 selected — anything past that was never
            // meant to preview (loupeGrid/loupeRows lay out at most 5) and
            // shows a white, not yellow, border in the grid to match.
            openLoupe(for: photoURLs.filter { previewSelectedURLs.contains($0) })
            return nil
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    private func openLoupe(for urls: [URL]) {
        loupeURLs = urls
        loadLoupeImages(for: urls)
    }

    private func loadLoupeImages(for urls: [URL]) {
        for url in urls where loupeImages[url] == nil {
            DispatchQueue.global(qos: .userInitiated).async {
                // makePreviewImage uses NSImage lockFocus/unlockFocus, which
                // is main-thread-only AppKit drawing — calling it off-thread
                // (as this used to) is undefined behavior and was causing a
                // brief app hang when several selected photos loaded at
                // once. makeShowGridThumbnail is ImageIO-based and safe to
                // call concurrently from a background queue.
                let image = makeShowGridThumbnail(from: url, maxPixelSize: 2000)

                DispatchQueue.main.async {
                    if let image {
                        loupeImages[url] = image
                    }
                }
            }
        }
    }

    // MARK: Export labeled / starred photos

    // Copies every liked (yellow-labeled) photo's original file to a
    // client-chosen folder. Purely a file export — it has no effect on the
    // liked/selected state here or on the Kousei/Kirigami slideshow flow.
    private func exportLabeledPhotos() {
        exportPhotos(
            matching: likedURLs,
            message: "Choose a folder to export the labeled photos to.",
            countingAs: .labeled
        )
    }

    // Same file-copy export as "Export Labeled", but for every photo that
    // has at least 1 star, independent of the liked/labeled circle.
    private func exportStarredPhotos() {
        let starredURLs = Set(photoURLs.filter { (ratings[$0] ?? 0) > 0 })
        exportPhotos(
            matching: starredURLs,
            message: "Choose a folder to export the starred photos to.",
            countingAs: .starred
        )
    }

    private func exportPhotos(matching urlsToMatch: Set<URL>, message: String, countingAs kind: ExportCounter.Kind) {
        guard !urlsToMatch.isEmpty else {
            return
        }

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Export"
        panel.message = message

        guard panel.runModal() == .OK, let destinationFolder = panel.url else {
            return
        }

        let urlsToExport = photoURLs.filter { urlsToMatch.contains($0) }

        DispatchQueue.global(qos: .userInitiated).async {
            let fileManager = FileManager.default

            for sourceURL in urlsToExport {
                var destinationURL = destinationFolder.appendingPathComponent(sourceURL.lastPathComponent)
                let baseName = sourceURL.deletingPathExtension().lastPathComponent
                let fileExtension = sourceURL.pathExtension
                var duplicateSuffix = 1

                while fileManager.fileExists(atPath: destinationURL.path) {
                    let candidateName = fileExtension.isEmpty
                        ? "\(baseName) \(duplicateSuffix)"
                        : "\(baseName) \(duplicateSuffix).\(fileExtension)"
                    destinationURL = destinationFolder.appendingPathComponent(candidateName)
                    duplicateSuffix += 1
                }

                try? fileManager.copyItem(at: sourceURL, to: destinationURL)
            }

            DispatchQueue.main.async {
                ExportCounter.recordExport(kind: kind)

                // The client may have just typed a brand new folder name
                // into the export panel (it allows creating one), and the
                // left-hand tree caches each folder's subfolder listing the
                // first time it's expanded — without this, a newly created
                // destination folder stayed invisible in the sidebar until
                // BriefShow was relaunched, even though the export itself
                // succeeded.
                refreshFolderTree()
            }
        }
    }

    // Forces the left-hand folder tree to rescan from disk by swapping in a
    // fresh root FolderNode — cheap, since FolderNode only scans a folder's
    // contents lazily, the first time something actually asks for its
    // children. `expandedURLs`/`selectedFolderURL` in FolderTreeSidebar are
    // keyed by URL rather than by node identity, so the tree's current
    // scroll/expansion state survives the swap.
    private func refreshFolderTree() {
        guard let currentRootURL = rootFolderNode?.url else {
            return
        }

        rootFolderNode = FolderNode(url: currentRootURL)
    }

    // MARK: Photo import + thumbnail loading

    private func openPhotoPickerForShow() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.resolvesAliases = true

        guard panel.runModal() == .OK else {
            return
        }

        importShowPhotos(panel.urls)
    }

    // Called when the client clicks a folder in the left-hand tree — loads
    // whatever images sit directly inside it, the same way the manual file
    // picker and drag-and-drop already do. Explicitly clears the grid
    // (rather than leaving the previous folder's photos up) when the
    // chosen folder has no images, so the grid always reflects whichever
    // folder is currently selected.
    //
    // The directory scan runs on a background queue rather than inline —
    // on a folder with a few thousand files, `contentsOfDirectory` plus the
    // per-file UTType check was slow enough to run right on the main
    // thread that BriefShow appeared to hang the instant a folder was
    // clicked, with nothing on screen to say it was actually working.
    private func loadImages(inFolder folderURL: URL) {
        isLoadingPhotos = true

        DispatchQueue.global(qos: .userInitiated).async {
            let contents = (try? FileManager.default.contentsOfDirectory(
                at: folderURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []

            let imageURLs = contents.filter { url in
                UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
            }

            DispatchQueue.main.async {
                guard !imageURLs.isEmpty else {
                    photoURLs = []
                    likedURLs = []
                    ratings = [:]
                    isLoadingPhotos = false
                    return
                }

                importShowPhotos(imageURLs)
            }
        }
    }

    // Shared by the file picker, drag-and-drop, and folder selection.
    private func importShowPhotos(_ urls: [URL]) {
        let sortedURLs = urls
            .filter { url in
                UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
            }
            .sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
            }

        guard !sortedURLs.isEmpty else {
            return
        }

        photoURLs = sortedURLs
        applyPersistedLabels(for: sortedURLs)
        loadGridThumbnails(for: sortedURLs)
    }

    // Restores each photo's liked/starred state from PhotoLabelStore —
    // this is what makes labels survive quitting and relaunching BriefShow,
    // and what makes an exported copy of an already-labeled photo (in a
    // brand new folder, under a different path) show up labeled too.
    // Replaces likedURLs/ratings outright (rather than merging) so they
    // only ever describe the batch of photos actually on screen, matching
    // the "N liked" header count and the Export/Clear All buttons.
    private func applyPersistedLabels(for urls: [URL]) {
        var newLikedURLs: Set<URL> = []
        var newRatings: [URL: Int] = [:]

        for url in urls {
            if PhotoLabelStore.isLiked(url) {
                newLikedURLs.insert(url)
            }

            let rating = PhotoLabelStore.rating(for: url)
            if rating > 0 {
                newRatings[url] = rating
            }
        }

        likedURLs = newLikedURLs
        ratings = newRatings
    }

    private func loadGridThumbnails(for urls: [URL]) {
        isLoadingPhotos = true
        loadedThumbnailCount = 0

        DispatchQueue.global(qos: .userInitiated).async {
            // Thumbnails are decoded here and only flushed to the @State
            // dictionary every few images (rather than after every single
            // one). With a couple hundred photos, updating @State per image
            // meant hundreds of back-to-back re-renders of the whole grid —
            // that churn, not the decoding itself, was most of what read as
            // BriefShow "freezing" while photos loaded.
            let flushInterval = 10
            var pendingBatch: [URL: NSImage] = [:]

            for (index, url) in urls.enumerated() {
                if let thumbnail = makeShowGridThumbnail(from: url) {
                    pendingBatch[url] = thumbnail
                }

                let processedCount = index + 1
                guard pendingBatch.count >= flushInterval || processedCount == urls.count else {
                    continue
                }

                let flushedBatch = pendingBatch
                pendingBatch = [:]

                DispatchQueue.main.async {
                    for (batchURL, thumbnail) in flushedBatch {
                        gridThumbnails[batchURL] = thumbnail
                    }

                    loadedThumbnailCount = processedCount

                    if loadedThumbnailCount >= urls.count {
                        isLoadingPhotos = false
                    }
                }
            }
        }
    }
}

// Backs the "Copy" and "Cut" items on both the grid's photo right-click
// menu and the sidebar's folder right-click menu — puts real file
// references on the system pasteboard so the client can Cmd+V them into
// Finder (or anywhere else that accepts files), the same as Finder's own
// Copy. Cut writes identically: a genuine cross-app "Cut" (the source
// vanishing only once it's pasted somewhere else) isn't something a
// third-party app can trigger through public API, so nothing here deletes
// anything — "Add to Bin" is the only action in either menu that touches
// disk.
private func writeURLsToPasteboard(_ urls: [URL]) {
    guard !urls.isEmpty else {
        return
    }

    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.writeObjects(urls as [NSURL])
}

// MARK: - Desktop folder access (sandboxed security-scoped bookmark)

// BriefShow is sandboxed with only `user-selected.read-write` access
// (BriefShow.entitlements), so it can't browse the Mac's filesystem the
// way Finder does — it can only read a folder the client has explicitly
// granted through an NSOpenPanel. Granting the client's home folder
// covers every everyday location underneath it (Desktop, Documents,
// Downloads, Pictures, ...) in one go, the same set Finder's sidebar
// starts from, without needing a separate grant per folder. This
// resolves (or, the first time only, requests) that access and remembers
// it via a security-scoped bookmark, so every later launch skips the
// prompt and the folder tree just opens straight up.
enum RootFolderAccess {
    private static let bookmarkDefaultsKey = "com.rocketsbrief.briefshow.rootFolderBookmark"

    static func resolve() -> URL? {
        if let url = resolveFromStoredBookmark() {
            return url
        }

        return requestAccessAndStoreBookmark()
    }

    private static func resolveFromStoredBookmark() -> URL? {
        guard let bookmarkData = UserDefaults.standard.data(forKey: bookmarkDefaultsKey) else {
            return nil
        }

        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            return nil
        }

        guard url.startAccessingSecurityScopedResource() else {
            return nil
        }

        if isStale {
            storeBookmark(for: url)
        }

        return url
    }

    private static func requestAccessAndStoreBookmark() -> URL? {
        let homeURL = FileManager.default.homeDirectoryForCurrentUser

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = homeURL
        panel.prompt = "Grant Access"
        panel.message = "Let BriefShow browse your folders (Desktop, Documents, Pictures, ...) so you can review photos straight from them."

        guard panel.runModal() == .OK, let grantedURL = panel.url else {
            return nil
        }

        guard grantedURL.startAccessingSecurityScopedResource() else {
            return nil
        }

        storeBookmark(for: grantedURL)
        return grantedURL
    }

    private static func storeBookmark(for url: URL) {
        guard let bookmarkData = try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else {
            return
        }

        UserDefaults.standard.set(bookmarkData, forKey: bookmarkDefaultsKey)
    }
}

// MARK: - Persisted photo labels (liked + star rating)

// Keeps every liked-label and star-rating decision so it survives quitting
// and relaunching BriefShow, and so it's still there when the client later
// opens a folder they exported labeled photos into (a copy of an
// already-labeled photo, at a new path).
//
// Keyed by filename + file size rather than the file's URL/path — the
// path is exactly what changes when a photo gets copied to an export
// folder, while the name and byte size stay identical for a straight file
// copy. Two different photos landing on the same name+size is possible in
// principle but very unlikely in practice, and far less likely than a
// client being annoyed that a labeled photo "forgot" its label the moment
// it was exported.
enum PhotoLabelStore {
    private static let likedDefaultsKey = "com.rocketsbrief.briefshow.likedPhotoKeys"
    private static let ratingsDefaultsKey = "com.rocketsbrief.briefshow.photoRatingKeys"

    private static func key(for url: URL) -> String {
        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? -1
        return "\(url.lastPathComponent)|\(fileSize)"
    }

    static func isLiked(_ url: URL) -> Bool {
        likedKeys.contains(key(for: url))
    }

    static func setLiked(_ isLiked: Bool, for url: URL) {
        var keys = likedKeys
        if isLiked {
            keys.insert(key(for: url))
        } else {
            keys.remove(key(for: url))
        }
        likedKeys = keys
    }

    static func rating(for url: URL) -> Int {
        ratingsByKey[key(for: url)] ?? 0
    }

    static func setRating(_ rating: Int, for url: URL) {
        var byKey = ratingsByKey
        if rating > 0 {
            byKey[key(for: url)] = rating
        } else {
            byKey.removeValue(forKey: key(for: url))
        }
        ratingsByKey = byKey
    }

    // Drops both the liked flag and the star rating for one photo — used
    // by "Clear All".
    static func clear(for url: URL) {
        setLiked(false, for: url)
        setRating(0, for: url)
    }

    private static var likedKeys: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: likedDefaultsKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: likedDefaultsKey) }
    }

    private static var ratingsByKey: [String: Int] {
        get { (UserDefaults.standard.dictionary(forKey: ratingsDefaultsKey) as? [String: Int]) ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: ratingsDefaultsKey) }
    }
}

// MARK: - Folder color labels (right-click a folder in the sidebar)

// The four Finder-style colored tags a folder in the sidebar can be given,
// purely a BriefShow-side label (a colored dot next to the folder's name in
// the tree) — it doesn't touch the folder on disk or its Finder tags.
enum FolderColorLabel: String, CaseIterable {
    case none, blue, yellow, green, red

    // Display order matches how the client asked for them: blue, yellow,
    // green, red.
    static let selectable: [FolderColorLabel] = [.blue, .yellow, .green, .red]

    var displayName: String {
        switch self {
        case .none: return "None"
        case .blue: return "Blue"
        case .yellow: return "Yellow"
        case .green: return "Green"
        case .red: return "Red"
        }
    }

    var color: Color? {
        switch self {
        case .none: return nil
        case .blue: return Color(red: 0.42, green: 0.62, blue: 0.95)
        case .yellow: return Color(red: 0.96, green: 0.78, blue: 0.28)
        case .green: return Color(red: 0.40, green: 0.78, blue: 0.48)
        case .red: return Color(red: 0.94, green: 0.38, blue: 0.38)
        }
    }

    // A small solid-color dot, rendered as a real NSImage rather than an
    // SF Symbol, for use as a context-menu item's icon. AppKit renders SF
    // Symbols (and any image it treats as a "template") in a single flat
    // color — usually the menu's own ink color — regardless of any SwiftUI
    // .foregroundColor applied beforehand, which is why every dot in the
    // Color Label menu was showing up the same gray. Explicitly marking
    // this image non-template is what makes AppKit draw it in its actual
    // color instead.
    static func dotImage(for color: Color?, diameter: CGFloat = 12) -> NSImage {
        let size = NSSize(width: diameter, height: diameter)
        let image = NSImage(size: size)

        image.lockFocus()
        NSColor(color ?? .gray).setFill()
        NSBezierPath(ovalIn: NSRect(origin: .zero, size: size)).fill()
        image.unlockFocus()

        image.isTemplate = false
        return image
    }
}

// Persists which color (if any) each folder is tagged with, keyed by its
// absolute path — the same trade-off RootFolderAccess's bookmark makes:
// simple and correct for a folder that stays put, but a color won't follow
// a folder that's later renamed or moved (including via BriefShow's own
// Cut/Paste) the way PhotoLabelStore's name+size key lets a liked photo's
// label follow it through an export.
enum FolderColorStore {
    private static let defaultsKey = "com.rocketsbrief.briefshow.folderColorLabels"

    static func color(for url: URL) -> FolderColorLabel {
        let stored = (UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String]) ?? [:]
        guard let raw = stored[url.standardizedFileURL.path], let label = FolderColorLabel(rawValue: raw) else {
            return .none
        }
        return label
    }

    static func setColor(_ label: FolderColorLabel, for url: URL) {
        var stored = (UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String]) ?? [:]
        let key = url.standardizedFileURL.path

        if label == .none {
            stored.removeValue(forKey: key)
        } else {
            stored[key] = label.rawValue
        }

        UserDefaults.standard.set(stored, forKey: defaultsKey)
    }

    // Loaded once by FolderTreeSidebar on appear into its own @State, so
    // the tree can react to color changes the same way it reacts to
    // selection/expansion — UserDefaults itself isn't observable. Keyed by
    // the same standardized path STRING used to read/write above (rather
    // than reconstructing a URL from it) — round-tripping a path through
    // `URL(fileURLWithPath:)` and comparing the result to a `FolderNode`'s
    // own URL with `==` is exactly the kind of thing that can silently
    // mismatch (trailing slash, symlink resolution, ...) and make a color
    // that was genuinely saved look like it never was, once the app
    // restarts and rebuilds the tree from scratch.
    static func loadAll() -> [String: FolderColorLabel] {
        let stored = (UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String]) ?? [:]
        var result: [String: FolderColorLabel] = [:]

        for (path, raw) in stored {
            guard let label = FolderColorLabel(rawValue: raw), label != .none else {
                continue
            }
            result[path] = label
        }

        return result
    }
}

// MARK: - Folder tree sidebar (Finder-style, home-folder-rooted)

// One node in the folder tree. A class (rather than a struct) so each
// node's `children` can be computed lazily and cached on first access —
// expanding a row scans just that one folder instead of the whole Desktop
// subtree being walked upfront when the sidebar first appears.
final class FolderNode: Identifiable {
    let url: URL
    var id: URL { url }

    private var cachedChildren: [FolderNode]??

    init(url: URL) {
        self.url = url
    }

    var name: String {
        url.lastPathComponent
    }

    var children: [FolderNode]? {
        if let cachedChildren {
            return cachedChildren
        }

        let loaded = FolderNode.loadSubfolders(of: url)
        cachedChildren = loaded
        return loaded
    }

    private static func loadSubfolders(of url: URL) -> [FolderNode]? {
        let contents = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        let subfolders = (contents ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        guard !subfolders.isEmpty else {
            return nil
        }

        return subfolders.map { FolderNode(url: $0) }
    }
}

// Left-hand Finder-style folder browser, rooted at the client's home
// folder (so it covers Desktop, Documents, Downloads, Pictures, etc. the
// same way Finder's own sidebar does). Clicking a folder here is
// BriefShow's primary way of loading photos now — it loads whatever
// images sit directly inside that folder into the grid, with no separate
// "Import" step, similar in spirit to Adobe Bridge's folder panel.
//
// The "currently open" row pinned above the scrolling tree always names
// whichever folder is loaded on the right — including when that folder
// was opened by dragging it onto the grid rather than by clicking it
// here, where it may not even be visible in the (possibly collapsed)
// tree below.
private struct FolderTreeSidebar: View {
    let rootNode: FolderNode
    @Binding var selectedURL: URL?
    let isPasteAvailable: Bool
    let onSetClipboard: (_ urls: [URL], _ isCut: Bool) -> Void
    let onPasteIntoFolder: (FolderNode) -> Void
    let onNewFolder: (FolderNode) -> Void
    let onTrashFolder: (FolderNode) -> Void

    // Which folders' disclosure triangles are currently open. Unlike
    // OutlineGroup (which manages expansion internally with no outside
    // access), tracking this ourselves lets us expand the tree down to
    // whatever folder is currently open — including when it was opened by
    // dragging a folder onto the grid rather than by clicking through the
    // tree — the same "reveal in sidebar" behavior Adobe Bridge/Finder
    // give you.
    @State private var expandedURLs: Set<URL> = []

    // Which row the pointer is currently over, so its name can scale up —
    // a single shared var (rather than per-row @State, which `row(for:)`
    // can't hold since it's a plain function, not its own View struct)
    // works fine here since only one row is ever hovered at a time.
    @State private var hoveredURL: URL?

    // Which color (if any) each folder is tagged with, keyed by the
    // folder's standardized path (see the doc comment on
    // FolderColorStore.loadAll for why a path string rather than a URL).
    // Loaded once into local @State (rather than read fresh from
    // UserDefaults on every row render) so setting a color actually
    // triggers a redraw; UserDefaults itself isn't observable.
    @State private var folderColors: [String: FolderColorLabel] = FolderColorStore.loadAll()

    // Same defensive pattern every other themed view in this file uses
    // (PhotoShowSheet, HeaderView, the hover cards, ...) — without its own
    // subscription here, this sidebar could keep showing whichever theme
    // was active when it first appeared instead of updating live when the
    // client picks a different one from the header circles.
    @ObservedObject private var themeManager = ThemeManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(rootNode.name.uppercased())
                .font(.custom("Figtree", size: 11).weight(.bold))
                .tracking(1.1)
                .foregroundColor(AppColors.muted.opacity(0.7))
                .padding(.horizontal, 18)
                .padding(.top, 20)
                .padding(.bottom, 10)

            if let selectedURL {
                currentlyOpenRow(for: selectedURL)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    row(for: rootNode, depth: 0)

                    ForEach(rootNode.children ?? [], id: \.id) { node in
                        folderDisclosure(for: node, depth: 1)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 20)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(AppColors.background)
        .onAppear { expandPathToSelection() }
        .onChange(of: selectedURL) { _ in expandPathToSelection() }
    }

    // A folder with subfolders renders as an expandable disclosure group
    // (its own row as the label, subfolders as its content); a leaf folder
    // just renders its row directly, with no triangle. Type-erased to
    // AnyView (rather than `some View`) because this function calls
    // itself recursively — an opaque return type can't refer to itself.
    //
    // `depth` counts how many folders deep this node sits below the
    // top-level list (Applications, Desktop, Documents, ...) — passed down
    // one deeper on every recursive call so row(for:depth:) can indent
    // each level. Without it, a expanded folder's children rendered at
    // the exact same indentation as its siblings, with nothing to show
    // which folders were actually inside which — see row(for:depth:).
    private func folderDisclosure(for node: FolderNode, depth: Int) -> AnyView {
        guard let children = node.children else {
            return AnyView(row(for: node, depth: depth))
        }
        return AnyView(
            VStack(alignment: .leading, spacing: 2) {
                row(for: node, depth: depth)

                if expandedURLs.contains(node.url) {
                    ForEach(children, id: \.id) { child in
                        folderDisclosure(for: child, depth: depth + 1)
                    }
                }
            }
        )
    }

    private func expandedBinding(for url: URL) -> Binding<Bool> {
        Binding(
            get: { expandedURLs.contains(url) },
            set: { isExpanded in
                if isExpanded {
                    expandedURLs.insert(url)
                } else {
                    expandedURLs.remove(url)
                }
            }
        )
    }

    // Walks every ancestor folder between the root and the currently open
    // folder (exclusive of the folder itself) and marks each one expanded,
    // so the open folder's own row is actually visible in the tree instead
    // of hidden inside a collapsed parent.
    private func expandPathToSelection() {
        guard let selectedURL else {
            return
        }

        let standardizedRoot = rootNode.url.standardizedFileURL
        let standardizedTarget = selectedURL.standardizedFileURL

        guard standardizedTarget.path.hasPrefix(standardizedRoot.path + "/") else {
            return
        }

        let relativeComponents = standardizedTarget.pathComponents.dropFirst(standardizedRoot.pathComponents.count)

        var ancestorURL = standardizedRoot
        for component in relativeComponents.dropLast() {
            ancestorURL.appendPathComponent(component)
            expandedURLs.insert(ancestorURL)
        }
    }

    // Pinned indicator naming the folder currently loaded into the grid,
    // so the client always has an unambiguous answer to "what am I
    // looking at" — the tree below it can be scrolled/collapsed away from
    // that folder's row without losing that context.
    private func currentlyOpenRow(for url: URL) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "folder.badge.checkmark")
                .font(.system(size: 12))
                .foregroundColor(AppColors.hoverInk)

            VStack(alignment: .leading, spacing: 1) {
                Text("OPEN")
                    .font(.custom("Figtree", size: 9).weight(.bold))
                    .tracking(0.8)
                    .foregroundColor(AppColors.muted.opacity(0.6))

                Text(url.lastPathComponent)
                    .font(.custom("Figtree", size: 13).weight(.semibold))
                    .foregroundColor(AppColors.ink)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(AppColors.panel)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(AppColors.hoverInk.opacity(0.35), lineWidth: 1)
        )
    }

// An open folder, hand-drawn because SF Symbols has no such glyph — there is
// `folder` and `folder.fill` and nothing between them, on any macOS version.
// Two filled subpaths with a real transparent GAP between them, rather than
// one shape with a lighter line through it: the sidebar row paints a
// selection/hover fill behind this, and a "gap" drawn in the background
// colour would turn into a visible stripe the moment that fill appears.
//
// Proportions are matched to folder.fill at the same point size so the two
// read as the same weight when half the tree is open and half is closed.
private struct OpenFolderShape: Shape {
    func path(in rect: CGRect) -> Path {
        func at(_ fx: CGFloat, _ fy: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + fx * rect.width, y: rect.minY + fy * rect.height)
        }

        var path = Path()

        // Back panel: the tabbed folder body, cut off where the front flap
        // takes over.
        path.move(to: at(0.00, 0.48))
        path.addLine(to: at(0.00, 0.22))
        path.addQuadCurve(to: at(0.09, 0.13), control: at(0.00, 0.13))
        path.addLine(to: at(0.31, 0.13))
        path.addLine(to: at(0.41, 0.27))
        path.addLine(to: at(0.75, 0.27))
        path.addQuadCurve(to: at(0.84, 0.36), control: at(0.84, 0.27))
        path.addLine(to: at(0.84, 0.48))
        path.closeSubpath()

        // Front flap: same width, slid right along the bottom, which is what
        // reads as "tilted forward and open" rather than "a folder".
        path.move(to: at(0.00, 0.55))
        path.addLine(to: at(0.84, 0.55))
        path.addLine(to: at(0.96, 0.88))
        path.addLine(to: at(0.12, 0.88))
        path.closeSubpath()

        return path
    }
}

    // `depth` is how many folders deep this row sits below the top-level
    // list — 0 for Applications/Desktop/Documents/... themselves, 1 for
    // what's directly inside one of them, and so on. Indenting the
    // icon+name by depth (rather than leaving every level flush against
    // the same left edge, which is what made an expanded folder's
    // contents unreadable against its own siblings) is what actually
    // shows the nesting.
    private func row(for node: FolderNode, depth: Int) -> some View {
        let isSelected = selectedURL == node.url
        let isHovered = hoveredURL == node.url
        // Only a folder that HAS children can be open; a leaf sitting in
        // expandedURLs (which can happen, since a plain tap inserts before
        // the children are known) must still draw as closed.
        let isExpanded = node.children != nil && expandedURLs.contains(node.url)
        let colorLabel = folderColors[node.url.standardizedFileURL.path] ?? .none

        return HStack(spacing: 8) {
            // An inline spacer (rather than extra .padding(.leading) on the
            // whole row) so only the icon/name/dot shift right — the
            // selection/hover background below stays full-width, the same
            // way Finder's and Xcode's own sidebars keep their highlight
            // pill from getting visibly narrower the deeper something is
            // nested.
            if depth > 0 {
                Color.clear.frame(width: CGFloat(depth) * 24)
            }

            // The triangle's own column, present on EVERY row whether or not
            // that row has a triangle. This is the whole reason the tree
            // stopped using DisclosureGroup: SwiftUI indents a
            // DisclosureGroup's label but not a plain row, so a folder with
            // subfolders sat ~27pt further right than its own sibling with
            // none — two rows at the same level, drawn at two different
            // levels, which read as nesting that wasn't there. Reserving the
            // column here lines every sibling up, the way Finder's sidebar
            // does, and leaves the gap empty for folders that can't open.
            Group {
                if node.children != nil, node.url != rootNode.url {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(AppColors.muted.opacity(0.8))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                } else {
                    Color.clear
                }
            }
            .frame(width: 10)
            // Decoration, not a second hit target: the row's own tap already
            // opens and closes it (see onTapGesture below), and a gesture
            // here would only add a way for the two to disagree.
            .allowsHitTesting(false)

            // Open folders get an open folder, the way Finder's own sidebar
            // does — the disclosure triangle already says "expanded", but it
            // sits far to the left of the name and is easy to miss when
            // several levels are open at once. Fixed-width frame on BOTH
            // icons so a folder's name doesn't shift sideways as it opens:
            // the two glyphs are not the same width.
            Group {
                if isExpanded {
                    OpenFolderShape()
                        .frame(width: 13, height: 11)
                } else {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 12))
                }
            }
            .frame(width: 14, alignment: .leading)
            .foregroundColor(isSelected ? AppColors.hoverInk : AppColors.muted.opacity(0.8))

            Text(node.name)
                .font(.custom("Figtree", size: 13).weight(isSelected ? .semibold : .regular))
                .foregroundColor(isSelected ? AppColors.ink : AppColors.muted)
                .lineLimit(1)
                // Left edge anchored so it grows rightward into the row's
                // empty space instead of pushing into the folder icon.
                .scaleEffect(isHovered ? 1.1 : 1, anchor: .leading)
                .animation(.easeOut(duration: 0.12), value: isHovered)

            Spacer(minLength: 0)

            if let color = colorLabel.color {
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? AppColors.panel : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            // Guards against a stale clear: if the pointer has already
            // moved straight onto the next row by the time this row's
            // "false" event arrives, that later event shouldn't erase the
            // new row's "true".
            if hovering {
                hoveredURL = node.url
            } else if hoveredURL == node.url {
                hoveredURL = nil
            }
        }
        .onTapGesture {
            selectedURL = node.url

            // A single click on the folder's row now opens/closes it the
            // same way clicking its disclosure triangle does — previously
            // the triangle was the only hit target that expanded a folder,
            // so clicking the name only selected it without revealing its
            // subfolders.
            if node.children != nil {
                if expandedURLs.contains(node.url) {
                    expandedURLs.remove(node.url)
                } else {
                    expandedURLs.insert(node.url)
                }
            }
        }
        .contextMenu {
            folderContextMenuItems(for: node, isRoot: node.url == rootNode.url)
        }
    }

    private func setFolderColor(_ label: FolderColorLabel, for node: FolderNode) {
        folderColors[node.url.standardizedFileURL.path] = (label == .none) ? nil : label
        FolderColorStore.setColor(label, for: node.url)
    }

    // The root row is the client's whole granted home folder (see
    // RootFolderAccess) — Copy/Cut, Color Label, and "Add to Bin" are left
    // off it entirely (Copy/Cut/coloring it are pointless, and "Add to
    // Bin" on it would trash the client's entire home directory), leaving
    // just New Folder and Paste.
    @ViewBuilder
    private func folderContextMenuItems(for node: FolderNode, isRoot: Bool) -> some View {
        Button("New Folder") {
            onNewFolder(node)
        }

        Divider()

        if !isRoot {
            Button("Copy") {
                writeURLsToPasteboard([node.url])
                onSetClipboard([node.url], false)
            }

            // Also sets BriefShow's own in-app clipboard so "Paste"
            // elsewhere in the tree actually moves this folder there — see
            // the doc comment on pasteClipboard in PhotoShowSheet. The
            // NSPasteboard write alongside it only ever copies once it
            // leaves BriefShow (e.g. pasted into Finder), since a genuine
            // cross-app "Cut" isn't triggerable from a third-party app.
            Button("Cut") {
                writeURLsToPasteboard([node.url])
                onSetClipboard([node.url], true)
            }

            Menu("Color Label") {
                ForEach(FolderColorLabel.selectable, id: \.self) { label in
                    Button {
                        setFolderColor(label, for: node)
                    } label: {
                        Label {
                            Text(label.displayName)
                        } icon: {
                            // A plain SF Symbol here (Image(systemName:)
                            // + .foregroundColor) renders as a monochrome
                            // template icon once AppKit turns this into a
                            // real NSMenuItem — .foregroundColor is simply
                            // dropped, which is why every dot came out the
                            // same gray. An explicitly non-template NSImage
                            // is the one thing AppKit actually draws in its
                            // real color inside a menu.
                            Image(nsImage: FolderColorLabel.dotImage(for: label.color))
                        }
                    }
                }

                if folderColors[node.url.standardizedFileURL.path] != nil {
                    Divider()

                    Button("No Color") {
                        setFolderColor(.none, for: node)
                    }
                }
            }
        }

        Button("Paste") {
            onPasteIntoFolder(node)
        }
        .disabled(!isPasteAvailable)

        if !isRoot {
            Divider()

            Button("Add to Bin", role: .destructive) {
                onTrashFolder(node)
            }
        }
    }
}

// A small, fast thumbnail (unlike makePreviewImage's up-to-1400pt preview
// image) for a grid that may hold 50-200+ photos at once.
// Not `private` — Develop.swift's filmstrip reuses this same fast
// thumbnail generator rather than duplicating it.
func makeShowGridThumbnail(from url: URL, maxPixelSize: CGFloat = 420) -> NSImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
        return nil
    }

    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceShouldCacheImmediately: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
    ]

    guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
        return nil
    }

    return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
}

struct ShowHeaderButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ShowHeaderButtonLabel(configuration: configuration)
    }
}

private struct ShowHeaderButtonLabel: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    let configuration: ButtonStyle.Configuration
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .font(.custom("Figtree", size: 12).weight(.semibold))
            .foregroundColor(isHovered ? AppColors.hoverInk : AppColors.ink)
            .scaleEffect(configuration.isPressed ? 0.98 : (isHovered ? 1.1 : 1))
            .animation(.linear(duration: 0.1), value: isHovered)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .onHover { hovering in
                isHovered = hovering
            }
    }
}

#Preview {
    ContentView()
}

