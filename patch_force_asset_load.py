from pathlib import Path

path = Path("BriefShow/ContentView.swift")
src = path.read_text()

patches = []

# 1. Dodaj helper funkciju za prinudno potpuno ucitavanje asset-a
old1 = """private func convertMusicURLToAAC(_ sourceURL: URL) throws -> URL {"""
new1 = """private func loadAssetFullySynchronously(_ asset: AVURLAsset) {
    let semaphore = DispatchSemaphore(value: 0)
    asset.loadValuesAsynchronously(forKeys: ["tracks", "duration", "playable"]) {
        semaphore.signal()
    }
    semaphore.wait()
}

private func convertMusicURLToAAC(_ sourceURL: URL) throws -> URL {"""
patches.append(("Patch 1: add loadAssetFullySynchronously helper", old1, new1))

# 2. Prinudno ucitaj videoAsset pre koriscenja
old2 = """    let videoAsset = AVURLAsset(url: videoURL)
    let composition = AVMutableComposition()"""
new2 = """    let videoAsset = AVURLAsset(url: videoURL)
    loadAssetFullySynchronously(videoAsset)
    let composition = AVMutableComposition()"""
patches.append(("Patch 2: force-load videoAsset", old2, new2))

# 3. Prinudno ucitaj music asset (posle AAC konverzije) pre koriscenja
old3 = """        let asset = AVURLAsset(url: convertedURL)
        let assetDuration = asset.duration
        let audioTracks = asset.tracks(withMediaType: .audio)"""
new3 = """        let asset = AVURLAsset(url: convertedURL)
        loadAssetFullySynchronously(asset)
        let assetDuration = asset.duration
        let audioTracks = asset.tracks(withMediaType: .audio)"""
patches.append(("Patch 3: force-load music asset", old3, new3))

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
