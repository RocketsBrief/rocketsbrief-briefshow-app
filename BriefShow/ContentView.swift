import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Combine
import AVFoundation
import ImageIO
import CoreGraphics

enum SlideshowTimingMode: String {
    case followMusic = "Follow Music"
    case customSpeed = "Custom Speed"
}

enum SlideshowTransitionStyle: String {
    case fade = "Fade"
    case blink = "Blink"
}

enum SlideshowVisualTheme: String {
    case singleFade = "Single Fade"
    case singleBlink = "Single Blink"
    case magazine = "Magazine"
    case magazineFamily = "Magazine Family"
    case magazineCouples = "Magazine Couples"
    case origami = "Origami"
    case magazineToon = "Magazine Toon"
    case origamiToon = "Origami Toon"
}

struct ContentView: View {
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
    @State private var timingMode: SlideshowTimingMode = .followMusic
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
    @State private var isExportingVideo: Bool = false
    @State private var exportStatusText: String?
    @State private var activePhotoIndex: Int = 0
    @State private var previousPhotoIndex: Int?
    @State private var transitionProgress: Double = 1
    @State private var magazineRevealElapsedSeconds: Double = 0
    @State private var magazinePageIndex: Int = 0
    @State private var origamiPageIndex: Int = 0

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
    @State private var previewElapsedSeconds: Double = 0
    @State private var previewTotalElapsedSeconds: Double = 0
    @State private var isFullScreenPreviewPresented: Bool = false
    @State private var savedWindowFrame: NSRect?
    @State private var savedPresentationOptions: NSApplication.PresentationOptions = []
    @State private var savedTitlebarAppearsTransparent: Bool = false
    @State private var savedTitleVisibility: NSWindow.TitleVisibility = .visible
    @State private var savedWindowStyleMask: NSWindow.StyleMask = []
    @State private var savedWindowLevel: NSWindow.Level = .normal
    @State private var savedCollectionBehavior: NSWindow.CollectionBehavior = []

    var body: some View {
        ZStack {
            Color(red: 0.957, green: 0.937, blue: 0.910)
                .ignoresSafeArea()

            VStack(spacing: 10) {
                HeaderView()

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
                        visualTheme: $visualTheme
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
                        magazinePageSlotCount: currentPreviewPageSlotCount,
                        origamiAnimationSeed: origamiPageIndex,
                        isPreviewPlaying: isPreviewPlaying,
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
                        }
                    )
                    RightExportPanel(
                        selectedResolution: $selectedExportResolution,
                        selectedMusicURL: selectedMusicURL,
                        selectedMusicCount: selectedMusicTrackCount,
                        canExport: !selectedPhotoURLs.isEmpty && !isPreparingPhotos,
                        isExporting: isExportingVideo,
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
                        .foregroundColor(Color(red: 0.390, green: 0.390, blue: 0.390).opacity(0.62))
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
                    visualTheme: visualTheme,
                    timeCounterText: timeCounterText,
                    transitionStyle: transitionStyle,
                    transitionProgress: usesMagazineTheme ? magazineRevealProgress : transitionProgress,
                    magazineImageFadeSeconds: magazineImageFadeSeconds,
                    magazineImageDelaySeconds: magazineImageDelaySeconds,
                    magazineLayoutSeed: magazinePageIndex,
                    magazinePageSlotCount: currentPreviewPageSlotCount,
                    origamiAnimationSeed: origamiPageIndex,
                    isPreviewPlaying: isPreviewPlaying,
                    onTogglePreview: togglePreview,
                    onStartFromBeginning: startPreviewFromBeginning,
                    onClose: {
                        closeCinemaFullScreenPreview()
                    }
                )
                .ignoresSafeArea()
                .zIndex(9999)
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
        .onReceive(Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()) { _ in
            advancePreviewIfNeeded(delta: 1.0 / 60.0)
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

    private var magazinePageDuration: Double {
        let fadeSeconds = max(0.05, magazineImageFadeSeconds)
        let delaySeconds = max(0, magazineImageDelaySeconds)
        let pageHoldSeconds = timingMode == .customSpeed ? max(0, secondsPerPhoto) : 0

        // 6 image slots on one magazine page:
        // image 1 starts at 0, each next image starts after Start Delay.
        // Seconds / Page is extra hold time after all images are visible.
        return max(1, fadeSeconds + (delaySeconds * 5) + pageHoldSeconds)
    }

    private var magazineLayoutVariant: Int {
        magazinePageIndex % 2
    }

    private func plannedMagazineSlotCount(pageIndex: Int, remainingPhotos: Int) -> Int {
        guard remainingPhotos > 0 else {
            return 0
        }

        let photoSeed = selectedPhotoURLs.enumerated().reduce(0) { total, item in
            let nameScore = item.element.lastPathComponent.unicodeScalars.reduce(0) { partial, scalar in
                partial + Int(scalar.value)
            }

            return total + ((item.offset + 1) * nameScore)
        }

        let safeSeed = abs(photoSeed)

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

    private var origamiInternalHoldDuration: Double {
        max(
            1.0,
            min(
                15.0,
                origamiInternalHoldSeconds
            )
        )
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

            // All replacement images move together
            // as one simultaneous animation batch.
            totalSwaps +=
                replacementCount > 0
                ? 1
                : 0

            // Hold before the simultaneous batch and
            // hold once more before the complete page fold.
            totalHolds +=
                replacementCount > 0
                ? 2
                : 1

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
                currentPhotoDuration * 0.30
            )
        )
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

            return max(0.5, audioPlayer.duration / Double(selectedPhotoURLs.count))
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

            return
                Double(metrics.holds)
                    * origamiInternalHoldDuration
                + Double(metrics.swaps)
                    * origamiInternalSwapDuration
                + Double(metrics.pages)
                    * origamiTransitionDuration
        }

        if timingMode == .followMusic, let audioPlayer {
            return max(0, audioPlayer.duration)
        }

        return currentPhotoDuration * Double(selectedPhotoURLs.count)
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
            }
        } else {
            audioPlayer?.pause()
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
                    isPreviewPlaying = false

                    previewTotalElapsedSeconds =
                        totalPreviewDuration

                    audioPlayer?.pause()
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

        let nextIndex =
            activePhotoIndex
            + (
                usesMagazineTheme
                ? currentMagazinePageSlotCount
                : 1
            )

        if nextIndex >= selectedPhotoURLs.count {
            if shouldLoopPreview {
                previewTotalElapsedSeconds = 0
                audioPlayer?.volume = 0
                audioPlayer?.currentTime = 0
                audioPlayer?.play()
                moveToPhoto(at: 0)
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
        }
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

            DispatchQueue.main.async {
                withAnimation(
                    .easeInOut(
                        duration: duration
                    )
                ) {
                    origamiWholePageFoldProgress = 1
                }
            }

            DispatchQueue.main.asyncAfter(
                deadline:
                    .now()
                    + duration
                    + 0.04
            ) {
                isOrigamiWholePageFoldAnimating = false

                guard activePhotoIndex
                        == newIndex
                else {
                    return
                }

                var cleanupTransaction =
                    Transaction()

                cleanupTransaction.animation = nil

                withTransaction(
                    cleanupTransaction
                ) {
                    previousOrigamiPageImages = []
                    previousOrigamiPageReplacements = [:]
                    previousPhotoIndex = nil
                    origamiWholePageFoldProgress = 1
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
            var preparedImages: [NSImage] = []

            for url in sortedURLs {
                if let image = makePreviewImage(from: url) {
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

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = "BriefShow-\(selectedExportResolution).mp4"

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
        exportStatusText = "Exporting video…"
        isPreviewPlaying = false
        audioPlayer?.pause()

        let photoURLs = selectedPhotoURLs
        let musicURLs = selectedMusicURLs
        let resolution = selectedExportResolution
        let durationPerPhoto = max(0.25, currentPhotoDuration)
        let selectedTransitionStyle = transitionStyle
        let selectedFadeDuration = fadeDuration
        let selectedMusicFadeIn = musicFadeInSeconds
        let selectedMusicFadeOut = musicFadeOutSeconds

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let videoOnlyURL = musicURLs.isEmpty ? outputURL : temporaryVideoURL(for: outputURL)

                try renderSlideshowVideo(
                    photoURLs: photoURLs,
                    outputURL: videoOnlyURL,
                    resolutionName: resolution,
                    secondsPerPhoto: durationPerPhoto,
                    transitionStyle: selectedTransitionStyle,
                    fadeDuration: selectedFadeDuration
                )

                if !musicURLs.isEmpty {
                    try muxVideoWithMusic(
                        videoURL: videoOnlyURL,
                        musicURLs: musicURLs,
                        outputURL: outputURL,
                        fadeInSeconds: selectedMusicFadeIn,
                        fadeOutSeconds: selectedMusicFadeOut,
                        preferHEVC: resolution == "Original"
                    )

                    try? FileManager.default.removeItem(at: videoOnlyURL)
                }

                DispatchQueue.main.async {
                    isExportingVideo = false
                    exportStatusText = "Export complete: \(outputURL.lastPathComponent)"
                }
            } catch {
                DispatchQueue.main.async {
                    isExportingVideo = false
                    exportStatusText = "Export failed: \(error.localizedDescription)"
                }
            }
        }
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


private func renderSlideshowVideo(
    photoURLs: [URL],
    outputURL: URL,
    resolutionName: String,
    secondsPerPhoto: Double,
    transitionStyle: SlideshowTransitionStyle,
    fadeDuration: Double
) throws {
    if FileManager.default.fileExists(atPath: outputURL.path) {
        try FileManager.default.removeItem(at: outputURL)
    }

    let renderSize = exportRenderSize(for: resolutionName, photoURLs: photoURLs)
    let fps: Int32 = 30
    let frameDuration = CMTime(value: 1, timescale: fps)
    let framesPerPhoto = max(1, Int(round(secondsPerPhoto * Double(fps))))
    let fadeFrames = max(1, min(
        Int(round(fadeDuration * Double(fps))),
        max(1, Int(Double(framesPerPhoto) * 0.45))
    ))

    let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)

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

private func muxVideoWithMusic(
    videoURL: URL,
    musicURLs: [URL],
    outputURL: URL,
    fadeInSeconds: Double,
    fadeOutSeconds: Double,
    preferHEVC: Bool
) throws {
    if FileManager.default.fileExists(atPath: outputURL.path) {
        try FileManager.default.removeItem(at: outputURL)
    }

    let videoAsset = AVURLAsset(url: videoURL)
    let composition = AVMutableComposition()

    guard let sourceVideoTrack = videoAsset.tracks(withMediaType: .video).first,
          let compositionVideoTrack = composition.addMutableTrack(
              withMediaType: .video,
              preferredTrackID: kCMPersistentTrackID_Invalid
          ) else {
        throw BriefShowExportError.couldNotExportWithAudio
    }

    let videoDuration = videoAsset.duration
    try compositionVideoTrack.insertTimeRange(
        CMTimeRange(start: .zero, duration: videoDuration),
        of: sourceVideoTrack,
        at: .zero
    )
    compositionVideoTrack.preferredTransform = sourceVideoTrack.preferredTransform

    var audioMix: AVMutableAudioMix?

    let musicSources: [(track: AVAssetTrack, duration: CMTime)] = musicURLs.compactMap { url in
        let asset = AVURLAsset(url: url)

        guard let track = asset.tracks(withMediaType: .audio).first,
              asset.duration > .zero else {
            return nil
        }

        return (track, asset.duration)
    }

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

            try compositionAudioTrack.insertTimeRange(
                CMTimeRange(start: .zero, duration: audioSegmentDuration),
                of: source.track,
                at: insertedAudioDuration
            )

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

    let compatiblePresets = AVAssetExportSession.exportPresets(compatibleWith: composition)
    let preferredPreset: String

    if preferHEVC, compatiblePresets.contains(AVAssetExportPresetHEVCHighestQuality) {
        preferredPreset = AVAssetExportPresetHEVCHighestQuality
    } else {
        preferredPreset = AVAssetExportPresetHighestQuality
    }

    print("BriefShow mux preset:", preferredPreset, "preferHEVC:", preferHEVC)

    guard let exportSession = AVAssetExportSession(
        asset: composition,
        presetName: preferredPreset
    ) else {
        throw BriefShowExportError.couldNotExportWithAudio
    }

    exportSession.outputURL = outputURL
    exportSession.outputFileType = .mp4
    exportSession.audioMix = audioMix
    exportSession.shouldOptimizeForNetworkUse = true

    let semaphore = DispatchSemaphore(value: 0)
    exportSession.exportAsynchronously {
        semaphore.signal()
    }
    semaphore.wait()

    if exportSession.status != .completed {
        throw exportSession.error ?? BriefShowExportError.couldNotExportWithAudio
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
    @State private var isRocketsBriefHovered = false
    @State private var isFundMissionHovered = false
    @State private var isDisclaimerHovered = false
    @State private var isDisclaimerNoticePresented = false

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 0) {
                    Text("Brief")
                        .font(.custom("Unbounded", size: 28).weight(.black))
                        .foregroundColor(Color(red: 0.315, green: 0.340, blue: 0.390))
                        .tracking(-2.4)

                    Text("Show")
                        .font(.custom("Unbounded", size: 28).weight(.black))
                        .foregroundColor(Color(red: 0.500, green: 0.525, blue: 0.575))
                        .tracking(-2.4)
                }

                Text("Create high-resolution photo slideshows with music.")
                    .font(.custom("Figtree", size: 13).weight(.medium))
                    .foregroundColor(Color(red: 0.390, green: 0.390, blue: 0.390))
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
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Need a website, web app, or mobile app?")
                .font(.custom("Figtree", size: 14).weight(.medium))
                .foregroundColor(Color(red: 0.315, green: 0.340, blue: 0.390))

            Text("Visit RocketsBrief and turn your idea into a hosted preview from just $5.")
                .font(.custom("Figtree", size: 11).weight(.regular))
                .foregroundColor(Color(red: 0.390, green: 0.390, blue: 0.390))
                .fixedSize(horizontal: false, vertical: true)

            Text("Click RocketsBrief to open the site.")
                .font(.custom("Figtree", size: 10.5).weight(.medium))
                .foregroundColor(Color(red: 0.000, green: 0.610, blue: 0.760))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(width: 270, alignment: .leading)
        .background(Color(red: 0.957, green: 0.937, blue: 0.910))
        .overlay(
            RoundedRectangle(cornerRadius: 26)
                .stroke(Color(red: 0.820, green: 0.780, blue: 0.710), lineWidth: 3)
        )
        .clipShape(RoundedRectangle(cornerRadius: 26))
        .shadow(color: Color.black.opacity(0.13), radius: 18, x: 0, y: 10)
    }
}

struct FundMissionHoverCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Enjoying BriefShow?")
                .font(.custom("Figtree", size: 14).weight(.medium))
                .foregroundColor(Color(red: 0.315, green: 0.340, blue: 0.390))

            Text("BriefShow is free to use. Your support helps RocketsBrief build more AI-powered tools, creative apps, and digital products — including some that may stay free for the community.")
                .font(.custom("Figtree", size: 11).weight(.regular))
                .foregroundColor(Color(red: 0.390, green: 0.390, blue: 0.390))
                .fixedSize(horizontal: false, vertical: true)

            Text("Click Fund Mission to support RocketsBrief.")
                .font(.custom("Figtree", size: 10.5).weight(.medium))
                .foregroundColor(Color(red: 0.000, green: 0.610, blue: 0.760))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(width: 285, alignment: .leading)
        .background(Color(red: 0.957, green: 0.937, blue: 0.910))
        .overlay(
            RoundedRectangle(cornerRadius: 26)
                .stroke(Color(red: 0.820, green: 0.780, blue: 0.710), lineWidth: 3)
        )
        .clipShape(RoundedRectangle(cornerRadius: 26))
        .shadow(color: Color.black.opacity(0.13), radius: 18, x: 0, y: 10)
    }
}

struct DisclaimerHoverCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Disclaimer & Usage Notice")
                .font(.custom("Figtree", size: 14).weight(.medium))
                .foregroundColor(Color(red: 0.315, green: 0.340, blue: 0.390))

            Text("Read the usage notice for BriefShow and RocketsBrief products, including user responsibility, voluntary support terms, limitations, and prohibited use.")
                .font(.custom("Figtree", size: 11).weight(.regular))
                .foregroundColor(Color(red: 0.390, green: 0.390, blue: 0.390))
                .fixedSize(horizontal: false, vertical: true)

            Text("Click Disclaimer to read the full notice.")
                .font(.custom("Figtree", size: 10.5).weight(.medium))
                .foregroundColor(Color(red: 0.000, green: 0.610, blue: 0.760))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(width: 315, alignment: .leading)
        .background(Color(red: 0.957, green: 0.937, blue: 0.910))
        .overlay(
            RoundedRectangle(cornerRadius: 26)
                .stroke(Color(red: 0.820, green: 0.780, blue: 0.710), lineWidth: 3)
        )
        .clipShape(RoundedRectangle(cornerRadius: 26))
        .shadow(color: Color.black.opacity(0.13), radius: 18, x: 0, y: 10)
    }
}

struct DisclaimerNoticeModal: View {
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
        )
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Disclaimer & Usage Notice")
                        .font(.custom("Figtree", size: 24).weight(.semibold))
                        .foregroundColor(Color(red: 0.315, green: 0.340, blue: 0.390))

                    Text("For BriefShow and RocketsBrief products")
                        .font(.custom("Figtree", size: 12.5).weight(.regular))
                        .foregroundColor(Color(red: 0.390, green: 0.390, blue: 0.390))
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
                                .foregroundColor(Color(red: 0.315, green: 0.340, blue: 0.390))

                            Text(section.1)
                                .font(.custom("Figtree", size: 12).weight(.regular))
                                .foregroundColor(Color(red: 0.390, green: 0.390, blue: 0.390))
                                .lineSpacing(3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    Text("By using BriefShow or supporting RocketsBrief, you agree that you are responsible for your own use of the tool and any content or output you create with it.")
                        .font(.custom("Figtree", size: 12).weight(.medium))
                        .foregroundColor(Color(red: 0.000, green: 0.610, blue: 0.760))
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
        .frame(width: 640, height: 620)
        .background(Color(red: 0.957, green: 0.937, blue: 0.910))
    }
}

struct LeftImportPanel: View {
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

    @State private var isThemePickerPresented = false
    @State private var isThemeButtonHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PanelTitle(title: "Settings", subtitle: "Timing and transitions")

            VStack(alignment: .leading, spacing: 8) {
                Text("Slideshow Settings")
                    .font(.custom("Figtree", size: 13).weight(.medium))
                    .foregroundColor(Color(red: 0.315, green: 0.340, blue: 0.390))

                VStack(alignment: .leading, spacing: 6) {
                    Text("Theme")
                        .font(.custom("Figtree", size: 11.5).weight(.medium))
                        .foregroundColor(Color(red: 0.390, green: 0.390, blue: 0.390))

                    Button {
                        isThemePickerPresented.toggle()
                    } label: {
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(visualTheme.rawValue)
                                    .font(.custom("Figtree", size: 12.5).weight(.medium))
                                    .foregroundColor(isThemeButtonHovered ? Color(red: 0.000, green: 0.610, blue: 0.760) : Color(red: 0.315, green: 0.340, blue: 0.390))
                                    .scaleEffect(isThemeButtonHovered ? 1.025 : 1, anchor: .leading)

                                Text("Choose Theme")
                                    .font(.custom("Figtree", size: 10.5).weight(.regular))
                                    .foregroundColor(isThemeButtonHovered ? Color(red: 0.000, green: 0.610, blue: 0.760).opacity(0.82) : Color(red: 0.390, green: 0.390, blue: 0.390).opacity(0.72))
                                    .scaleEffect(isThemeButtonHovered ? 1.02 : 1, anchor: .leading)
                            }

                            Spacer()

                            Image(systemName: "sparkles")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(Color(red: 0.000, green: 0.610, blue: 0.760))
                                .scaleEffect(isThemeButtonHovered ? 1.08 : 1)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(RoundedRectangle(cornerRadius: 18))
                    }
                    .buttonStyle(PlainButtonStyle())
                    .background(Color(red: 0.930, green: 0.900, blue: 0.850))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18)
                            .stroke(isThemeButtonHovered ? Color(red: 0.000, green: 0.610, blue: 0.760) : Color(red: 0.820, green: 0.780, blue: 0.710), lineWidth: 2)
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
                        .foregroundColor(Color(red: 0.390, green: 0.390, blue: 0.390).opacity(0.72))
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
                        label: usesMagazineSettings ? "Seconds / Page" : "Seconds / Photo",
                        value: Binding(
                            get: { secondsPerPhoto },
                            set: { newValue in
                                secondsPerPhoto = newValue
                                enforceFadeLimit()
                            }
                        ),
                        range: usesMagazineSettings ? 0...20 : 1...20,
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
                            label: "Image Change Delay",
                            value:
                                $origamiInternalHoldSeconds,
                            range: 1...15,
                            step: 0.5,
                            suffix: "s"
                        )

                        CompactStepperRow(
                            label: "Images Before Page",
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
                    }
                    .padding(.top, 2)
                }

                if usesMagazineSettings {
                    VStack(alignment: .leading, spacing: 6) {
                        CompactStepperRow(
                            label: "Image Fade In",
                            value: $magazineImageFadeSeconds,
                            range: 0.2...2.0,
                            step: 0.1,
                            suffix: "s"
                        )

                        CompactStepperRow(
                            label: "Start Delay",
                            value: $magazineImageDelaySeconds,
                            range: 0...2.0,
                            step: 0.1,
                            suffix: "s"
                        )
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
                    .foregroundColor(Color(red: 0.315, green: 0.340, blue: 0.390))
                    .padding(.top, 2)

                Text(timingModeHelperText)
                    .font(.custom("Figtree", size: 11).weight(.regular))
                    .foregroundColor(Color(red: 0.390, green: 0.390, blue: 0.390).opacity(0.78))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(red: 0.930, green: 0.900, blue: 0.850))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18)
                            .stroke(Color(red: 0.820, green: 0.780, blue: 0.710).opacity(0.85), lineWidth: 2)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .padding(.top, 2)
            }
            .padding(14)
            .background(Color(red: 0.957, green: 0.937, blue: 0.910))
            .overlay(
                RoundedRectangle(cornerRadius: 24)
                    .stroke(Color(red: 0.820, green: 0.780, blue: 0.710), lineWidth: 4)
            )
            .clipShape(RoundedRectangle(cornerRadius: 24))
        }
        .padding(14)
        .frame(width: 290)
        .background(Color(red: 0.957, green: 0.937, blue: 0.910))
        .overlay(
            RoundedRectangle(cornerRadius: 34)
                .stroke(Color(red: 0.820, green: 0.780, blue: 0.710), lineWidth: 4)
        )
        .clipShape(RoundedRectangle(cornerRadius: 34))
        
    }

    private var usesMagazineSettings: Bool {
        visualTheme == .magazine || visualTheme == .magazineFamily || visualTheme == .magazineCouples
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
            return "Magazine will create editorial pages with one, three, or more photos per page."
        case .magazineFamily:
            return "Magazine Family will use warmer layouts for group and family photos."
        case .magazineCouples:
            return "Magazine Couples will use romantic layouts for portraits, weddings, and trips."
        case .origami:
            return "Origami will use geometric panel-style pages inspired by folded paper movement."
        case .magazineToon:
            return "Magazine Toon will require sign in and credits once AI styles are connected."
        case .origamiToon:
            return "Origami Toon will require sign in and credits once AI styles are connected."
        }
    }

    private var timingModeHelperText: String {
        if visualTheme == .origami {
            return "Image Change Delay controls the pause before the image fold. Images Before Page controls how many images change together before the complete page folds."
        }

        if usesMagazineSettings {
            return "For Magazine, Image Fade In controls alpha 0→1, Start Delay controls when the next image begins, and Seconds / Page controls how long the full page waits before the next empty page starts."
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

struct ThemePickerPopover: View {
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
                    .foregroundColor(Color(red: 0.315, green: 0.340, blue: 0.390))

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

            Text("Pick the slideshow style. AI Toon themes will be available later with sign in and credits.")
                .font(.custom("Figtree", size: 12).weight(.regular))
                .foregroundColor(Color(red: 0.390, green: 0.390, blue: 0.390))
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
                    title: "Magazine",
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
                    title: "Origami",
                    subtitle: "Geometric folded-panel movement and page layouts.",
                    isSelected: selectedTheme == .origami,
                    isLocked: false
                ) {
                    selectedTheme = .origami
                    isPresented = false
                }

                ThemePickerSectionTitle("AI Toon Styles")

                ThemePickerOption(
                    title: "Magazine Toon",
                    subtitle: "AI cartoon photo processing + magazine layout. Coming soon.",
                    isSelected: false,
                    isLocked: true,
                    action: {}
                )

                ThemePickerOption(
                    title: "Origami Toon",
                    subtitle: "AI cartoon photo processing + origami layout. Coming soon.",
                    isSelected: false,
                    isLocked: true,
                    action: {}
                )
            }
        }
        .padding(22)
        .frame(width: 500, height: 680, alignment: .topLeading)
        .background(Color(red: 0.957, green: 0.937, blue: 0.910))
    }
}

struct ThemePickerSectionTitle: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.custom("Figtree", size: 11.5).weight(.semibold))
            .foregroundColor(Color(red: 0.000, green: 0.610, blue: 0.760))
            .padding(.top, 2)
    }
}

struct ThemePickerOption: View {
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
                            .foregroundColor(titleColor)
                            .scaleEffect(isHovered && !isLocked ? 1.025 : 1, anchor: .leading)

                        if isLocked {
                            Text("Locked")
                                .font(.custom("Figtree", size: 9.5).weight(.semibold))
                                .foregroundColor(Color(red: 0.390, green: 0.390, blue: 0.390))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Color(red: 0.900, green: 0.870, blue: 0.810))
                                .clipShape(RoundedRectangle(cornerRadius: 999))
                        }
                    }

                    Text(subtitle)
                        .font(.custom("Figtree", size: 10.5).weight(.regular))
                        .foregroundColor(Color(red: 0.390, green: 0.390, blue: 0.390).opacity(isLocked ? 0.55 : 0.78))
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
                    .stroke(borderColor, lineWidth: isSelected ? 2.5 : 1.5)
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
            return Color(red: 0.390, green: 0.390, blue: 0.390).opacity(0.55)
        }

        if isHovered || isSelected {
            return Color(red: 0.000, green: 0.610, blue: 0.760)
        }

        return Color(red: 0.315, green: 0.340, blue: 0.390)
    }

    private var iconColor: Color {
        if isSelected || (isHovered && !isLocked) {
            return Color(red: 0.000, green: 0.610, blue: 0.760)
        }

        return Color(red: 0.390, green: 0.390, blue: 0.390).opacity(isLocked ? 0.45 : 0.50)
    }

    private var backgroundColor: Color {
        isSelected
            ? Color(red: 0.930, green: 0.900, blue: 0.850)
            : Color(red: 0.957, green: 0.937, blue: 0.910)
    }

    private var borderColor: Color {
        if isSelected || (isHovered && !isLocked) {
            return Color(red: 0.000, green: 0.610, blue: 0.760)
        }

        return Color(red: 0.820, green: 0.780, blue: 0.710).opacity(isLocked ? 0.45 : 0.85)
    }
}

struct FullScreenPreviewSheet: View {
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
    let visualTheme: SlideshowVisualTheme
    let timeCounterText: String
    let transitionStyle: SlideshowTransitionStyle
    let transitionProgress: Double
    let magazineImageFadeSeconds: Double
    let magazineImageDelaySeconds: Double
    let magazineLayoutSeed: Int
    let magazinePageSlotCount: Int
    let origamiAnimationSeed: Int
    let isPreviewPlaying: Bool
    let onTogglePreview: () -> Void
    let onStartFromBeginning: () -> Void
    let onClose: () -> Void

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

                fullscreenCloseButton
                    .position(x: proxy.size.width - 44, y: 44)
                    .zIndex(1000)

                fullscreenBottomControls
                    .frame(width: max(420, proxy.size.width - 56))
                    .position(x: proxy.size.width / 2, y: proxy.size.height - 74)
                    .zIndex(1000)
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
        if let activePreviewImage {
            if usesMagazinePreview {
                MagazinePreviewPage(
                    images: themedPreviewImages,
                    theme: visualTheme,
                    activePhotoName: activePhotoName,
                    activePhotoIndex: activePhotoIndex,
                    transitionProgress: transitionProgress,
                    imageFadeSeconds: magazineImageFadeSeconds,
                    imageDelaySeconds: magazineImageDelaySeconds,
                    layoutSeed: magazineLayoutSeed
                )
                .frame(width: size.width, height: size.height)
                .background(Color.black)
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
                        animationVariant: origamiAnimationSeed
                    )

                    if !previousOrigamiPageImages.isEmpty {
                        OrigamiWholePageHalfFoldOverlay(
                            images: previousOrigamiPageImages,
                            slotReplacementImages:
                                previousOrigamiPageReplacements,
                            animationVariant:
                                previousOrigamiPageAnimationVariant,
                            progress:
                                origamiWholePageFoldProgress
                        )
                        .allowsHitTesting(false)
                        .zIndex(100)
                    }
                }
                .frame(
                    width: size.width,
                    height: size.height
                )
                .background(Color.black)
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
                .foregroundColor(Color(red: 0.315, green: 0.340, blue: 0.390))
                .frame(width: 34, height: 34)
                .background(Color(red: 0.957, green: 0.937, blue: 0.910).opacity(0.96))
                .overlay(
                    RoundedRectangle(cornerRadius: 999)
                        .stroke(Color(red: 0.315, green: 0.340, blue: 0.390).opacity(0.75), lineWidth: 1.5)
                )
                .clipShape(RoundedRectangle(cornerRadius: 999))
                .shadow(color: Color.black.opacity(0.34), radius: 8, x: 0, y: 3)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.escape, modifiers: [])
    }

    private var fullscreenBottomControls: some View {
        HStack(alignment: .center, spacing: 10) {
            HStack(spacing: 10) {
                PreviewControlButton(
                    title: isPreviewPlaying ? "Stop Preview" : "Play Preview",
                    isDisabled: photoCount == 0 || isPreparingPhotos,
                    action: onTogglePreview
                )

                PreviewControlButton(
                    title: "Play From Beginning",
                    isDisabled: photoCount == 0 || isPreparingPhotos,
                    action: onStartFromBeginning
                )
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(Color.black.opacity(0.62))
            .clipShape(RoundedRectangle(cornerRadius: 999))
            .shadow(color: Color.black.opacity(0.30), radius: 10, x: 0, y: 4)

            Spacer()

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
    let layoutSeed: Int

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
                appearAmount: appearAmount(forRevealOrder: revealOrder)
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
        let raw = ((transitionProgress * revealOnlySeconds) - startSeconds) / fadeSeconds
        return min(1, max(0, raw))
    }
}

struct MagazineImageTile: View {
    let image: NSImage
    let appearAmount: Double

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

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.white

                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
            .opacity(appearAmount)
        }
        .clipped()
        .shadow(
            color: Color.black.opacity(revealShadowOpacity),
            radius: revealShadowRadius,
            x: revealShadowXOffset,
            y: revealShadowYOffset
        )
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

            if landscapeCount == 2 {
                return .twoLandscape
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

        ZStack {
            // New image stays behind the old image.
            Image(nsImage: newImage)
                .resizable()
                .scaledToFill()
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
                    width: width * 0.25,
                    height: 0
                ),
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
                    width: -width * 0.25,
                    height: 0
                ),
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

        ZStack {
            // New image stays behind all four old quarters.
            Image(nsImage: newImage)
                .resizable()
                .scaledToFill()
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
                    width: width * 0.25,
                    height: height * 0.25
                ),
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
                    width: -width * 0.25,
                    height: height * 0.25
                ),
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
                    width: width * 0.25,
                    height: -height * 0.25
                ),
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
                    width: -width * 0.25,
                    height: -height * 0.25
                ),
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
                            Image(
                                nsImage:
                                    displayedImage
                            )
                            .resizable()
                            .scaledToFill()
                            .frame(
                                width:
                                    proxy.size.width,
                                height:
                                    proxy.size.height
                            )
                            .clipped()
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
        let fadeStart = 0.90

        guard safeProgress > fadeStart else {
            return 1
        }

        return max(
            0,
            1 - (
                safeProgress - fadeStart
            ) / (
                1 - fadeStart
            )
        )
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
                    animationVariant
            )
            .frame(
                width: width,
                height: height
            )
            .background(Color.black)
        )
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

            let halfHeight =
                canvasHeight * 0.5

            let angle =
                90 * easedProgress

            ZStack {
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

struct CenterPreviewPanel: View {
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
    let magazinePageSlotCount: Int
    let origamiAnimationSeed: Int
    let isPreviewPlaying: Bool
    let onAddPhotos: () -> Void
    let onAddMusic: (Int) -> Void
    let onDropPhotos: ([URL]) -> Void
    let onDropMusic: ([URL]) -> Void
    let onTogglePreview: () -> Void
    let onStartFromBeginning: () -> Void
    let onOpenFullScreen: () -> Void

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
                PanelTitle(title: "Preview", subtitle: "Your slideshow will appear here")
                ZStack {
                    RoundedRectangle(cornerRadius: 34)
                        .fill(activePreviewImage == nil && !isPreparingPhotos && NSImage(named: "ScreenSketch") != nil ? Color.clear : Color.black)

                    if let activePreviewImage {
                        if usesMagazinePreview {
                            MagazinePreviewPage(
                                images: themedPreviewImages,
                                theme: visualTheme,
                                activePhotoName: activePhotoName,
                                activePhotoIndex: activePhotoIndex,
                                transitionProgress: transitionProgress,
                                imageFadeSeconds: magazineImageFadeSeconds,
                                imageDelaySeconds: magazineImageDelaySeconds,
                                layoutSeed: magazineLayoutSeed
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 28))
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
                                    animationVariant: origamiAnimationSeed
                                )

                                if !previousOrigamiPageImages.isEmpty {
                                    OrigamiWholePageHalfFoldOverlay(
                                        images: previousOrigamiPageImages,
                                        slotReplacementImages:
                                            previousOrigamiPageReplacements,
                                        animationVariant:
                                            previousOrigamiPageAnimationVariant,
                                        progress:
                                            origamiWholePageFoldProgress
                                    )
                                    .allowsHitTesting(false)
                                    .zIndex(100)
                                }
                            }
                            .clipShape(
                                RoundedRectangle(
                                    cornerRadius: 28
                                )
                            )
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
                        if NSImage(named: "ScreenSketch") != nil {
                            Image("ScreenSketch")
                                .resizable()
                                .scaledToFill()
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .clipShape(RoundedRectangle(cornerRadius: 28))
                        } else {
                            VStack(spacing: 16) {
                                Image(systemName: "play.rectangle.fill")
                                    .font(.system(size: 42))
                                    .foregroundColor(Color(red: 0.957, green: 0.863, blue: 0.545))

                                Text("No slideshow yet")
                                    .font(.custom("Figtree", size: 13).weight(.medium))
                                    .foregroundColor(.white)

                                Text("Add photos and music to generate a preview.")
                                    .font(.custom("Figtree", size: 14).weight(.medium))
                                    .foregroundColor(.white.opacity(0.65))
                            }
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

                HStack {
                    PreviewControlButton(
                        title: isPreviewPlaying ? "Stop Preview" : "Play Preview",
                        isDisabled: photoCount == 0 || isPreparingPhotos,
                        action: onTogglePreview
                    )

                    PreviewControlButton(
                        title: "Play From Beginning",
                        isDisabled: photoCount == 0 || isPreparingPhotos,
                        action: onStartFromBeginning
                    )

                    PreviewControlButton(
                        title: "Full Screen",
                        isDisabled: photoCount == 0 || isPreparingPhotos,
                        action: onOpenFullScreen
                    )

                    Spacer()

                    Text(timeCounterText)
                        .font(.custom("Figtree", size: 12).weight(.regular))
                        .foregroundColor(Color(red: 0.390, green: 0.390, blue: 0.390))
                        .lineLimit(1)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .top)
            .background(Color(red: 0.957, green: 0.937, blue: 0.910))
            .overlay(
                RoundedRectangle(cornerRadius: 34)
                    .stroke(Color(red: 0.820, green: 0.780, blue: 0.710), lineWidth: 4)
            )
            .clipShape(RoundedRectangle(cornerRadius: 34))

            HStack(spacing: 10) {
                Button(action: onAddPhotos) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            Image(systemName: "photo.on.rectangle.angled")
                                .font(.system(size: 19, weight: .medium))
                                .foregroundColor(Color(red: 0.315, green: 0.340, blue: 0.390))

                            VStack(alignment: .leading, spacing: 2) {
                                Text("Photos")
                                    .font(.custom("Figtree", size: 13).weight(.medium))
                                    .foregroundColor(Color(red: 0.315, green: 0.340, blue: 0.390))

                                Text(photoStatusText)
                                    .font(.custom("Figtree", size: 10.5).weight(.regular))
                                    .foregroundColor(Color(red: 0.390, green: 0.390, blue: 0.390).opacity(0.72))
                                    .lineLimit(1)
                            }

                            Spacer()
                        }

                        VStack(spacing: 6) {
                            PhotoImportInfoRow(
                                icon: "photo.stack",
                                title: "Select multiple photos"
                            )

                            PhotoImportInfoRow(
                                icon: "arrow.down.doc",
                                title: "Drag & drop supported"
                            )

                            PhotoImportInfoRow(
                                icon: "arrow.left.arrow.right",
                                title: "Reorder anytime in Timeline"
                            )
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "music.note.list")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundColor(Color(red: 0.315, green: 0.340, blue: 0.390))

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Music Playlist")
                                .font(.custom("Figtree", size: 13).weight(.medium))
                                .foregroundColor(Color(red: 0.315, green: 0.340, blue: 0.390))

                            Text("Up to 3 tracks • repeats until slideshow ends")
                                .font(.custom("Figtree", size: 10.5).weight(.regular))
                                .foregroundColor(Color(red: 0.390, green: 0.390, blue: 0.390).opacity(0.72))
                                .lineLimit(1)
                        }

                        Spacer()
                    }

                    VStack(spacing: 6) {
                        ForEach(0..<3, id: \.self) { index in
                            HStack(spacing: 8) {
                                Image(systemName: selectedMusicURLs.indices.contains(index) ? "music.note" : "plus")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(Color(red: 0.315, green: 0.340, blue: 0.390).opacity(0.8))
                                    .frame(width: 18, height: 18)
                                    .background(Color.white.opacity(0.48))
                                    .clipShape(Circle())

                                VStack(alignment: .leading, spacing: 1) {
                                    Text("Track \(index + 1)")
                                        .font(.custom("Figtree", size: 10).weight(.medium))
                                        .foregroundColor(Color(red: 0.315, green: 0.340, blue: 0.390))

                                    Text(
                                        selectedMusicURLs.indices.contains(index)
                                            ? selectedMusicURLs[index].lastPathComponent
                                            : index == 0 ? "Add main track" : "Optional"
                                    )
                                    .font(.custom("Figtree", size: 10.5).weight(.regular))
                                    .foregroundColor(Color(red: 0.390, green: 0.390, blue: 0.390).opacity(0.72))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                }

                                Spacer()
                            }
                            .padding(.horizontal, 8)
                            .frame(height: 34)
                            .background(Color.white.opacity(0.28))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(Color(red: 0.820, green: 0.780, blue: 0.710).opacity(0.8), lineWidth: 1)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .contentShape(RoundedRectangle(cornerRadius: 10))
                            .onTapGesture {
                                onAddMusic(index)
                            }
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .contentShape(RoundedRectangle(cornerRadius: 34))
            .background(Color(red: 0.957, green: 0.937, blue: 0.910))
            .overlay(
                RoundedRectangle(cornerRadius: 34)
                    .stroke(Color(red: 0.820, green: 0.780, blue: 0.710), lineWidth: 4)
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
}

struct PhotoImportInfoRow: View {
    let icon: String
    let title: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(Color(red: 0.315, green: 0.340, blue: 0.390).opacity(0.8))
                .frame(width: 18, height: 18)
                .background(Color.white.opacity(0.48))
                .clipShape(Circle())

            Text(title)
                .font(.custom("Figtree", size: 10.5).weight(.regular))
                .foregroundColor(Color(red: 0.390, green: 0.390, blue: 0.390).opacity(0.78))
                .lineLimit(1)

            Spacer()
        }
        .padding(.horizontal, 8)
        .frame(height: 34)
        .background(Color.white.opacity(0.28))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(red: 0.820, green: 0.780, blue: 0.710).opacity(0.8), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

struct RightExportPanel: View {
    @Binding var selectedResolution: String
    let selectedMusicURL: URL?
    let selectedMusicCount: Int
    let canExport: Bool
    let isExporting: Bool
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
                    .foregroundColor(Color(red: 0.315, green: 0.340, blue: 0.390))

                SettingRow(label: "Format", value: "MP4")
                SettingRow(label: "Codec", value: selectedResolution == "Original" ? "H.265" : "H.264")
                SettingRow(label: "Resolution", value: selectedResolution)
                SettingRow(label: "FPS", value: "30")

                VStack(alignment: .leading, spacing: 7) {
                    Text("Export Size")
                        .font(.custom("Figtree", size: 12).weight(.regular))
                        .foregroundColor(Color(red: 0.390, green: 0.390, blue: 0.390))

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
                        .foregroundColor(Color(red: 0.390, green: 0.390, blue: 0.390).opacity(0.78))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if isExporting {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.7)
                            .frame(width: 16, height: 16)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(red: 0.930, green: 0.900, blue: 0.850))
                .overlay(
                    RoundedRectangle(cornerRadius: 18)
                        .stroke(Color(red: 0.820, green: 0.780, blue: 0.710).opacity(0.85), lineWidth: 2)
                )
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .padding(.top, 2)

            }
            .padding(14)
            .background(Color(red: 0.957, green: 0.937, blue: 0.910))
            .overlay(
                RoundedRectangle(cornerRadius: 24)
                    .stroke(Color(red: 0.820, green: 0.780, blue: 0.710), lineWidth: 4)
            )
            .clipShape(RoundedRectangle(cornerRadius: 24))

        }
        .padding(14)
        .frame(width: 290)
        .background(Color(red: 0.957, green: 0.937, blue: 0.910))
        .overlay(
            RoundedRectangle(cornerRadius: 34)
                .stroke(Color(red: 0.820, green: 0.780, blue: 0.710), lineWidth: 4)
        )
        .clipShape(RoundedRectangle(cornerRadius: 34))
        .popover(isPresented: $isShowingExportConfirmation, arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Export Video")
                    .font(.custom("Figtree", size: 14).weight(.medium))
                    .foregroundColor(Color(red: 0.315, green: 0.340, blue: 0.390))

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
                    SettingRow(label: "Format", value: "MP4")
                    SettingRow(label: "Audio", value: exportAudioText)
                }

                Text("Choose where to save this \(selectedResolution) slideshow video.")
                    .font(.custom("Figtree", size: 11).weight(.regular))
                    .foregroundColor(Color(red: 0.390, green: 0.390, blue: 0.390).opacity(0.78))
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Button("Cancel") {
                        isShowingExportConfirmation = false
                    }
                    .buttonStyle(.plain)
                    .font(.custom("Figtree", size: 11).weight(.medium))
                    .foregroundColor(Color(red: 0.390, green: 0.390, blue: 0.390).opacity(0.78))
                    .padding(.horizontal, 13)
                    .padding(.vertical, 8)
                    .background(Color(red: 0.930, green: 0.900, blue: 0.850))
                    .clipShape(RoundedRectangle(cornerRadius: 999))

                    Button {
                        isShowingExportConfirmation = false
                        onExportVideo()
                    } label: {
                        Text(isExporting ? "Exporting…" : "Export Video")
                            .font(.custom("Figtree", size: 11).weight(.medium))
                            .foregroundColor(Color(red: 0.315, green: 0.340, blue: 0.390))
                            .padding(.horizontal, 13)
                            .padding(.vertical, 8)
                            .background(Color(red: 0.930, green: 0.900, blue: 0.850))
                            .overlay(
                                RoundedRectangle(cornerRadius: 999)
                                    .stroke(Color(red: 0.820, green: 0.780, blue: 0.710), lineWidth: 1.7)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 999))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canExport || isExporting)
                }
            }
            .padding(16)
            .frame(width: 260)
            .background(Color(red: 0.957, green: 0.937, blue: 0.910))
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
        .background(Color(red: 0.957, green: 0.937, blue: 0.910))
        .overlay(
            RoundedRectangle(cornerRadius: 34)
                .stroke(Color(red: 0.820, green: 0.780, blue: 0.710), lineWidth: 4)
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


enum EmptyTimelineSceneKind: Int, CaseIterable, Identifiable {
    case coupleSideBySide
    case coupleLooking
    case beachWalk
    case womanSolo
    case manSolo
    case poolCouple
    case palmWoman

    var id: Int { rawValue }

    var symbol: String {
        switch self {
        case .coupleSideBySide:
            return "person.2"
        case .coupleLooking:
            return "heart"
        case .beachWalk:
            return "figure.walk"
        case .womanSolo:
            return "person.crop.circle"
        case .manSolo:
            return "person.crop.circle"
        case .poolCouple:
            return "water.waves"
        case .palmWoman:
            return "leaf"
        }
    }

    var detailSymbol: String? {
        switch self {
        case .coupleSideBySide:
            return "sparkles"
        case .coupleLooking:
            return "person.2"
        case .beachWalk:
            return "sun.max"
        case .womanSolo:
            return "sparkle"
        case .manSolo:
            return "camera"
        case .poolCouple:
            return "building.2"
        case .palmWoman:
            return "camera.aperture"
        }
    }
}

struct EmptyTimelineStoryboard: View {
    private var dummyImageNames: [String] {
        (1...8)
            .map { "DummyTimeline\($0)" }
            .filter { NSImage(named: $0) != nil }
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                if dummyImageNames.isEmpty {
                    ForEach(EmptyTimelineSceneKind.allCases) { scene in
                        EmptyTimelineSceneThumb(scene: scene)
                    }
                } else {
                    ForEach(dummyImageNames, id: \.self) { imageName in
                        EmptyTimelineImageThumb(imageName: imageName)
                    }
                }

                Spacer(minLength: 0)
            }
        }
        .frame(height: 66)
    }
}

struct EmptyTimelineImageThumb: View {
    let imageName: String

    var body: some View {
        Image(imageName)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: 132, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color(red: 0.820, green: 0.780, blue: 0.710).opacity(0.88), lineWidth: 2.4)
            )
    }
}

struct EmptyTimelineSceneThumb: View {
    let scene: EmptyTimelineSceneKind

    private let ink = Color(red: 0.315, green: 0.340, blue: 0.390)
    private let paper = Color(red: 0.930, green: 0.900, blue: 0.850)

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14)
                .fill(paper.opacity(0.54))

            SketchSceneBackground(scene: scene)

            Image(systemName: scene.symbol)
                .font(.system(size: 22, weight: .regular))
                .foregroundColor(ink.opacity(0.78))
                .offset(mainSymbolOffset)

            if let detailSymbol = scene.detailSymbol {
                Image(systemName: detailSymbol)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundColor(ink.opacity(0.45))
                    .offset(detailSymbolOffset)
            }

            RoundedRectangle(cornerRadius: 14)
                .stroke(Color(red: 0.820, green: 0.780, blue: 0.710).opacity(0.88), lineWidth: 2.4)
        }
        .frame(width: 92, height: 56)
    }

    private var mainSymbolOffset: CGSize {
        switch scene {
        case .beachWalk:
            return CGSize(width: -14, height: 3)
        case .poolCouple:
            return CGSize(width: -12, height: 5)
        case .palmWoman:
            return CGSize(width: 14, height: 4)
        default:
            return CGSize(width: 0, height: 0)
        }
    }

    private var detailSymbolOffset: CGSize {
        switch scene {
        case .coupleSideBySide:
            return CGSize(width: 25, height: -16)
        case .coupleLooking:
            return CGSize(width: -24, height: 13)
        case .beachWalk:
            return CGSize(width: 25, height: -16)
        case .womanSolo:
            return CGSize(width: 24, height: -15)
        case .manSolo:
            return CGSize(width: 24, height: -15)
        case .poolCouple:
            return CGSize(width: 22, height: -13)
        case .palmWoman:
            return CGSize(width: -22, height: -13)
        }
    }
}

struct SketchSceneBackground: View {
    let scene: EmptyTimelineSceneKind

    private let ink = Color(red: 0.315, green: 0.340, blue: 0.390)
    private let blue = Color(red: 0.000, green: 0.610, blue: 0.760)

    var body: some View {
        ZStack {
            commonSketchLines

            switch scene {
            case .coupleSideBySide, .coupleLooking:
                portraitFrame

            case .beachWalk:
                beachLines
                palmTree
                    .offset(x: 24, y: -2)

            case .womanSolo:
                portraitFrame
                softOval
                    .offset(x: 15, y: -2)

            case .manSolo:
                portraitFrame
                softOval
                    .offset(x: -15, y: -2)

            case .poolCouple:
                poolLines

            case .palmWoman:
                palmTree
                    .rotationEffect(.degrees(-10))
                    .offset(x: -20, y: 3)
                beachLines
            }
        }
        .frame(width: 92, height: 56)
        .clipped()
    }

    private var commonSketchLines: some View {
        Path { path in
            path.move(to: CGPoint(x: 10, y: 45))
            path.addCurve(to: CGPoint(x: 82, y: 45), control1: CGPoint(x: 25, y: 39), control2: CGPoint(x: 60, y: 52))

            path.move(to: CGPoint(x: 15, y: 12))
            path.addCurve(to: CGPoint(x: 76, y: 13), control1: CGPoint(x: 32, y: 8), control2: CGPoint(x: 58, y: 18))
        }
        .stroke(ink.opacity(0.18), style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
    }

    private var portraitFrame: some View {
        RoundedRectangle(cornerRadius: 10)
            .stroke(ink.opacity(0.18), lineWidth: 1.5)
            .frame(width: 58, height: 38)
    }

    private var softOval: some View {
        Ellipse()
            .stroke(ink.opacity(0.16), lineWidth: 1.5)
            .frame(width: 30, height: 38)
    }

    private var beachLines: some View {
        Path { path in
            path.move(to: CGPoint(x: 8, y: 40))
            path.addCurve(to: CGPoint(x: 84, y: 40), control1: CGPoint(x: 28, y: 34), control2: CGPoint(x: 58, y: 48))

            path.move(to: CGPoint(x: 12, y: 48))
            path.addLine(to: CGPoint(x: 86, y: 48))
        }
        .stroke(ink.opacity(0.22), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
    }

    private var poolLines: some View {
        Path { path in
            path.move(to: CGPoint(x: 8, y: 38))
            path.addCurve(to: CGPoint(x: 84, y: 38), control1: CGPoint(x: 24, y: 28), control2: CGPoint(x: 58, y: 48))

            path.move(to: CGPoint(x: 8, y: 47))
            path.addCurve(to: CGPoint(x: 84, y: 47), control1: CGPoint(x: 24, y: 37), control2: CGPoint(x: 58, y: 57))
        }
        .stroke(blue.opacity(0.42), style: StrokeStyle(lineWidth: 2, lineCap: .round))
    }

    private var palmTree: some View {
        Path { path in
            path.move(to: CGPoint(x: 30, y: 50))
            path.addQuadCurve(to: CGPoint(x: 42, y: 16), control: CGPoint(x: 26, y: 31))

            path.move(to: CGPoint(x: 42, y: 16))
            path.addLine(to: CGPoint(x: 24, y: 21))
            path.move(to: CGPoint(x: 42, y: 16))
            path.addLine(to: CGPoint(x: 60, y: 20))
            path.move(to: CGPoint(x: 42, y: 16))
            path.addLine(to: CGPoint(x: 33, y: 8))
            path.move(to: CGPoint(x: 42, y: 16))
            path.addLine(to: CGPoint(x: 51, y: 8))
        }
        .stroke(ink.opacity(0.30), style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
        .frame(width: 70, height: 52)
    }
}

struct TimelinePhotoThumb: View {
    let index: Int
    let url: URL
    let isActive: Bool

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(red: 0.930, green: 0.900, blue: 0.850))

            if let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 92, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 18))
                    .foregroundColor(Color(red: 0.390, green: 0.390, blue: 0.390).opacity(0.65))
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
            ? Color(red: 0.000, green: 0.610, blue: 0.760)
            : Color(red: 0.820, green: 0.780, blue: 0.710).opacity(0.85)
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
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.custom("Figtree", size: 17).weight(.medium))
                .foregroundColor(Color(red: 0.315, green: 0.340, blue: 0.390))

            Text(subtitle)
                .font(.custom("Figtree", size: 13).weight(.regular))
                .foregroundColor(Color(red: 0.390, green: 0.390, blue: 0.390))
        }
    }
}

struct DropCard: View {
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
                        .foregroundColor(isHovered ? activeColor.opacity(0.82) : Color(red: 0.390, green: 0.390, blue: 0.390))
                        .lineLimit(1)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 9)
        .background(isHovered ? Color(red: 0.930, green: 0.900, blue: 0.850) : Color(red: 0.957, green: 0.937, blue: 0.910))
        .overlay(
            RoundedRectangle(cornerRadius: 22)
                .stroke(isHovered ? activeColor : Color(red: 0.820, green: 0.780, blue: 0.710), lineWidth: isHovered ? 3.4 : 3)
        )
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .animation(.linear(duration: 0.10), value: isHovered)
        .onHover { hovering in
            isHovered = hovering
        }
    }

    private var activeColor: Color {
        isHovered ? Color(red: 0.000, green: 0.610, blue: 0.760) : Color(red: 0.315, green: 0.340, blue: 0.390)
    }
}



struct TimingModeButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.custom("Figtree", size: 11).weight(.medium))
                .foregroundColor(activeColor)
                .lineLimit(1)
                .scaleEffect(isHovered ? 1.035 : 1)
                .animation(.linear(duration: 0.10), value: isHovered)
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity)
                .background(Color(red: 0.930, green: 0.900, blue: 0.850))
                .overlay(
                    RoundedRectangle(cornerRadius: 999)
                        .stroke(activeColor.opacity(isSelected || isHovered ? 1 : 0.7), lineWidth: isSelected || isHovered ? 2.2 : 1.6)
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
            return Color(red: 0.000, green: 0.610, blue: 0.760)
        }

        return Color(red: 0.315, green: 0.340, blue: 0.390)
    }
}

struct PreviewControlButton: View {
    let title: String
    let isDisabled: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.custom("Figtree", size: 11).weight(.medium))
                .foregroundColor(activeColor)
                .lineLimit(1)
                .scaleEffect(isHovered && !isDisabled ? 1.035 : 1)
                .animation(.linear(duration: 0.10), value: isHovered)
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .frame(width: 150)
                .background(Color(red: 0.930, green: 0.900, blue: 0.850))
                .overlay(
                    RoundedRectangle(cornerRadius: 999)
                        .stroke(activeColor.opacity(isHovered && !isDisabled ? 1 : 0.7), lineWidth: isHovered && !isDisabled ? 2.2 : 1.6)
                )
                .clipShape(RoundedRectangle(cornerRadius: 999))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.55 : 1)
        .onHover { hovering in
            isHovered = hovering
        }
    }

    private var activeColor: Color {
        if isHovered && !isDisabled {
            return Color(red: 0.000, green: 0.610, blue: 0.760)
        }

        return Color(red: 0.315, green: 0.340, blue: 0.390)
    }
}

struct CompactStepperRow: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let suffix: String

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.custom("Figtree", size: 12).weight(.regular))
                .foregroundColor(Color(red: 0.390, green: 0.390, blue: 0.390))

            Spacer()

            Stepper(
                value: $value,
                in: range,
                step: step
            ) {
                Text(formattedValue)
                    .font(.custom("Figtree", size: 12).weight(.regular))
                    .foregroundColor(Color(red: 0.315, green: 0.340, blue: 0.390))
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
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.custom("Figtree", size: 12).weight(.regular))
                .foregroundColor(Color(red: 0.390, green: 0.390, blue: 0.390))

            Spacer()

            Text(value)
                .font(.custom("Figtree", size: 12).weight(.regular))
                .foregroundColor(Color(red: 0.315, green: 0.340, blue: 0.390))
        }
    }
}

struct HeaderLinkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HeaderLinkButtonLabel(configuration: configuration)
    }
}

struct HeaderLinkButtonLabel: View {
    let configuration: ButtonStyle.Configuration

    @State private var isHovered = false

    var body: some View {
        configuration.label
            .font(.custom("Figtree", size: 11).weight(.medium))
            .foregroundColor(textColor)
            .lineLimit(1)
            .scaleEffect(configuration.isPressed ? 0.985 : (isHovered ? 1.025 : 1))
            .animation(.linear(duration: 0.10), value: isHovered)
            .animation(.linear(duration: 0.08), value: configuration.isPressed)
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(Color(red: 0.930, green: 0.900, blue: 0.850))
            .overlay(
                RoundedRectangle(cornerRadius: 999)
                    .stroke(borderColor, lineWidth: isHovered ? 2.2 : 1.6)
            )
            .clipShape(RoundedRectangle(cornerRadius: 999))
            .onHover { hovering in
                isHovered = hovering
            }
    }

    private var textColor: Color {
        isHovered
            ? Color(red: 0.000, green: 0.610, blue: 0.760)
            : Color(red: 0.315, green: 0.340, blue: 0.390)
    }

    private var borderColor: Color {
        isHovered
            ? Color(red: 0.000, green: 0.610, blue: 0.760)
            : Color(red: 0.315, green: 0.340, blue: 0.390).opacity(0.7)
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
    let configuration: ButtonStyle.Configuration
    let isPrimary: Bool

    @State private var isHovered = false

    var body: some View {
        configuration.label
            .font(.custom("Figtree", size: 11).weight(.medium))
            .foregroundColor(textColor)
            .lineLimit(1)
            .scaleEffect(configuration.isPressed ? 0.985 : (isHovered ? 1.035 : 1))
            .animation(.linear(duration: 0.10), value: isHovered)
            .animation(.linear(duration: 0.08), value: configuration.isPressed)
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(Color(red: 0.930, green: 0.900, blue: 0.850))
            .overlay(
                RoundedRectangle(cornerRadius: 999)
                    .stroke(borderColor, lineWidth: isHovered ? 2.2 : 1.6)
            )
            .clipShape(RoundedRectangle(cornerRadius: 999))
            .onHover { hovering in
                isHovered = hovering
            }
    }

    private var textColor: Color {
        isHovered
            ? Color(red: 0.000, green: 0.610, blue: 0.760)
            : Color(red: 0.315, green: 0.340, blue: 0.390)
    }

    private var borderColor: Color {
        isHovered
            ? Color(red: 0.000, green: 0.610, blue: 0.760)
            : Color(red: 0.820, green: 0.780, blue: 0.710)
    }
}

#Preview {
    ContentView()
}

