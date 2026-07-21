import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Combine
import AVFoundation
import AVKit
import ImageIO
import CoreImage
import CoreGraphics

enum SlideshowTimingMode: String {
    case followMusic = "Follow Music"
    case customSpeed = "Custom Speed"
}

// How the live "Preview" card renders the slideshow. The two "live" modes
// drive the same real-time SwiftUI animation timer at a different tick rate;
// "renderedVideo" instead pre-renders the slideshow to an actual 1080p video
// file once and plays that back, which is perfectly smooth on weak hardware
// since it's just video playback rather than real-time compositing.
enum PreviewRenderMode: String {
    case liveFPS30
    case liveFPS60
    case renderedVideo
}

enum SlideshowTransitionStyle: String {
    case fade = "Fade"
    case blink = "Blink"
}

enum SlideshowVisualTheme: String {
    case singleFade = "Single Fade"
    case singleBlink = "Single Blink"
    case magazine = "Kousei"
    case magazineFamily = "Magazine Family"
    case magazineCouples = "Magazine Couples"
    case origami = "Kirigami"
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

struct ContentView: View {
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
                HeaderView(isProfileModalPresented: $isProfileModalPresented)

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
                        visualTheme == .origami
                        ? origamiReviewPageRanges
                        : magazineReviewPageRanges,
                    cropTransforms: $photoCropTransforms,
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
        .onChange(of: selectedPhotoURLs) { newValue in
            updateMagazinePhotoSeed(for: newValue)
        }
        .onReceive(Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()) { _ in
            switch previewRenderMode {
            case .renderedVideo:
                // Playback is driven by previewVideoPlayer (AVPlayer) itself,
                // not by this tick-based animation state.
                break
            case .liveFPS60:
                advancePreviewIfNeeded(delta: 1.0 / 60.0)
            case .liveFPS30:
                previewTickCounter += 1
                guard previewTickCounter % 2 == 0 else {
                    break
                }
                advancePreviewIfNeeded(delta: 1.0 / 30.0)
            }
        }
        .onReceive(Timer.publish(every: 600, on: .main, in: .common).autoconnect()) { _ in
            Task { await DeviceCheckIn.checkIn() }
        }
        .task {
            await remoteStatus.refresh()
            await ExportCounter.flush()
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
        visualTheme == .magazine || visualTheme == .magazineFamily || visualTheme == .magazineCouples
    }

    private var usesOrigamiTheme: Bool {
        visualTheme == .origami
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
        let total = previewImages.count

        while consumed < total {
            let remaining = total - consumed

            let count = max(
                1,
                min(
                    6,
                    adaptiveMagazineSlotCount(
                        pageIndex: pageIndex,
                        startIndex: consumed,
                        remainingPhotos: remaining
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
        }

        return ranges
    }

    // Same idea for Kirigami, chunked using its real base-slot-count cycle
    // (3, 5, 6, 2, 4). Swap-in replacement photos are folded into later
    // review pages instead of simulated mid-page, so every photo still gets
    // reviewed exactly once without reproducing the swap animation timing.
    private var origamiReviewPageRanges: [Range<Int>] {
        var ranges: [Range<Int>] = []
        var consumed = 0
        var pageIndex = 0
        let total = previewImages.count

        while consumed < total {
            let remaining = total - consumed

            let count = max(
                1,
                min(
                    6,
                    plannedOrigamiSlotCount(
                        pageIndex: pageIndex,
                        remainingPhotos: remaining
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
        }

        return ranges
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

    private func adaptiveMagazineSlotCount(pageIndex: Int, startIndex: Int, remainingPhotos: Int) -> Int {
        let plannedCount = plannedMagazineSlotCount(pageIndex: pageIndex, remainingPhotos: remainingPhotos)

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
        adaptiveMagazineSlotCount(
            pageIndex: magazinePageIndex,
            startIndex: activePhotoIndex,
            remainingPhotos: selectedPhotoURLs.count - activePhotoIndex
        )
    }

    private func plannedOrigamiSlotCount(
        pageIndex: Int,
        remainingPhotos: Int
    ) -> Int {
        guard remainingPhotos > 0 else {
            return 0
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

        while consumedPhotos < selectedPhotoURLs.count {
            let remainingPhotos = selectedPhotoURLs.count - consumedPhotos
            let slotCount = max(
                1,
                adaptiveMagazineSlotCount(
                    pageIndex: pageIndex,
                    startIndex: consumedPhotos,
                    remainingPhotos: remainingPhotos
                )
            )

            consumedPhotos += slotCount
            pageIndex += 1
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
            if mode == .renderedVideo {
                prepareRenderedPreviewVideo(thenPlay: false)
            }
            return
        }

        if previewRenderMode == .renderedVideo {
            previewVideoPlayer?.pause()
        }

        previewRenderMode = mode

        if mode == .renderedVideo {
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

        let previousURL = preparedPreviewVideoURL
        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BriefShow-preview-\(UUID().uuidString).mp4")

        let photoURLs = selectedPhotoURLs
        let musicURLs = selectedMusicURLs
        let durationPerPhoto = max(0.25, currentPhotoDuration)
        let selectedTransitionStyle = transitionStyle
        let selectedFadeDuration = fadeDuration
        let selectedVisualTheme = visualTheme
        let selectedMagazineImageFade = magazineImageFadeSeconds
        let selectedMagazineImageDelay = magazineImageDelaySeconds
        let selectedPhotoCropTransforms = photoCropTransforms
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
                    || selectedVisualTheme == .magazineFamily
                    || selectedVisualTheme == .magazineCouples {

                    try renderMagazineSlideshowVideo(
                        photoURLs: photoURLs,
                        outputURL: videoOnlyURL,
                        resolutionName: "1080p",
                        pageDuration: durationPerPhoto,
                        imageFadeSeconds: selectedMagazineImageFade,
                        imageDelaySeconds: selectedMagazineImageDelay,
                        revealStyle: selectedTransitionStyle,
                        cropTransforms: selectedPhotoCropTransforms,
                        fileType: .mp4,
                        progressHandler: reportProgress
                    )
                } else if selectedVisualTheme == .origami {
                    try renderOrigamiSlideshowVideo(
                        photoURLs: photoURLs,
                        outputURL: videoOnlyURL,
                        resolutionName: "1080p",
                        pageDuration: selectedOrigamiHoldSeconds,
                        imagesBeforePageChange: selectedOrigamiImagesBeforePageChange,
                        simultaneousSwapCount: selectedOrigamiSimultaneousSwapCount,
                        cropTransforms: selectedPhotoCropTransforms,
                        fileType: .mp4,
                        progressHandler: reportProgress
                    )
                } else if selectedVisualTheme == .imagination {
                    try renderImaginationSlideshowVideo(
                        photoURLs: photoURLs,
                        outputURL: videoOnlyURL,
                        resolutionName: "1080p",
                        pageDuration: durationPerPhoto,
                        fadeDuration: selectedFadeDuration,
                        fileType: .mp4,
                        progressHandler: reportProgress
                    )
                } else {
                    try renderSlideshowVideo(
                        photoURLs: photoURLs,
                        outputURL: videoOnlyURL,
                        resolutionName: "1080p",
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
                        fileType: exportFileType,
                        progressHandler:
                            reportRenderProgress
                    )
                } else if selectedVisualTheme == .origami {
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
    seed: Int
) -> Int {
    guard remainingPhotos > 0 else {
        return 0
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
    remainingPhotos: Int
) -> Int {
    guard plannedCount > 0 else {
        return 0
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
    photoURLs: [URL]
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

    while consumed < photos.count {
        let remaining =
            photos.count - consumed

        let planned =
            plannedMagazineExportSlotCount(
                pageIndex: pageIndex,
                remainingPhotos:
                    remaining,
                seed: seed
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
                    remaining
            )
        )

        let endIndex = min(
            photos.count,
            consumed + slotCount
        )

        guard consumed < endIndex else {
            break
        }

        pages.append(
            MagazineExportPage(
                photos:
                    Array(
                        photos[
                            consumed..<endIndex
                        ]
                    ),
                layoutVariant:
                    pageIndex % 2
            )
        )

        consumed = endIndex
        pageIndex += 1
    }

    return pages
}

private func magazineExportSlotShapes(
    for photos: [MagazineExportPhoto]
) -> [MagazineExportSlotShape] {
    let portraitCount =
        photos.filter {
            $0.shape == .portrait
        }.count

    let landscapeCount =
        photos.filter {
            $0.shape == .landscape
        }.count

    let mixed =
        portraitCount > 0
        && landscapeCount > 0

    switch photos.count {
    case 2:
        return mixed
            ? [.wide, .tall]
            : [.flex, .flex]

    case 3:
        if portraitCount >= 2 {
            return [
                .tall,
                .tall,
                .flex,
            ]
        }

        if mixed {
            return [
                .wide,
                .wide,
                .tall,
            ]
        }

        return [
            .wide,
            .flex,
            .flex,
        ]

    case 4:
        if portraitCount >= 2 {
            return [
                .tall,
                .tall,
                .wide,
                .wide,
            ]
        }

        if mixed {
            return [
                .tall,
                .wide,
                .wide,
                .wide,
            ]
        }

        return Array(
            repeating: .wide,
            count: 4
        )

    case 5:
        if portraitCount >= 2 {
            return [
                .tall,
                .tall,
                .wide,
                .wide,
                .wide,
            ]
        }

        if mixed {
            return [
                .tall,
                .wide,
                .wide,
                .wide,
                .wide,
            ]
        }

        return Array(
            repeating: .wide,
            count: 5
        )

    default:
        if portraitCount >= 3 {
            return [
                .tall,
                .tall,
                .tall,
                .wide,
                .wide,
                .wide,
            ]
        }

        if portraitCount == 2 {
            return [
                .wide,
                .wide,
                .wide,
                .tall,
                .wide,
                .tall,
            ]
        }

        if portraitCount == 1 {
            return [
                .tall,
                .wide,
                .wide,
                .wide,
                .wide,
                .wide,
            ]
        }

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

private func orderedMagazineExportPhotos(
    _ photos: [MagazineExportPhoto]
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
            for: photos
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

    let portraitCount =
        photos.filter {
            $0.shape == .portrait
        }.count

    let landscapeCount =
        photos.filter {
            $0.shape == .landscape
        }.count

    let mixed =
        portraitCount > 0
        && landscapeCount > 0

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
        if mixed {
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
        if portraitCount >= 2 {
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

        if mixed {
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
        if portraitCount >= 2 {
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

        if mixed {
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

        if page.layoutVariant == 0 {
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
        if portraitCount >= 2 {
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

        if mixed {
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
        if portraitCount >= 3 {
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

        if portraitCount == 2 {
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

        if portraitCount == 1 {
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

        if page.layoutVariant == 0 {
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
        NSColor.white.cgColor
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
        NSColor.white.cgColor
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

    let orderedPhotos =
        orderedMagazineExportPhotos(
            page.photos
        )

    let rects =
        magazineExportLayoutRects(
            page: page,
            contentRect:
                contentRect,
            gap: gap
        )

    let fadeSeconds = max(
        0.05,
        imageFadeSeconds
    )

    let delaySeconds = max(
        0,
        imageDelaySeconds
    )

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
            photoURLs: photoURLs
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
    let swapBatches:
        [OrigamiSwiftUIExportSwapBatch]
    let finalReplacements:
        [Int: NSImage]
    let pageIndex: Int
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

private func buildOrigamiSwiftUIExportPages(
    photoURLs: [URL],
    imagesBeforePageChange: Int,
    simultaneousSwapCount: Int,
    cropTransforms: [URL: MagazinePhotoCrop]
) -> (pages: [OrigamiSwiftUIExportPage], cropByImageIdentity: [ObjectIdentifier: MagazinePhotoCrop]) {
    let loadedPhotoPairs: [(url: URL, image: NSImage)] =
        photoURLs.compactMap { url in
            NSImage(contentsOf: url).map { (url: url, image: $0) }
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

    let cycle = [3, 5, 6, 2, 4]

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
                6,
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
                swapBatches:
                    swapBatches,
                finalReplacements:
                    currentReplacements,
                pageIndex:
                    pageIndex
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
                    cropByImageIdentity
            )

            if let previousPage {
                OrigamiWholePageHalfFoldOverlay(
                    images:
                        previousPage
                            .baseImages,
                    slotReplacementImages:
                        previousPage
                            .finalReplacements,
                    animationVariant:
                        previousPage
                            .pageIndex,
                    progress:
                        wholePageFoldProgress,
                    cropByImageIdentity:
                        cropByImageIdentity
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
                cropTransforms
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

private func loadDroppedFileURLs(
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
    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var accountManager = AccountManager.shared
    @ObservedObject private var remoteStatus = AppRemoteStatus.shared
    @Binding var isProfileModalPresented: Bool
    @State private var isRocketsBriefHovered = false
    @State private var isSupportHovered = false
    @State private var isFundMissionHovered = false
    @State private var isDisclaimerHovered = false
    @State private var isDisclaimerNoticePresented = false

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 14) {
                    HStack(spacing: 0) {
                        Text("Brief")
                            .font(.custom("Unbounded", size: 28).weight(.black))
                            .foregroundColor(AppColors.ink)
                            .tracking(-2.4)

                        Text("Show")
                            .font(.custom("Unbounded", size: 28).weight(.black))
                            .foregroundColor(AppColors.inkSecondary)
                            .tracking(-2.4)
                    }

                    HStack(spacing: 8) {
                        ThemeToggleButton(theme: .white, selected: $themeManager.current)
                        ThemeToggleButton(theme: .buttery, selected: $themeManager.current)
                    }
                }

                Text("Create high-resolution photo slideshows with music.")
                    .font(.custom("Figtree", size: 13).weight(.medium))
                    .foregroundColor(AppColors.muted)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 6) {
                HStack(spacing: 12) {
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
                                .frame(width: 15, height: 15)

                            Text("RocketsBrief")
                        }
                        .frame(height: 15)
                    }
                    .buttonStyle(HeaderLinkButtonStyle())
                .overlay(alignment: .topTrailing) {
                    if isRocketsBriefHovered {
                        RocketsBriefHoverCard()
                            .offset(x: -6, y: 48)
                            .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .topTrailing)))
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
                            .frame(width: 15, height: 15)

                        Text("Support")
                    }
                    .frame(height: 15)
                }
                .buttonStyle(HeaderLinkButtonStyle())
                .overlay(alignment: .topTrailing) {
                    if isSupportHovered {
                        SupportHoverCard()
                            .offset(x: -6, y: 48)
                            .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .topTrailing)))
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
                        .frame(width: 86, height: 15)
                        .fixedSize(horizontal: false, vertical: false)
                }
                .buttonStyle(HeaderLinkButtonStyle())
                .overlay(alignment: .topTrailing) {
                    if isFundMissionHovered {
                        FundMissionHoverCard()
                            .offset(x: -6, y: 48)
                            .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .topTrailing)))
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
                        .frame(width: 86, height: 15)
                        .fixedSize(horizontal: false, vertical: false)
                }
                .buttonStyle(HeaderLinkButtonStyle())
                .overlay(alignment: .topTrailing) {
                    if isDisclaimerHovered {
                        DisclaimerHoverCard()
                            .offset(x: -6, y: 48)
                            .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .topTrailing)))
                            .zIndex(300)
                    }
                }
                .onHover { hovering in
                    withAnimation(.linear(duration: 0.12)) {
                        isDisclaimerHovered = hovering
                    }
                }

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
        .sheet(isPresented: $isDisclaimerNoticePresented) {
            DisclaimerNoticeModal()
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

            Text("Read the usage notice for BriefShow and RocketsBrief products, including user responsibility, voluntary support terms, limitations, and prohibited use.")
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

struct DisclaimerNoticeModal: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @Environment(\.dismiss) private var dismiss

    private let noticeSections: [(String, String)] = [
        (
            "Free creative tool",
            "BriefShow is provided as a free creative tool by RocketsBrief. It is offered “as is” and “as available,” without guarantees that it will always be error-free, uninterrupted, or suitable for every specific purpose."
        ),
        (
            "User responsibility",
            "You are responsible for the images, music, files, prompts, content, exports, and any other materials you upload, create, process, publish, share, or use through BriefShow or any RocketsBrief product."
        ),
        (
            "Prohibited use",
            "You may not use BriefShow, RocketsBrief, or any related tool to create, promote, distribute, or support unlawful, harmful, fraudulent, abusive, infringing, or prohibited activity. This includes scams, phishing, malware, spam, impersonation, copyright infringement, illegal products or services, or any activity that violates applicable laws, third-party rights, platform rules, or payment processor policies."
        ),
        (
            "Review before use",
            "Any output created with BriefShow should be reviewed by you before publishing, selling, sharing, or relying on it. RocketsBrief does not guarantee legal compliance, business results, earnings, conversions, or that any output will meet a specific requirement."
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
            "Future changes to BriefShow",
            "RocketsBrief may change, add, remove, lock, or discontinue any feature, theme, or part of BriefShow at any time, without notice. This includes requiring a free account sign-up to continue using BriefShow, and introducing paid features, subscriptions, or pricing for BriefShow in the future. By continuing to use BriefShow, you agree that these changes may happen at any time."
        ),
        (
            "Copyright and ownership",
            "BriefShow is created by and is the property of the RocketsBrief Team. You are welcome to share or recommend BriefShow to others free of charge. You may not sell, resell, rebrand, redistribute for payment, or claim ownership of BriefShow, in whole or in part."
        ),
        (
            "Account data and email use",
            "If BriefShow ever requires a free account to continue use, your email address is stored securely using Supabase, a third-party database provider. RocketsBrief does not have access to your email inbox or password, and never asks for them. By creating an account, you agree that RocketsBrief may use your email address to send you marketing material, product updates, and promotional messages about RocketsBrief and its products."
        ),
        (
            "Usage analytics",
            "BriefShow shares only two basic metrics with RocketsBrief: how many videos have been exported, and how many separate machines run BriefShow. To protect your privacy, the app generates a strictly randomized installation ID that has no connection to your hardware, device serial numbers, or network configuration. Neither count includes your files, photos, music, exported videos, or any personal information — and this metric is completely separate from, and in addition to, the email address you provide only if you create an account."
        )
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Disclaimer & Usage Notice")
                        .font(.custom("Figtree", size: 24).weight(.semibold))
                        .foregroundColor(AppColors.ink)

                    Text("For BriefShow and RocketsBrief products")
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

                    Text("By using BriefShow, you agree to this entire Disclaimer & Usage Notice, including that you are responsible for your own use of the tool and any content or output you create with it.")
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
                    && visualTheme != .origami {

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

                if visualTheme == .origami {
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
        visualTheme == .magazine || visualTheme == .magazineFamily || visualTheme == .magazineCouples
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
        case .magazineFamily:
            return "Magazine Family will use warmer layouts for group and family photos."
        case .magazineCouples:
            return "Magazine Couples will use romantic layouts for portraits, weddings, and trips."
        case .origami:
            return "Kirigami will use geometric panel-style pages inspired by folded paper movement."
        case .imagination:
            return "Kanata brings photos to life as 3D cards emerging from deep space."
        }
    }

    private var timingModeHelperText: String {
        if visualTheme == .origami {
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
    @Binding var cropTransforms: [URL: MagazinePhotoCrop]
    let onClose: () -> Void

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
            }
            .frame(width: 560)

            if let range = currentPageRange {
                Group {
                    if visualTheme == .origami {
                        OrigamiPreviewPage(
                            images: Array(previewImages[range]),
                            slotReplacementImages: [:],
                            activeSwapImages: [:],
                            activeSwapStyles: [:],
                            swapProgress: 1,
                            activePhotoName: "",
                            showsPhotoName: false,
                            transitionProgress: 1,
                            animationVariant: currentPageIndex,
                            cropByImageIdentity: cropByImageIdentity,
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
                    title: "Kirigami",
                    subtitle: "Geometric folded-panel movement and page layouts.",
                    isSelected: selectedTheme == .origami,
                    isLocked: false
                ) {
                    selectedTheme = .origami
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
        visualTheme == .magazine || visualTheme == .magazineFamily || visualTheme == .magazineCouples
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
                    .opacity(previewRenderMode == .renderedVideo && previewVideoPlayer != nil ? 1 : 0)
                    .allowsHitTesting(previewRenderMode == .renderedVideo && previewVideoPlayer != nil)
                    .ignoresSafeArea()

                fullscreenCloseButton
                    .position(x: proxy.size.width - 44, y: 44)
                    .zIndex(1000)

                // In video mode, AVKit's own play/pause/scrub overlay
                // (part of VideoPlayer above) replaces these custom controls.
                if !(previewRenderMode == .renderedVideo && previewVideoPlayer != nil) {
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
        if previewRenderMode == .renderedVideo && previewVideoPlayer != nil {
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
                        cropByImageIdentity: photoCropByImageIdentity
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
            } else if visualTheme == .origami {
                ZStack {
                    OrigamiPreviewPage(
                        images: themedPreviewImages,
                        slotReplacementImages: origamiSlotReplacementImages,
                        activeSwapImages: origamiActiveSwapImages,
                        activeSwapStyles: origamiActiveSwapStyles,
                        swapProgress: origamiSwapProgress,
                        activePhotoName: activePhotoName,
                        showsPhotoName: false,
                        transitionProgress: transitionProgress,
                        animationVariant: origamiAnimationSeed,
                        cropByImageIdentity: photoCropByImageIdentity
                    )

                    if !previousOrigamiPageImages.isEmpty {
                        OrigamiWholePageHalfFoldOverlay(
                            images: previousOrigamiPageImages,
                            slotReplacementImages:
                                previousOrigamiPageReplacements,
                            animationVariant:
                                previousOrigamiPageAnimationVariant,
                            progress:
                                origamiWholePageFoldProgress,
                            cropByImageIdentity: photoCropByImageIdentity
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

    var body: some View {
        VStack(spacing: 0) {
            Text(label)
                .font(.custom("Figtree", size: 11).weight(.medium))
                .foregroundColor(textColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                )

            HoverTooltipArrow()
                .fill(.regularMaterial)
                .frame(width: 11, height: 6)
                .offset(y: -1)
        }
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
        Array(images.prefix(6))
    }

    private var pagePhotoCount: Int {
        pageImages.count
    }

    private var layoutVariant: Int {
        layoutSeed % 2
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
        switch pagePhotoCount {
        case 2:
            return hasMixedLandscapeAndPortrait ? [.wide, .tall] : [.flex, .flex]

        case 3:
            if portraitIndexes.count >= 2 {
                return [.tall, .tall, .flex]
            }

            if hasMixedLandscapeAndPortrait {
                return [.wide, .wide, .tall]
            }

            return [.wide, .flex, .flex]

        case 4:
            if portraitIndexes.count >= 2 {
                return [.tall, .tall, .wide, .wide]
            }

            if hasMixedLandscapeAndPortrait {
                return [.tall, .wide, .wide, .wide]
            }

            return [.wide, .wide, .wide, .wide]

        case 5:
            if portraitIndexes.count >= 2 {
                return [.tall, .tall, .wide, .wide, .wide]
            }

            if hasMixedLandscapeAndPortrait {
                return [.tall, .wide, .wide, .wide, .wide]
            }

            return [.wide, .wide, .wide, .wide, .wide]

        default:
            if portraitIndexes.count >= 3 {
                return [.tall, .tall, .tall, .wide, .wide, .wide]
            }

            if portraitIndexes.count == 2 {
                return [.wide, .wide, .wide, .tall, .wide, .tall]
            }

            if portraitIndexes.count == 1 {
                return [.tall, .wide, .wide, .wide, .wide, .wide]
            }

            return [.wide, .wide, .wide, .wide, .wide, .wide]
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
                .background(Color.white)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }

    @ViewBuilder
    private func magazineTemplate(width: CGFloat, height: CGFloat, gap: CGFloat) -> some View {
        switch pagePhotoCount {
        case 0:
            Color.white

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

    @ViewBuilder
    private func twoImageMagazineTemplate(width: CGFloat, height: CGFloat, gap: CGFloat) -> some View {
        if hasMixedLandscapeAndPortrait {
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
        if portraitIndexes.count >= 2 {
            HStack(spacing: gap) {
                tile(slot: 0, revealOrder: 0)
                tile(slot: 1, revealOrder: 1)
                tile(slot: 2, revealOrder: 2)
            }
        } else if hasMixedLandscapeAndPortrait {
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
        if portraitIndexes.count >= 2 {
            HStack(spacing: gap) {
                tile(slot: 0, revealOrder: 0)
                tile(slot: 1, revealOrder: 1)

                VStack(spacing: gap) {
                    tile(slot: 2, revealOrder: 2)
                    tile(slot: 3, revealOrder: 3)
                }
                .frame(width: (width - gap * 2) * 0.44)
            }
        } else if hasMixedLandscapeAndPortrait {
            HStack(spacing: gap) {
                tile(slot: 0, revealOrder: 0)
                    .frame(width: (width - gap) * 0.34)

                VStack(spacing: gap) {
                    tile(slot: 1, revealOrder: 1)
                    tile(slot: 2, revealOrder: 2)
                    tile(slot: 3, revealOrder: 3)
                }
            }
        } else if layoutVariant == 0 {
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
        if portraitIndexes.count >= 2 {
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
        } else if hasMixedLandscapeAndPortrait {
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
        if portraitIndexes.count >= 3 {
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
        } else if portraitIndexes.count == 2 {
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
        } else if portraitIndexes.count == 1 {
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
        } else if layoutVariant == 0 {
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
            Color.white
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
                Color.white

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

struct OrigamiPreviewPage: View {
    let images: [NSImage]
    let slotReplacementImages: [Int: NSImage]
    let activeSwapImages: [Int: NSImage]
    let activeSwapStyles: [Int: Int]
    let swapProgress: Double
    let activePhotoName: String
    let showsPhotoName: Bool
    let transitionProgress: Double
    let animationVariant: Int
    let cropByImageIdentity: [ObjectIdentifier: MagazinePhotoCrop]
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
        Array(images.prefix(6))
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
            if portraitCount == 2 {
                return .twoPortrait
            }

            // Only stack into tall, ultra-wide slots when both
            // photos are actually wide/panoramic. Moderate
            // landscape shots (4:3, 3:2, and similar) belong
            // side by side, or a stacked layout would crop off
            // most of their width.
            if wideCount == 2 {
                return .twoLandscape
            }

            if landscapeCount == 2 {
                return .twoLandscapeModerate
            }

            return .twoMixed

        case 3:
            if portraitCount == 3 {
                return .threePortrait
            }

            if landscapeCount == 3 {
                return .threeLandscape
            }

            return .threeMixed

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
            .shadow(
                color: Color.black.opacity(
                    0.42
                    * min(
                        1,
                        abs(angle) / 90
                    )
                ),
                radius: 10,
                x: 0,
                y: 3
            )
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

                        Color.black
                            .opacity(
                                (
                                    1
                                    - localProgress
                                )
                                * 0.30
                            )
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
                    .shadow(
                        color:
                            Color.black.opacity(
                                (
                                    1
                                    - localProgress
                                )
                                * 0.48
                            ),
                        radius:
                            12
                            * CGFloat(
                                1
                                - localProgress
                            ),
                        x:
                            normalizedAnimationVariant
                                == 0
                            ? (
                                slot.isMultiple(
                                    of: 2
                                )
                                ? -8
                                : 8
                            )
                            : 0,
                        y:
                            normalizedAnimationVariant
                                == 1
                            ? (
                                slot.isMultiple(
                                    of: 2
                                )
                                ? -8
                                : 8
                            )
                            : 5
                    )
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

        if portraitCount >= 2 {
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

        if portraitCount >= 1 {
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

        if portraitCount >= 2 {
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
        } else if portraitCount == 1 {
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
    let slotReplacementImages: [Int: NSImage]
    let animationVariant: Int
    let progress: Double
    let cropByImageIdentity: [ObjectIdentifier: MagazinePhotoCrop]

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
                    cropByImageIdentity
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

    var body: some View {
        HStack(spacing: 6) {
            pill(
                .liveFPS30,
                label: "30",
                help: "Live preview at 30fps. Lighter on older or weaker Macs, at the cost of slightly less fluid motion."
            )

            pill(
                .liveFPS60,
                label: "60",
                help: "Live preview at 60fps (default). The smoothest motion, but can stutter on weaker hardware."
            )

            pill(
                .renderedVideo,
                systemImage: "film",
                help: "Prepares the slideshow as a real 1080p video once, then plays that back. Never stutters, even on weak hardware — takes a moment to prepare before it starts playing."
            )
        }
    }

    @ViewBuilder
    private func pill(_ target: PreviewRenderMode, label: String, help: String) -> some View {
        pillButton(target: target, help: help) {
            Text(label)
                .font(.custom("Figtree", size: 11).weight(.bold))
        }
    }

    @ViewBuilder
    private func pill(_ target: PreviewRenderMode, systemImage: String, help: String) -> some View {
        pillButton(target: target, help: help) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .bold))
        }
    }

    @ViewBuilder
    private func pillButton<Label: View>(
        target: PreviewRenderMode,
        help: String,
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
        .help(help)
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
        visualTheme == .magazine || visualTheme == .magazineFamily || visualTheme == .magazineCouples
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
                        .opacity(previewRenderMode == .renderedVideo && previewVideoPlayer != nil ? 1 : 0)
                        .allowsHitTesting(previewRenderMode == .renderedVideo && previewVideoPlayer != nil)

                    if previewRenderMode == .renderedVideo {
                        if previewVideoPlayer != nil {
                            EmptyView()
                        } else if isPreparingPreviewVideo {
                            VStack(spacing: 12) {
                                ProgressView(value: previewVideoPrepareProgress)
                                    .frame(width: 180)

                                Text("Preparing 1080p preview video… \(Int(previewVideoPrepareProgress * 100))%")
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

                                Text("Add photos to prepare a 1080p preview video.")
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
                                    cropByImageIdentity: photoCropByImageIdentity
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
                        } else if visualTheme == .origami {
                            ZStack {
                                OrigamiPreviewPage(
                                    images: themedPreviewImages,
                                    slotReplacementImages: origamiSlotReplacementImages,
                                    activeSwapImages: origamiActiveSwapImages,
                                    activeSwapStyles: origamiActiveSwapStyles,
                                    swapProgress: origamiSwapProgress,
                                    activePhotoName: activePhotoName,
                                    showsPhotoName: true,
                                    transitionProgress: transitionProgress,
                                    animationVariant: origamiAnimationSeed,
                                    cropByImageIdentity: photoCropByImageIdentity
                                )

                                if !previousOrigamiPageImages.isEmpty {
                                    OrigamiWholePageHalfFoldOverlay(
                                        images: previousOrigamiPageImages,
                                        slotReplacementImages:
                                            previousOrigamiPageReplacements,
                                        animationVariant:
                                            previousOrigamiPageAnimationVariant,
                                        progress:
                                            origamiWholePageFoldProgress,
                                        cropByImageIdentity: photoCropByImageIdentity
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

                            Text("Preparing photo previews…")
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
                    if previewRenderMode != .renderedVideo {
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
                        previewRenderMode == .renderedVideo
                            ? "Video mode uses the play/pause/scrub controls built into the player above."
                            : "Full Screen shows the true, exported look of your slideshow."
                    )
                        .font(.custom("Figtree", size: 10.5).weight(.regular))
                        .foregroundColor(AppColors.muted)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Spacer(minLength: 8)

                    if previewRenderMode != .renderedVideo {
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
            .overlayPreferenceValue(PreviewTooltipPreferenceKey.self) { items in
                GeometryReader { proxy in
                    ForEach(items) { item in
                        let rect = proxy[item.anchor]
                        HoverTooltipBubble(label: item.label, textColor: AppColors.ink)
                            .position(x: rect.midX, y: rect.minY - 26)
                    }
                }
            }
            .zIndex(50)

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
/// (see `CenterPreviewPanel`'s `.overlayPreferenceValue`), which is
/// guaranteed to paint above everything below it.
private struct PreviewTooltipAnchor: Identifiable {
    let id: UUID
    let label: String
    let anchor: Anchor<CGRect>
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

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: isHovered ? .semibold : .semibold))
                .foregroundColor(isHovered ? AppColors.hoverInk : AppColors.ink.opacity(0.8))
                .frame(width: 18, height: 18)
                .background(Color.white.opacity(0.48))
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
        .background(isHovered ? Color.white.opacity(0.42) : Color.white.opacity(0.28))
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

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: hasTrack ? "music.note" : "plus")
                    .font(.system(size: 10, weight: isHovered ? .semibold : .semibold))
                    .foregroundColor(isHovered ? AppColors.hoverInk : AppColors.ink.opacity(0.8))
                    .frame(width: 18, height: 18)
                    .background(Color.white.opacity(0.48))
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
            .background(isHovered ? Color.white.opacity(0.42) : Color.white.opacity(0.28))
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
            .scaleEffect(configuration.isPressed ? 0.985 : (isHovered ? 1.025 : 1))
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
            : AppColors.ink.opacity(0.7)
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

#Preview {
    ContentView()
}

