from pathlib import Path

path = Path("BriefShow/ContentView.swift")
src = path.read_text()

old = """struct ImaginationCardPage: View {
    let activeImage: NSImage?
    let previousImage: NSImage?
    let transitionProgress: Double

    private var incomingProgress: Double {
        min(1, max(0, transitionProgress))
    }

    private var easedIncoming: Double {
        let t = incomingProgress
        return t * t * (3 - 2 * t)
    }

    private var outgoingOpacity: Double {
        max(0, 1 - incomingProgress * 1.6)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black

                if let previousImage {
                    Image(nsImage: previousImage)
                        .resizable()
                        .scaledToFit()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .opacity(outgoingOpacity)
                        .scaleEffect(1 - incomingProgress * 0.08)
                }

                if let activeImage {
                    Image(nsImage: activeImage)
                        .resizable()
                        .scaledToFit()
                        .frame(
                            width: proxy.size.width * 0.82,
                            height: proxy.size.height * 0.82
                        )
                        .background(Color.black)
                        .shadow(
                            color: Color.black.opacity(0.6),
                            radius: 24 * easedIncoming,
                            x: 0,
                            y: 12
                        )
                        .rotation3DEffect(
                            .degrees((1 - easedIncoming) * 55),
                            axis: (x: 1, y: 0.4, z: 0),
                            perspective: 0.6
                        )
                        .scaleEffect(0.35 + 0.65 * easedIncoming)
                        .opacity(easedIncoming)
                        .position(
                            x: proxy.size.width * 0.5,
                            y: proxy.size.height * 0.5
                        )
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }
}"""

new = """private struct ImaginationDustOverlay: View {
    @State private var animate = false

    private let particles: [(CGFloat, CGFloat, CGFloat)] = (0..<26).map { _ in
        (
            CGFloat.random(in: 0...1),
            CGFloat.random(in: 0...1),
            CGFloat.random(in: 1.2...3.2)
        )
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                ForEach(0..<particles.count, id: \\.self) { i in
                    let p = particles[i]
                    Circle()
                        .fill(Color.white.opacity(0.22))
                        .frame(width: p.2, height: p.2)
                        .position(
                            x: p.0 * proxy.size.width,
                            y: animate
                                ? (p.1 * proxy.size.height) - 50
                                : p.1 * proxy.size.height
                        )
                }
            }
            .onAppear {
                withAnimation(
                    .linear(duration: 9)
                        .repeatForever(autoreverses: true)
                ) {
                    animate = true
                }
            }
        }
        .allowsHitTesting(false)
    }
}

struct ImaginationCardPage: View {
    let activeImage: NSImage?
    let previousImage: NSImage?
    let transitionProgress: Double

    @State private var driftPhase: Bool = false

    private var incomingProgress: Double {
        min(1, max(0, transitionProgress))
    }

    private var easedIncoming: Double {
        let t = incomingProgress
        return 1 - pow(1 - t, 3)
    }

    private var outgoingOpacity: Double {
        max(0, 1 - incomingProgress * 1.6)
    }

    private func blurredBackground(
        _ image: NSImage,
        size: CGSize
    ) -> some View {
        Image(nsImage: image)
            .resizable()
            .scaledToFill()
            .frame(width: size.width, height: size.height)
            .blur(radius: 45)
            .brightness(-0.38)
            .saturation(0.85)
            .scaleEffect(1.18)
            .clipped()
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black

                if let activeImage {
                    blurredBackground(activeImage, size: proxy.size)
                        .opacity(easedIncoming)
                } else if let previousImage {
                    blurredBackground(previousImage, size: proxy.size)
                }

                ImaginationDustOverlay()

                if let previousImage {
                    Image(nsImage: previousImage)
                        .resizable()
                        .scaledToFit()
                        .frame(
                            width: proxy.size.width * 0.76,
                            height: proxy.size.height * 0.76
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                        .shadow(
                            color: Color.black.opacity(0.55),
                            radius: 26,
                            x: 0,
                            y: 14
                        )
                        .opacity(outgoingOpacity)
                        .position(
                            x: proxy.size.width * 0.5,
                            y: proxy.size.height * 0.5
                        )
                }

                if let activeImage {
                    Image(nsImage: activeImage)
                        .resizable()
                        .scaledToFit()
                        .frame(
                            width: proxy.size.width * 0.76,
                            height: proxy.size.height * 0.76
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                        .shadow(
                            color: Color.black.opacity(0.6),
                            radius: 28,
                            x: 0,
                            y: 16
                        )
                        .scaleEffect(1.32 - 0.32 * easedIncoming)
                        .scaleEffect(driftPhase ? 1.018 : 1.0)
                        .offset(
                            x: (1 - easedIncoming) * proxy.size.width * 0.4
                        )
                        .opacity(easedIncoming)
                        .position(
                            x: proxy.size.width * 0.5,
                            y: proxy.size.height * 0.5
                        )
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
            .onAppear {
                withAnimation(
                    .easeInOut(duration: 7)
                        .repeatForever(autoreverses: true)
                ) {
                    driftPhase = true
                }
            }
        }
    }
}"""

count = src.count(old)
if count != 1:
    print(f"FAIL: found {count} occurrences, expected 1. No changes written.")
else:
    path.write_text(src.replace(old, new, 1))
    print("=== PATCH APPLIED SUCCESSFULLY ===")
