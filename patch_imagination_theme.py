from pathlib import Path

path = Path("BriefShow/ContentView.swift")
src = path.read_text()

patches = []

# 1. Dodaj novi enum case
old1 = """    case origamiToon = "Origami Toon"
}"""
new1 = """    case origamiToon = "Origami Toon"
    case imagination = "Imagination"
}"""
patches.append(("Patch 1: add imagination enum case", old1, new1))

# 2. Dodaj ThemePickerOption za Imagination (posle Origami opcije)
old2 = """                ThemePickerOption(
                    title: "Origami",
                    subtitle: "Geometric folded-panel movement and page layouts.",
                    isSelected: selectedTheme == .origami,
                    isLocked: false
                ) {
                    selectedTheme = .origami
                    isPresented = false
                }"""
new2 = """                ThemePickerOption(
                    title: "Origami",
                    subtitle: "Geometric folded-panel movement and page layouts.",
                    isSelected: selectedTheme == .origami,
                    isLocked: false
                ) {
                    selectedTheme = .origami
                    isPresented = false
                }

                ThemePickerOption(
                    title: "Imagination",
                    subtitle: "Photos emerge as 3D cards from deep space.",
                    isSelected: selectedTheme == .imagination,
                    isLocked: false
                ) {
                    selectedTheme = .imagination
                    transitionStyle = .fade
                    isPresented = false
                }"""
patches.append(("Patch 2: add Imagination picker option", old2, new2))

# 3. Dodaj novi self-contained View struct ImaginationCardPage
# (ubacujemo ga odmah pre "struct CenterPreviewPanel: View {")
old3 = """struct CenterPreviewPanel: View {"""
new3 = """struct ImaginationCardPage: View {
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
}

struct CenterPreviewPanel: View {"""
patches.append(("Patch 3: add ImaginationCardPage view", old3, new3))

# 4. Zakaci novu temu u glavni switch (posle Origami grane, pre "} else {")
old4 = """                } else {
                    if transitionStyle == .fade, let
                        previousPreviewImage {"""
new4 = """                } else if visualTheme == .imagination {
                    ImaginationCardPage(
                        activeImage: activePreviewImage,
                        previousImage: previousPreviewImage,
                        transitionProgress: transitionProgress
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 28))
                } else {
                    if transitionStyle == .fade, let
                        previousPreviewImage {"""
patches.append(("Patch 4: hook Imagination into main preview switch", old4, new4))

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
