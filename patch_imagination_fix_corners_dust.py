from pathlib import Path

path = Path("BriefShow/ContentView.swift")
src = path.read_text()

patches = []

# 1. Fix rounded corners - previousImage: scaledToFit -> scaledToFill + clipped
old1 = """                if let previousImage {
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
                }"""
new1 = """                if let previousImage {
                    Image(nsImage: previousImage)
                        .resizable()
                        .scaledToFill()
                        .frame(
                            width: proxy.size.width * 0.76,
                            height: proxy.size.height * 0.76
                        )
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 24))
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
                }"""
patches.append(("Patch 1: fix rounded corners on previousImage", old1, new1))

# 2. Fix rounded corners - activeImage: scaledToFit -> scaledToFill + clipped
old2 = """                if let activeImage {
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
                }"""
new2 = """                if let activeImage {
                    Image(nsImage: activeImage)
                        .resizable()
                        .scaledToFill()
                        .frame(
                            width: proxy.size.width * 0.76,
                            height: proxy.size.height * 0.76
                        )
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 24))
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
                }"""
patches.append(("Patch 2: fix rounded corners on activeImage", old2, new2))

# 3. Move dust overlay to be more visible - increase opacity/size and render it AFTER foreground images (on top)
old3 = """                if let activeImage {
                    blurredBackground(activeImage, size: proxy.size)
                        .opacity(easedIncoming)
                } else if let previousImage {
                    blurredBackground(previousImage, size: proxy.size)
                }

                ImaginationDustOverlay()

                if let previousImage {"""
new3 = """                if let activeImage {
                    blurredBackground(activeImage, size: proxy.size)
                        .opacity(easedIncoming)
                } else if let previousImage {
                    blurredBackground(previousImage, size: proxy.size)
                }

                if let previousImage {"""
patches.append(("Patch 3a: remove dust from behind photos", old3, new3))

old3b = """            .frame(width: proxy.size.width, height: proxy.size.height)
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
new3b = """                ImaginationDustOverlay()
                    .zIndex(50)
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
patches.append(("Patch 3b: add dust overlay on top of everything", old3b, new3b))

# 4. Zgusni i posvetli prasinu (vise cestica, vidljivije)
old4 = """private struct ImaginationDustOverlay: View {
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
}"""
new4 = """private struct ImaginationDustOverlay: View {
    @State private var animate = false

    private let particles: [(CGFloat, CGFloat, CGFloat, Double)] = (0..<55).map { _ in
        (
            CGFloat.random(in: 0...1),
            CGFloat.random(in: 0...1),
            CGFloat.random(in: 1.5...4.5),
            Double.random(in: 0.35...0.85)
        )
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                ForEach(0..<particles.count, id: \\.self) { i in
                    let p = particles[i]
                    Circle()
                        .fill(Color.white.opacity(p.3))
                        .frame(width: p.2, height: p.2)
                        .blur(radius: p.2 > 3 ? 0.6 : 0)
                        .position(
                            x: p.0 * proxy.size.width,
                            y: animate
                                ? (p.1 * proxy.size.height) - 60
                                : p.1 * proxy.size.height
                        )
                }
            }
            .onAppear {
                withAnimation(
                    .linear(duration: 10)
                        .repeatForever(autoreverses: true)
                ) {
                    animate = true
                }
            }
        }
        .allowsHitTesting(false)
    }
}"""
patches.append(("Patch 4: more visible dust particles", old4, new4))

report = []
for label, old, new in patches:
    c = src.count(old)
    report.append(f"{'OK' if c==1 else 'FAIL'} [{label}]: {c} occurrence(s)")

print("\n".join(report))
fails = [r for r in report if r.startswith("FAIL")]

if fails:
    print(f"\nABORTED - {len(fails)} failed. No changes written.")
else:
    for label, old, new in patches:
        src = src.replace(old, new, 1)
    path.write_text(src)
    print("\n=== ALL APPLIED SUCCESSFULLY ===")
