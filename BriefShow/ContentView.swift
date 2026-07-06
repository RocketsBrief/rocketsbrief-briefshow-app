import SwiftUI

struct ContentView: View {
    var body: some View {
        ZStack {
            Color(red: 0.957, green: 0.937, blue: 0.910)
                .ignoresSafeArea()

            VStack(spacing: 14) {
                HeaderView()

                HStack(spacing: 14) {
                    LeftImportPanel()
                    CenterPreviewPanel()
                    RightExportPanel()
                }

                TimelinePanel()
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
        }
        .frame(minWidth: 980, minHeight: 640)
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
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PanelTitle(title: "Media", subtitle: "Add photos and music")

            DropCard(
                icon: "photo.on.rectangle.angled",
                title: "Add Photos",
                subtitle: "Drag images here or choose files"
            )

            DropCard(
                icon: "music.note",
                title: "Add Music",
                subtitle: "MP3, WAV or M4A soundtrack"
            )

            VStack(alignment: .leading, spacing: 10) {
                Text("Slideshow Settings")
                    .font(.custom("Figtree", size: 13).weight(.medium))
                    .foregroundColor(Color(red: 0.315, green: 0.340, blue: 0.390))

                SettingRow(label: "Transition", value: "Fade")
                SettingRow(label: "Motion", value: "Soft Zoom")
                SettingRow(label: "Timing", value: "Fit to Music")
            }
            .padding(16)
            .background(Color(red: 0.957, green: 0.937, blue: 0.910))
            .overlay(
                RoundedRectangle(cornerRadius: 24)
                    .stroke(Color(red: 0.820, green: 0.780, blue: 0.710), lineWidth: 4)
            )
            .clipShape(RoundedRectangle(cornerRadius: 24))

            Spacer()
        }
        .padding(14)
        .frame(width: 250)
        .background(Color(red: 0.957, green: 0.937, blue: 0.910))
        .overlay(
            RoundedRectangle(cornerRadius: 34)
                .stroke(Color(red: 0.820, green: 0.780, blue: 0.710), lineWidth: 4)
        )
        .clipShape(RoundedRectangle(cornerRadius: 34))
        
    }
}

struct CenterPreviewPanel: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PanelTitle(title: "Preview", subtitle: "Your slideshow will appear here")

            ZStack {
                RoundedRectangle(cornerRadius: 34)
                    .fill(Color.black)

                VStack(spacing: 16) {
                    Image(systemName: "play.rectangle.fill")
                        .font(.system(size: 42))
                        .foregroundColor(Color(red: 0.957, green: 0.863, blue: 0.545))

                    Text("No slideshow yet")
                        .font(.custom("Figtree", size: 13).weight(.medium))
                        .foregroundColor(.white)

                    Text("Add photos and music to generate a preview.")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white.opacity(0.65))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(
                RoundedRectangle(cornerRadius: 34)
                    .stroke(Color(red: 0.820, green: 0.780, blue: 0.710), lineWidth: 4)
            )

            HStack {
                Button("Play Preview") {}
                    .buttonStyle(BrutalButtonStyle())

                Button("Fit to Music") {}
                    .buttonStyle(BrutalButtonStyle())

                Spacer()

                Text("00:00 / 00:00")
                    .font(.custom("Figtree", size: 12).weight(.regular))
                    .foregroundColor(Color(red: 0.390, green: 0.390, blue: 0.390))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity)
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
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PanelTitle(title: "Timeline", subtitle: "Photos will be arranged here")

            HStack(spacing: 12) {
                ForEach(0..<6) { index in
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color(red: 0.957, green: 0.937, blue: 0.910))
                        .frame(width: 92, height: 56)
                        .overlay(
                            VStack(spacing: 6) {
                                Image(systemName: "photo")
                                    .font(.system(size: 18))
                                    .foregroundColor(Color(red: 0.390, green: 0.390, blue: 0.390).opacity(0.65))

                                Text("Photo \(index + 1)")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(Color(red: 0.390, green: 0.390, blue: 0.390).opacity(0.65))
                            }
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(Color(red: 0.820, green: 0.780, blue: 0.710).opacity(0.85), lineWidth: 3)
                        )
                }

                Spacer()
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
        .padding(.vertical, 18)
        .background(Color(red: 0.957, green: 0.937, blue: 0.910))
        .overlay(
            RoundedRectangle(cornerRadius: 26)
                .stroke(Color(red: 0.820, green: 0.780, blue: 0.710), lineWidth: 4)
        )
        .clipShape(RoundedRectangle(cornerRadius: 26))
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

