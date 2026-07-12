from pathlib import Path

path = Path("BriefShow/ContentView.swift")
src = path.read_text()

patches = []

# 1. Dijagnostika oko video insertTimeRange
old1 = """    let videoDuration = videoAsset.duration
    try compositionVideoTrack.insertTimeRange(
        CMTimeRange(start: .zero, duration: videoDuration),
        of: sourceVideoTrack,
        at: .zero
    )
    compositionVideoTrack.preferredTransform = sourceVideoTrack.preferredTransform"""
new1 = """    let videoDuration = videoAsset.duration
    print("BriefShow mux: videoDuration =", videoDuration, "isValid:", videoDuration.isValid)
    do {
        try compositionVideoTrack.insertTimeRange(
            CMTimeRange(start: .zero, duration: videoDuration),
            of: sourceVideoTrack,
            at: .zero
        )
    } catch {
        print("BriefShow mux FAILED at video insertTimeRange:", String(describing: error))
        throw error
    }
    compositionVideoTrack.preferredTransform = sourceVideoTrack.preferredTransform"""
patches.append(("Patch 1: video insertTimeRange diagnostics", old1, new1))

# 2. Dijagnostika oko musicSources ucitavanja
old2 = """    let musicSources: [(track: AVAssetTrack, duration: CMTime)] = musicURLs.compactMap { url in
        let asset = AVURLAsset(url: url)

        guard let track = asset.tracks(withMediaType: .audio).first,
              asset.duration > .zero else {
            return nil
        }

        return (track, asset.duration)
    }"""
new2 = """    let musicSources: [(track: AVAssetTrack, duration: CMTime)] = musicURLs.compactMap { url in
        let asset = AVURLAsset(url: url)
        let assetDuration = asset.duration
        let audioTracks = asset.tracks(withMediaType: .audio)

        print(
            "BriefShow mux: music url =", url.lastPathComponent,
            "duration =", assetDuration,
            "isValid:", assetDuration.isValid,
            "audioTrackCount:", audioTracks.count
        )

        guard let track = audioTracks.first,
              assetDuration > .zero else {
            print("BriefShow mux: SKIPPING music track (no track or zero duration)")
            return nil
        }

        return (track, assetDuration)
    }

    print("BriefShow mux: usable musicSources count =", musicSources.count)"""
patches.append(("Patch 2: musicSources loading diagnostics", old2, new2))

# 3. Dijagnostika oko audio insertTimeRange u petlji
old3 = """            try compositionAudioTrack.insertTimeRange(
                CMTimeRange(start: .zero, duration: audioSegmentDuration),
                of: source.track,
                at: insertedAudioDuration
            )

            insertedAudioDuration = insertedAudioDuration + audioSegmentDuration
            sourceIndex += 1"""
new3 = """            do {
                try compositionAudioTrack.insertTimeRange(
                    CMTimeRange(start: .zero, duration: audioSegmentDuration),
                    of: source.track,
                    at: insertedAudioDuration
                )
            } catch {
                print(
                    "BriefShow mux FAILED at audio insertTimeRange:",
                    "insertedAudioDuration:", insertedAudioDuration,
                    "audioSegmentDuration:", audioSegmentDuration,
                    "error:", String(describing: error)
                )
                throw error
            }

            insertedAudioDuration = insertedAudioDuration + audioSegmentDuration
            sourceIndex += 1"""
patches.append(("Patch 3: audio insertTimeRange diagnostics", old3, new3))

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
