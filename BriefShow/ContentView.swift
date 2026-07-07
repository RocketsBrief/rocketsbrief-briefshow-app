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

struct ContentView: View {
    @State private var selectedPhotoURLs: [URL] = []
    @State private var previewImages: [NSImage] = []
    @State private var isPreparingPhotos: Bool = false
    @State private var preparedPhotoCount: Int = 0
    @State private var selectedMusicURL: URL?
    @State private var audioPlayer: AVAudioPlayer?
    @State private var timingMode: SlideshowTimingMode = .followMusic
    @State private var secondsPerPhoto: Double = 5
    @State private var fadeDuration: Double = 1
    @State private var musicFadeInSeconds: Double = 4
    @State private var musicFadeOutSeconds: Double = 4
    @State private var shouldLoopPreview: Bool = false
    @State private var transitionStyle: SlideshowTransitionStyle = .fade
    @State private var selectedExportResolution: String = "4K"
    @State private var isExportingVideo: Bool = false
    @State private var exportStatusText: String?
    @State private var activePhotoIndex: Int = 0
    @State private var previousPhotoIndex: Int?
    @State private var transitionProgress: Double = 1
    @State private var isPreviewPlaying: Bool = false
    @State private var previewElapsedSeconds: Double = 0
    @State private var previewTotalElapsedSeconds: Double = 0

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
                        musicFadeInSeconds: $musicFadeInSeconds,
                        musicFadeOutSeconds: $musicFadeOutSeconds,
                        shouldLoopPreview: $shouldLoopPreview,
                        transitionStyle: $transitionStyle
                    )
                    CenterPreviewPanel(
                        activePreviewImage: activePreviewImage,
                        previousPreviewImage: previousPreviewImage,
                        activePhotoName: activePhotoName,
                        activePhotoIndex: activePhotoIndex,
                        photoCount: selectedPhotoURLs.count,
                        isPreparingPhotos: isPreparingPhotos,
                        preparedPhotoCount: preparedPhotoCount,
                        selectedMusicURL: selectedMusicURL,
                        timeCounterText: timeCounterText,
                        transitionStyle: transitionStyle,
                        transitionProgress: transitionProgress,
                        isPreviewPlaying: isPreviewPlaying,
                        onAddPhotos: openPhotoPicker,
                        onAddMusic: openMusicPicker,
                        onDropPhotos: importPhotoURLs,
                        onDropMusic: importMusicURLs,
                        onTogglePreview: togglePreview,
                        onStartFromBeginning: startPreviewFromBeginning
                    )
                    RightExportPanel(
                        selectedResolution: $selectedExportResolution,
                        selectedMusicURL: selectedMusicURL,
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
                    isPreparingPhotos: isPreparingPhotos,
                    onDropPhotos: importPhotoURLs,
                    onDropMusic: importMusicURLs,
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
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(
            minWidth: 980,
            idealWidth: 1180,
            maxWidth: .infinity,
            alignment: .top
        )
        .onReceive(Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()) { _ in
            advancePreviewIfNeeded(delta: 0.1)
        }
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

    private var currentPhotoDuration: Double {
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
        return "\(formatTime(elapsed)) / \(formatTime(totalPreviewDuration)) · Photo \(activePhotoIndex + 1) / \(selectedPhotoURLs.count)"
    }

    private func formatTime(_ seconds: Double) -> String {
        let safeSeconds = max(0, Int(seconds.rounded()))
        let minutes = safeSeconds / 60
        let remainingSeconds = safeSeconds % 60

        return String(format: "%02d:%02d", minutes, remainingSeconds)
    }

    private func togglePreview() {
        guard !selectedPhotoURLs.isEmpty, !isPreparingPhotos, !previewImages.isEmpty else {
            return
        }

        isPreviewPlaying.toggle()
        previewElapsedSeconds = 0

        if isPreviewPlaying {
            let fadeInDuration = max(musicFadeInSeconds, 0.1)
            audioPlayer?.volume = Float(min(previewTotalElapsedSeconds / fadeInDuration, 1))
            audioPlayer?.play()
        } else {
            audioPlayer?.pause()
        }
    }

    private func advancePreviewIfNeeded(delta: Double) {
        guard isPreviewPlaying, !selectedPhotoURLs.isEmpty else {
            return
        }

        previewElapsedSeconds += delta
        previewTotalElapsedSeconds += delta
        updateAudioFadeOut()

        guard previewElapsedSeconds >= currentPhotoDuration else {
            return
        }

        previewElapsedSeconds = 0

        let nextIndex = activePhotoIndex + 1

        if nextIndex >= selectedPhotoURLs.count {
            if shouldLoopPreview {
                previewTotalElapsedSeconds = 0
                audioPlayer?.volume = 0
                audioPlayer?.currentTime = 0
                audioPlayer?.play()
                moveToPhoto(at: 0)
            } else {
                isPreviewPlaying = false
                previewTotalElapsedSeconds = totalPreviewDuration
                audioPlayer?.pause()
                moveToPhoto(at: selectedPhotoURLs.count - 1)
            }
            return
        }

        moveToPhoto(at: nextIndex)
    }

    private func startPreviewFromBeginning() {
        guard !selectedPhotoURLs.isEmpty, !isPreparingPhotos, !previewImages.isEmpty else {
            return
        }

        previousPhotoIndex = nil
        transitionProgress = 1
        activePhotoIndex = 0
        previewElapsedSeconds = 0
        previewTotalElapsedSeconds = 0
        isPreviewPlaying = true
        audioPlayer?.volume = 0
        audioPlayer?.currentTime = 0
        audioPlayer?.play()
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

    private func moveToPhoto(at newIndex: Int) {
        guard selectedPhotoURLs.indices.contains(newIndex), newIndex != activePhotoIndex else {
            return
        }

        if transitionStyle == .fade {
            previousPhotoIndex = activePhotoIndex
            transitionProgress = 0
            activePhotoIndex = newIndex

            let safeFadeDuration = min(max(fadeDuration, 0.15), max(0.15, currentPhotoDuration * 0.45))

            DispatchQueue.main.async {
                withAnimation(.easeInOut(duration: safeFadeDuration)) {
                    transitionProgress = 1
                }
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + safeFadeDuration + 0.02) {
                if activePhotoIndex == newIndex {
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

    private func openMusicPicker() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.resolvesAliases = true

        if panel.runModal() == .OK {
            importMusicURLs(panel.urls)
        }
    }

    private func importMusicURLs(_ urls: [URL]) {
        guard let musicURL = urls.first(where: { url in
            UTType(filenameExtension: url.pathExtension)?.conforms(to: .audio) == true
        }) else {
            return
        }

        selectedMusicURL = musicURL
        prepareAudioPlayer(for: musicURL)
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
        let resolution = selectedExportResolution
        let durationPerPhoto = max(0.25, currentPhotoDuration)
        let selectedTransitionStyle = transitionStyle
        let selectedFadeDuration = fadeDuration
        let musicURL = selectedMusicURL
        let selectedMusicFadeIn = musicFadeInSeconds
        let selectedMusicFadeOut = musicFadeOutSeconds

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let videoOnlyURL = musicURL == nil ? outputURL : temporaryVideoURL(for: outputURL)

                try renderSlideshowVideo(
                    photoURLs: photoURLs,
                    outputURL: videoOnlyURL,
                    resolutionName: resolution,
                    secondsPerPhoto: durationPerPhoto,
                    transitionStyle: selectedTransitionStyle,
                    fadeDuration: selectedFadeDuration
                )

                if let musicURL {
                    try muxVideoWithMusic(
                        videoURL: videoOnlyURL,
                        musicURL: musicURL,
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
    musicURL: URL,
    outputURL: URL,
    fadeInSeconds: Double,
    fadeOutSeconds: Double,
    preferHEVC: Bool
) throws {
    if FileManager.default.fileExists(atPath: outputURL.path) {
        try FileManager.default.removeItem(at: outputURL)
    }

    let videoAsset = AVURLAsset(url: videoURL)
    let musicAsset = AVURLAsset(url: musicURL)
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

    if let sourceAudioTrack = musicAsset.tracks(withMediaType: .audio).first,
       let compositionAudioTrack = composition.addMutableTrack(
           withMediaType: .audio,
           preferredTrackID: kCMPersistentTrackID_Invalid
       ) {
        let audioDuration = minCMTime(videoDuration, musicAsset.duration)

        try compositionAudioTrack.insertTimeRange(
            CMTimeRange(start: .zero, duration: audioDuration),
            of: sourceAudioTrack,
            at: .zero
        )

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
                        .frame(height: 15)
                        .fixedSize(horizontal: true, vertical: false)
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
                }
            }
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

            Text("BriefShow is free to use. If you enjoy it and want to support the mission, you can help us build more free creative apps.")
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

struct LeftImportPanel: View {
    @Binding var timingMode: SlideshowTimingMode
    @Binding var secondsPerPhoto: Double
    @Binding var fadeDuration: Double
    @Binding var musicFadeInSeconds: Double
    @Binding var musicFadeOutSeconds: Double
    @Binding var shouldLoopPreview: Bool
    @Binding var transitionStyle: SlideshowTransitionStyle

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PanelTitle(title: "Settings", subtitle: "Timing and transitions")

            VStack(alignment: .leading, spacing: 8) {
                Text("Slideshow Settings")
                    .font(.custom("Figtree", size: 13).weight(.medium))
                    .foregroundColor(Color(red: 0.315, green: 0.340, blue: 0.390))

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

                if timingMode == .customSpeed {
                    CompactStepperRow(
                        label: "Seconds / Photo",
                        value: Binding(
                            get: { secondsPerPhoto },
                            set: { newValue in
                                secondsPerPhoto = newValue
                                enforceFadeLimit()
                            }
                        ),
                        range: 1...20,
                        step: 1,
                        suffix: "s"
                    )
                }

                CompactStepperRow(
                    label: "Fade",
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
                .opacity(isFadeControlDisabled ? 0.55 : 1)
                .disabled(isFadeControlDisabled)

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

                VStack(alignment: .leading, spacing: 7) {
                    Text("Transition Style")
                        .font(.custom("Figtree", size: 12).weight(.regular))
                        .foregroundColor(Color(red: 0.390, green: 0.390, blue: 0.390))

                    HStack(spacing: 8) {
                        TimingModeButton(
                            title: "Fade",
                            isSelected: transitionStyle == .fade
                        ) {
                            if maxAllowedFadeDuration > 0 {
                                transitionStyle = .fade
                            }
                        }
                        .opacity(maxAllowedFadeDuration == 0 ? 0.55 : 1)
                        .disabled(maxAllowedFadeDuration == 0)

                        TimingModeButton(
                            title: "Blink",
                            isSelected: transitionStyle == .blink
                        ) {
                            transitionStyle = .blink
                        }
                    }
                }
                .padding(.top, 2)

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
        transitionStyle == .blink || maxAllowedFadeDuration == 0
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

    private var timingModeHelperText: String {
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

struct CenterPreviewPanel: View {
    let activePreviewImage: NSImage?
    let previousPreviewImage: NSImage?
    let activePhotoName: String
    let activePhotoIndex: Int
    let photoCount: Int
    let isPreparingPhotos: Bool
    let preparedPhotoCount: Int
    let selectedMusicURL: URL?
    let timeCounterText: String
    let transitionStyle: SlideshowTransitionStyle
    let transitionProgress: Double
    let isPreviewPlaying: Bool
    let onAddPhotos: () -> Void
    let onAddMusic: () -> Void
    let onDropPhotos: ([URL]) -> Void
    let onDropMusic: ([URL]) -> Void
    let onTogglePreview: () -> Void
    let onStartFromBeginning: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 12) {
                PanelTitle(title: "Preview", subtitle: "Your slideshow will appear here")
                ZStack {
                    RoundedRectangle(cornerRadius: 34)
                        .fill(activePreviewImage == nil && !isPreparingPhotos && NSImage(named: "ScreenSketch") != nil ? Color.clear : Color.black)

                    if let activePreviewImage {
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
                    DropCard(
                        icon: "photo.on.rectangle.angled",
                        title: "Add Photos",
                        subtitle: photoStatusText,
                        isLoading: isPreparingPhotos
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)

                DropCard(
                    icon: "music.note",
                    title: "Add Music",
                    subtitle: musicStatusText
                )
                .frame(maxWidth: .infinity)
                .contentShape(RoundedRectangle(cornerRadius: 22))
                .onTapGesture {
                    onAddMusic()
                }
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

struct RightExportPanel: View {
    @Binding var selectedResolution: String
    let selectedMusicURL: URL?
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
        selectedMusicURL?.lastPathComponent ?? "Silent for now"
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

        let activeURL = photoURLs.indices.contains(activePhotoIndex) ? photoURLs[activePhotoIndex] : nil
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

            if let activeURL, let newActiveIndex = photoURLs.firstIndex(of: activeURL) {
                activePhotoIndex = newActiveIndex
            } else {
                activePhotoIndex = min(activePhotoIndex, max(0, photoURLs.count - 1))
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

