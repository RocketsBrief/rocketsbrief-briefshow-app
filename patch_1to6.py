from pathlib import Path

path = Path("BriefShow/ContentView.swift")
src = path.read_text()

patches = []

old1 = """    @State private var origamiImagesBeforePageChange: Int = 2
    @State private var origamiInternalHoldSeconds: Double = 3.5"""
new1 = """    @State private var origamiImagesBeforePageChange: Int = 2
    @State private var origamiInternalHoldSeconds: Double = 3.5
    @State private var origamiSimultaneousSwapCount: Int = 1"""
patches.append(("Patch 1", old1, new1))

old2 = """    @State private var origamiActiveSwapImages: [Int: NSImage] = [:]
    @State private var origamiActiveSwapStyles: [Int: Int] = [:]
    @State private var origamiSwapProgress: Double = 1
    @State private var isOrigamiSwapAnimating: Bool = false"""
new2 = """    @State private var origamiActiveSwapImages: [Int: NSImage] = [:]
    @State private var origamiActiveSwapStyles: [Int: Int] = [:]
    @State private var origamiSwapProgress: Double = 1
    @State private var isOrigamiSwapAnimating: Bool = false
    @State private var isOrigamiWholePageFoldAnimating: Bool = false"""
patches.append(("Patch 2", old2, new2))

old3 = """        let batchCount =
            currentOrigamiReplacementCount
                - origamiCompletedSwapCount"""
new3 = """        let batchCount = min(
            max(1, origamiSimultaneousSwapCount),
            currentOrigamiReplacementCount
                - origamiCompletedSwapCount
        )"""
patches.append(("Patch 3", old3, new3))

old4 = """            guard transitionProgress >= 0.999,
                  !isOrigamiSwapAnimating
            else {
                return
            }"""
new4 = """            guard transitionProgress >= 0.999,
                  !isOrigamiSwapAnimating,
                  !isOrigamiWholePageFoldAnimating
            else {
                return
            }"""
patches.append(("Patch 4", old4, new4))

old5 = """                origamiWholePageFoldProgress = 0

                origamiPageIndex ="""
new5 = """                origamiWholePageFoldProgress = 0

                isOrigamiWholePageFoldAnimating = true

                origamiPageIndex ="""
patches.append(("Patch 5", old5, new5))

old6 = """            DispatchQueue.main.asyncAfter(
                deadline:
                    .now()
                    + duration
                    + 0.04
            ) {
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
            }"""
new6 = """            DispatchQueue.main.asyncAfter(
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
            }"""
patches.append(("Patch 6", old6, new6))

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
