import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Combine

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
    @State private var selectedMusicURL: URL?
    @State private var timingMode: SlideshowTimingMode = .followMusic
    @State private var secondsPerPhoto: Double = 5
    @State private var fadeDuration: Double = 1
    @State private var musicFadeOutSeconds: Double = 4
    @State private var shouldLoopPreview: Bool = false
    @State private var transitionStyle: SlideshowTransitionStyle = .fade
    @State private var activePhotoIndex: Int = 0
    @State private var previousPhotoIndex: Int?
    @State private var isTransitioning: Bool = false
    @State private var isPreviewPlaying: Bool = false
    @State private var previewElapsedSeconds: Double = 0

    var body: some View {
        ZStack {
            Color(red: 0.957, green: 0.937, blue: 0.910)
                .ignoresSafeArea()

            VStack(spacing: 14) {
                HeaderView()

                HStack(alignment: .top, spacing: 14) {
                    LeftImportPanel(
                        selectedPhotoCount: selectedPhotoURLs.count,
                        selectedMusicURL: selectedMusicURL,
                        timingMode: $timingMode,
                        secondsPerPhoto: $secondsPerPhoto,
                        fadeDuration: $fadeDuration,
                        musicFadeOutSeconds: $musicFadeOutSeconds,
                        shouldLoopPreview: $shouldLoopPreview,
                        transitionStyle: $transitionStyle,
                        onAddPhotos: openPhotoPicker,
                        onAddMusic: openMusicPicker
                    )
                    CenterPreviewPanel(
                        activePreviewImage: activePreviewImage,
                        previousPreviewImage: previousPreviewImage,
                        activePhotoName: activePhotoName,
                        activePhotoIndex: activePhotoIndex,
                        photoCount: selectedPhotoURLs.count,
                        transitionStyle: transitionStyle,
                        isTransitioning: isTransitioning,
                        isPreviewPlaying: isPreviewPlaying,
                        onTogglePreview: togglePreview,
                        onStartFromBeginning: startPreviewFromBeginning
                    )
                    RightExportPanel()
                }

                TimelinePanel(
                    photoURLs: selectedPhotoURLs,
                    musicURL: selectedMusicURL,
                    activePhotoIndex: activePhotoIndex
                )
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
        }
        .frame(minWidth: 980, minHeight: 640)
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            advancePreviewIfNeeded()
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
            return max(1, secondsPerPhoto)
        case .customSpeed:
            return max(1, secondsPerPhoto)
        }
    }

    private func togglePreview() {
        guard !selectedPhotoURLs.isEmpty else {
            return
        }

        isPreviewPlaying.toggle()
        previewElapsedSeconds = 0
    }

    private func advancePreviewIfNeeded() {
        guard isPreviewPlaying, !selectedPhotoURLs.isEmpty else {
            return
        }

        previewElapsedSeconds += 1

        guard previewElapsedSeconds >= currentPhotoDuration else {
            return
        }

        previewElapsedSeconds = 0

        let nextIndex = activePhotoIndex + 1

        if nextIndex >= selectedPhotoURLs.count {
            if shouldLoopPreview {
                moveToPhoto(at: 0)
            } else {
                isPreviewPlaying = false
                moveToPhoto(at: selectedPhotoURLs.count - 1)
            }
            return
        }

        moveToPhoto(at: nextIndex)
    }

    private func startPreviewFromBeginning() {
        guard !selectedPhotoURLs.isEmpty else {
            return
        }

        previousPhotoIndex = nil
        isTransitioning = false
        activePhotoIndex = 0
        previewElapsedSeconds = 0
        isPreviewPlaying = true
    }

    private func moveToPhoto(at newIndex: Int) {
        guard selectedPhotoURLs.indices.contains(newIndex), newIndex != activePhotoIndex else {
            return
        }

        if transitionStyle == .fade {
            previousPhotoIndex = activePhotoIndex
            isTransitioning = false
            activePhotoIndex = newIndex

            let duration = min(max(fadeDuration, 0.15), 3)

            DispatchQueue.main.async {
                withAnimation(.easeInOut(duration: duration)) {
                    isTransitioning = true
                }
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
                previousPhotoIndex = nil
                isTransitioning = false
            }
        } else {
            previousPhotoIndex = nil
            isTransitioning = false
            activePhotoIndex = newIndex
        }
    }

    private func resetPreviewState() {
        activePhotoIndex = 0
        previousPhotoIndex = nil
        isTransitioning = false
        previewElapsedSeconds = 0
        isPreviewPlaying = false
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
            previewImages = sortedURLs.compactMap { makePreviewImage(from: $0) }
            resetPreviewState()
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

    private func openMusicPicker() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.resolvesAliases = true

        if panel.runModal() == .OK {
            selectedMusicURL = panel.url
        }
    }
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

            Button("Export Video") {}
                .buttonStyle(PrimaryBrutalButtonStyle())
        }
    }
}

struct LeftImportPanel: View {
    let selectedPhotoCount: Int
    let selectedMusicURL: URL?
    @Binding var timingMode: SlideshowTimingMode
    @Binding var secondsPerPhoto: Double
    @Binding var fadeDuration: Double
    @Binding var musicFadeOutSeconds: Double
    @Binding var shouldLoopPreview: Bool
    @Binding var transitionStyle: SlideshowTransitionStyle
    let onAddPhotos: () -> Void
    let onAddMusic: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PanelTitle(title: "Media", subtitle: "Add photos and music")

            Button(action: onAddPhotos) {
                DropCard(
                    icon: "photo.on.rectangle.angled",
                    title: "Add Photos",
                    subtitle: selectedPhotoCount == 0 ? "Choose multiple image files" : "\(selectedPhotoCount) photo\(selectedPhotoCount == 1 ? "" : "s") selected"
                )
            }
            .buttonStyle(.plain)

            Button(action: onAddMusic) {
                DropCard(
                    icon: "music.note",
                    title: "Add Music",
                    subtitle: selectedMusicURL?.lastPathComponent ?? "MP3, WAV or M4A soundtrack"
                )
            }
            .buttonStyle(.plain)

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
                    label: "Music Fade Out",
                    value: $musicFadeOutSeconds,
                    range: 1...10,
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

            Spacer()
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
            return "Automatically spaces photos to match the music length, then fades the music out at the end."
        case .customSpeed:
            return "Use your own seconds per photo. Fade controls image transitions, and music fades out in the final seconds."
        }
    }
}

struct CenterPreviewPanel: View {
    let activePreviewImage: NSImage?
    let previousPreviewImage: NSImage?
    let activePhotoName: String
    let activePhotoIndex: Int
    let photoCount: Int
    let transitionStyle: SlideshowTransitionStyle
    let isTransitioning: Bool
    let isPreviewPlaying: Bool
    let onTogglePreview: () -> Void
    let onStartFromBeginning: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PanelTitle(title: "Preview", subtitle: "Your slideshow will appear here")

            ZStack {
                RoundedRectangle(cornerRadius: 34)
                    .fill(Color.black)

                if let activePreviewImage {
                    if transitionStyle == .fade, let previousPreviewImage {
                        Image(nsImage: previousPreviewImage)
                            .resizable()
                            .scaledToFit()
                            .opacity(isTransitioning ? 0 : 1)
                            .clipShape(RoundedRectangle(cornerRadius: 28))
                    }

                    Image(nsImage: activePreviewImage)
                        .resizable()
                        .scaledToFit()
                        .opacity(transitionStyle == .fade && previousPreviewImage != nil ? (isTransitioning ? 1 : 0) : 1)
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
            .overlay(
                RoundedRectangle(cornerRadius: 34)
                    .stroke(Color(red: 0.820, green: 0.780, blue: 0.710), lineWidth: 4)
            )

            HStack {
                PreviewControlButton(
                    title: isPreviewPlaying ? "Stop Preview" : "Play Preview",
                    isDisabled: photoCount == 0,
                    action: onTogglePreview
                )

                PreviewControlButton(
                    title: "Play From Beginning",
                    isDisabled: photoCount == 0,
                    action: onStartFromBeginning
                )

                Spacer()

                Text(photoCount == 0 ? "00:00 / 00:00" : "Photo \(activePhotoIndex + 1) / \(photoCount)")
                    .font(.custom("Figtree", size: 12).weight(.regular))
                    .foregroundColor(Color(red: 0.390, green: 0.390, blue: 0.390))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .top)
        .background(Color(red: 0.957, green: 0.937, blue: 0.910))
        .overlay(
            RoundedRectangle(cornerRadius: 34)
                .stroke(Color(red: 0.820, green: 0.780, blue: 0.710), lineWidth: 4)
        )
        .clipShape(RoundedRectangle(cornerRadius: 34))
        
    }

}

struct RightExportPanel: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PanelTitle(title: "Export", subtitle: "Render your video")

            VStack(alignment: .leading, spacing: 10) {
                SettingRow(label: "Format", value: "MP4")
                SettingRow(label: "Codec", value: "H.264")
                SettingRow(label: "Quality", value: "High")
                SettingRow(label: "Resolution", value: "4K")
                SettingRow(label: "FPS", value: "30")
            }
            .padding(16)
            .background(Color(red: 0.957, green: 0.937, blue: 0.910))
            .overlay(
                RoundedRectangle(cornerRadius: 24)
                    .stroke(Color(red: 0.820, green: 0.780, blue: 0.710), lineWidth: 4)
            )
            .clipShape(RoundedRectangle(cornerRadius: 24))
            Spacer()

            Button("Export High Resolution Video") {}
                .buttonStyle(PrimaryBrutalButtonStyle())
        }
        .padding(14)
        .frame(width: 260)
        .background(Color(red: 0.957, green: 0.937, blue: 0.910))
        .overlay(
            RoundedRectangle(cornerRadius: 34)
                .stroke(Color(red: 0.820, green: 0.780, blue: 0.710), lineWidth: 4)
        )
        .clipShape(RoundedRectangle(cornerRadius: 34))
        
    }
}

struct TimelinePanel: View {
    let photoURLs: [URL]
    let musicURL: URL?
    let activePhotoIndex: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PanelTitle(title: "Timeline", subtitle: timelineSubtitle)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    if photoURLs.isEmpty {
                        ForEach(0..<6) { index in
                            TimelinePlaceholder(index: index)
                        }
                    } else {
                        ForEach(Array(photoURLs.enumerated()), id: \.offset) { index, url in
                            TimelinePhotoThumb(
                                index: index,
                                url: url,
                                isActive: index == activePhotoIndex
                            )
                        }
                    }

                    Spacer(minLength: 0)
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

        return "Photos will be arranged here"
    }
}


struct TimelinePlaceholder: View {
    let index: Int

    var body: some View {
        RoundedRectangle(cornerRadius: 14)
            .fill(Color(red: 0.957, green: 0.937, blue: 0.910))
            .frame(width: 92, height: 56)
            .overlay(
                VStack(spacing: 6) {
                    Image(systemName: "photo")
                        .font(.system(size: 18))
                        .foregroundColor(Color(red: 0.390, green: 0.390, blue: 0.390).opacity(0.65))

                    Text("Photo \(index + 1)")
                        .font(.custom("Figtree", size: 11).weight(.medium))
                        .foregroundColor(Color(red: 0.390, green: 0.390, blue: 0.390).opacity(0.65))
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color(red: 0.820, green: 0.780, blue: 0.710).opacity(0.85), lineWidth: 3)
            )
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

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .regular))
                .foregroundColor(Color(red: 0.315, green: 0.340, blue: 0.390))

            VStack(spacing: 2) {
                Text(title)
                    .font(.custom("Figtree", size: 12).weight(.medium))
                    .foregroundColor(Color(red: 0.315, green: 0.340, blue: 0.390))

                Text(subtitle)
                    .font(.custom("Figtree", size: 10).weight(.regular))
                    .foregroundColor(Color(red: 0.390, green: 0.390, blue: 0.390))
                    .lineLimit(1)
                    .multilineTextAlignment(.center)
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

