from pathlib import Path

path = Path("BriefShow/ContentView.swift")
src = path.read_text()

patches = []

# 4a. Hook u fullscreen preview
old4a = """            } else {
                ZStack {
                    Color.black

                    if transitionStyle == .fade, let previousPreviewImage {
                        FittedFullscreenImage(image: previousPreviewImage)"""
new4a = """            } else if visualTheme == .imagination {
                ImaginationCardPage(
                    activeImage: activePreviewImage,
                    previousImage: previousPreviewImage,
                    transitionProgress: transitionProgress
                )
                .frame(width: size.width, height: size.height)
            } else {
                ZStack {
                    Color.black

                    if transitionStyle == .fade, let previousPreviewImage {
                        FittedFullscreenImage(image: previousPreviewImage)"""
patches.append(("Patch 4a: hook Imagination into fullscreen preview", old4a, new4a))

# 4b. Hook u glavni CenterPreviewPanel
old4b = """                        } else {
                            if transitionStyle == .fade, let previousPreviewImage {
                                Image(nsImage: previousPreviewImage)
                                    .resizable()"""
new4b = """                        } else if visualTheme == .imagination {
                            ImaginationCardPage(
                                activeImage: activePreviewImage,
                                previousImage: previousPreviewImage,
                                transitionProgress: transitionProgress
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 28))
                        } else {
                            if transitionStyle == .fade, let previousPreviewImage {
                                Image(nsImage: previousPreviewImage)
                                    .resizable()"""
patches.append(("Patch 4b: hook Imagination into main preview panel", old4b, new4b))

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
