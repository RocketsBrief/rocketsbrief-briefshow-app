import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Combine
import AVFoundation

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
                        onTogglePreview: togglePreview,
                        onStartFromBeginning: startPreviewFromBeginning
                    )
                    RightExportPanel(selectedResolution: $selectedExportResolution)
                }

                TimelinePanel(
                    photoURLs: selectedPhotoURLs,
                    musicURL: selectedMusicURL,
                    activePhotoIndex: activePhotoIndex
                )
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

    private func openPhotoPicker() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.resolvesAliases = true

        if panel.runModal() == .OK {
            let sortedURLs = panel.urls.sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
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
    }

    private func openMusicPicker() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.resolvesAliases = true

        if panel.runModal() == .OK {
            selectedMusicURL = panel.url
            prepareAudioPlayer(for: panel.url)
            resetPreviewState()
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

struct HeaderView: View {
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 0) {
                    Text("Brief")
                        .font(.custom("Unbounded", size: 28).weight(.black))
                        .foregroundColor(Color(red: 0.180, green: 0.205, blue: 0.245))
                        .tracking(-2.4)

                    Text("Show")
                        .font(.custom("Unbounded", size: 28).weight(.black))
                        .foregroundColor(Color(red: 0.000, green: 0.610, blue: 0.760))
                        .tracking(-2.4)
                }

                Text("Create high-resolution photo slideshows with music.")
                    .font(.custom("Figtree", size: 13).weight(.medium))
                    .foregroundColor(Color(red: 0.390, green: 0.390, blue: 0.390))
            }

            Spacer()

            Button("New Project") {}
                .buttonStyle(BrutalButtonStyle())


        }
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
                        value: $secondsPerPhoto,
                        range: 1...20,
                        step: 1,
                        suffix: "s"
                    )
                }

                CompactStepperRow(
                    label: "Fade",
                    value: $fadeDuration,
                    range: 0.5...3,
                    step: 0.5,
                    suffix: "s"
                )

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
                            transitionStyle = .fade
                        }

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

    private var timingModeHelperText: String {
        switch timingMode {
        case .followMusic:
            return "Automatically spaces photos to match the music length, with music fade-in at the start and fade-out at the end."
        case .customSpeed:
            return "Use your own seconds per photo. Fade controls image transitions, with music fade-in and fade-out applied."
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
    let onTogglePreview: () -> Void
    let onStartFromBeginning: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 12) {
                PanelTitle(title: "Preview", subtitle: "Your slideshow will appear here")
                ZStack {
                    RoundedRectangle(cornerRadius: 34)
                        .fill(Color.black)

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
                .frame(maxWidth: .infinity, minHeight: 220, maxHeight: 260)
                .clipShape(RoundedRectangle(cornerRadius: 34))

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

                Button(action: onAddMusic) {
                    DropCard(
                        icon: "music.note",
                        title: "Add Music",
                        subtitle: musicStatusText
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(Color(red: 0.957, green: 0.937, blue: 0.910))
            .overlay(
                RoundedRectangle(cornerRadius: 34)
                    .stroke(Color(red: 0.820, green: 0.780, blue: 0.710), lineWidth: 4)
            )
            .clipShape(RoundedRectangle(cornerRadius: 34))
        
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

    private let resolutions = ["480p", "720p", "1080p", "4K", "Original"]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PanelTitle(title: "Export", subtitle: "Render your video")

            VStack(alignment: .leading, spacing: 10) {
                Text("Video Settings")
                    .font(.custom("Figtree", size: 13).weight(.medium))
                    .foregroundColor(Color(red: 0.315, green: 0.340, blue: 0.390))

                SettingRow(label: "Format", value: "MP4")
                SettingRow(label: "Codec", value: "H.264")
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

                Text(exportHelperText)
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

    private func exportResolutionButton(_ resolution: String) -> some View {
        TimingModeButton(
            title: resolution,
            isSelected: selectedResolution == resolution
        ) {
            selectedResolution = resolution
        }
    }

    private var exportHelperText: String {
        "Choose a smaller size for quick sharing, 4K for crisp video, or Original to use the source image size."
    }
}

struct TimelinePanel: View {
    let photoURLs: [URL]
    let musicURL: URL?
    let activePhotoIndex: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PanelTitle(title: "Timeline", subtitle: timelineSubtitle)

            if photoURLs.isEmpty {
                EmptyTimelineStoryboard()
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(Array(photoURLs.enumerated()), id: \.offset) { index, url in
                            TimelinePhotoThumb(
                                index: index,
                                url: url,
                                isActive: index == activePhotoIndex
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
        
    }

    private var timelineSubtitle: String {
        if let musicURL {
            return "Photos arranged with \(musicURL.lastPathComponent)"
        }

        return "Add photos to build your timeline"
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
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(EmptyTimelineSceneKind.allCases) { scene in
                    EmptyTimelineSceneThumb(scene: scene)
                }

                Spacer(minLength: 0)
            }
        }
        .frame(height: 66)
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

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .regular))
                .foregroundColor(Color(red: 0.315, green: 0.340, blue: 0.390))

            VStack(spacing: 2) {
                Text(title)
                    .font(.custom("Figtree", size: 12).weight(.medium))
                    .foregroundColor(Color(red: 0.315, green: 0.340, blue: 0.390))

                HStack(spacing: 6) {
                    if isLoading {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.55)
                            .frame(width: 12, height: 12)
                    }

                    Text(subtitle)
                        .font(.custom("Figtree", size: 10).weight(.regular))
                        .foregroundColor(Color(red: 0.390, green: 0.390, blue: 0.390))
                        .lineLimit(1)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 9)
        .background(Color(red: 0.957, green: 0.937, blue: 0.910))
        .overlay(
            RoundedRectangle(cornerRadius: 22)
                .stroke(Color(red: 0.820, green: 0.780, blue: 0.710), lineWidth: 3)
        )
        .clipShape(RoundedRectangle(cornerRadius: 22))
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
            : Color(red: 0.760, green: 0.720, blue: 0.650)
    }
}

#Preview {
    ContentView()
}

