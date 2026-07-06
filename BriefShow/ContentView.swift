import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum SlideshowTimingMode: String {
    case followMusic = "Follow Music"
    case customSpeed = "Custom Speed"
}

struct ContentView: View {
    @State private var selectedPhotoURLs: [URL] = []
    @State private var selectedMusicURL: URL?
    @State private var timingMode: SlideshowTimingMode = .followMusic
    @State private var secondsPerPhoto: Double = 5
    @State private var fadeDuration: Double = 1
    @State private var musicFadeOutSeconds: Double = 4

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
                        onAddPhotos: openPhotoPicker,
                        onAddMusic: openMusicPicker
                    )
                    CenterPreviewPanel(firstPhotoURL: selectedPhotoURLs.first)
                    RightExportPanel()
                }

                TimelinePanel(photoURLs: selectedPhotoURLs, musicURL: selectedMusicURL)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
        }
        .frame(minWidth: 980, minHeight: 640)
    }

    private func openPhotoPicker() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.resolvesAliases = true

        if panel.runModal() == .OK {
            selectedPhotoURLs = panel.urls
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
    let firstPhotoURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PanelTitle(title: "Preview", subtitle: "Your slideshow will appear here")

            ZStack {
                RoundedRectangle(cornerRadius: 34)
                    .fill(Color.black)

                if let firstPhotoURL, let image = NSImage(contentsOf: firstPhotoURL) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 28))

                    VStack {
                        Spacer()

                        HStack {
                            Text(firstPhotoURL.lastPathComponent)
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
                Button("Play Preview") {}
                    .buttonStyle(BrutalButtonStyle())

                Spacer()

                Text("00:00 / 00:00")
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
                            TimelinePhotoThumb(index: index, url: url)
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
                .stroke(Color(red: 0.820, green: 0.780, blue: 0.710).opacity(0.85), lineWidth: 3)
        )
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
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 24, weight: .regular))
                .foregroundColor(Color(red: 0.315, green: 0.340, blue: 0.390))

            VStack(spacing: 4) {
                Text(title)
                    .font(.custom("Figtree", size: 13).weight(.medium))
                    .foregroundColor(Color(red: 0.315, green: 0.340, blue: 0.390))

                Text(subtitle)
                    .font(.custom("Figtree", size: 11).weight(.regular))
                    .foregroundColor(Color(red: 0.390, green: 0.390, blue: 0.390))
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(Color(red: 0.957, green: 0.937, blue: 0.910))
        .overlay(
            RoundedRectangle(cornerRadius: 26)
                .stroke(Color(red: 0.820, green: 0.780, blue: 0.710), lineWidth: 4)
        )
        .clipShape(RoundedRectangle(cornerRadius: 26))
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
            .font(.custom("Figtree", size: 14).weight(.medium))
            .foregroundColor(textColor)
            .scaleEffect(configuration.isPressed ? 0.985 : (isHovered ? 1.045 : 1))
            .animation(.linear(duration: 0.11), value: isHovered)
            .animation(.linear(duration: 0.08), value: configuration.isPressed)
            .padding(.horizontal, 18)
            .padding(.vertical, 9)
            .background(Color(red: 0.930, green: 0.900, blue: 0.850))
            .overlay(
                RoundedRectangle(cornerRadius: 999)
                    .stroke(borderColor, lineWidth: isHovered ? 2.4 : 2)
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

