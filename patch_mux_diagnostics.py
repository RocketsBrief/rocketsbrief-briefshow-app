from pathlib import Path

path = Path("BriefShow/ContentView.swift")
src = path.read_text()

patches = []

# 1. Dijagnostika oko video track insertTimeRange
old1 = """    let videoDuration = videoAsset.duration

    try compositionVideoTrack.insertTimeRange(
        CMTimeRange(start: .zero, duration: videoDuration),
        of: videoTrack,
        at: .zero
    )

    compositionVideoTrack.preferredTransform = videoTrack.preferredTransform"""
new1 = """    let videoDuration = videoAsset.duration

    print(
        "BriefShow mux: videoDuration =",
        videoDuration,
        "isValid:",
        videoDuration.isValid,
        "isNumeric:",
        videoDuration.isNumeric
    )

    do {
        try compositionVideoTrack.insertTimeRange(
            CMTimeRange(start: .zero, duration: videoDuration),
            of: videoTrack,
            at: .zero
        )
    } catch {
        print(
            "BriefShow mux FAILED at video insertTimeRange:",
            error.localizedDescription,
            "fullError:",
            String(describing: error)
        )
        throw error
    }

    compositionVideoTrack.preferredTransform = videoTrack.preferredTransform"""
patches.append(("Patch 1: diagnostics around video insertTimeRange", old1, new1))

# 2. Dijagnostika oko music asset duration/track ucitavanja
old2 = """        for url in musicURLs {
            let asset = AVURLAsset(url: url)
            let duration = asset.duration

            guard duration > .zero else {
                continue
            }

            musicSources.append((asset, duration))
        }"""
new2 = """        for url in musicURLs {
            let asset = AVURLAsset(url: url)
            let duration = asset.duration
            let trackCount = asset.tracks(withMediaType: .audio).count

            print(
                "BriefShow mux: music url =",
                url.lastPathComponent,
                "duration =",
                duration,
                "isValid:",
                duration.isValid,
                "audioTrackCount:",
                trackCount
            )

            guard duration > .zero else {
                print("BriefShow mux: skipping music track, duration <= 0")
                continue
            }

            musicSources.append((asset, duration))
        }

        print(
            "BriefShow mux: total usable musicSources =",
            musicSources.count
        )"""
patches.append(("Patch 2: diagnostics around music asset loading", old2, new2))

# 3. Dijagnostika oko audio insertTimeRange u petlji
old3 = """                try compositionAudioTrack.insertTimeRange(
                    CMTimeRange(
                        start: .zero,
                        duration: insertDuration
                    ),
                    of: audioTrack,
                    at: cursor
                )

                cursor += insertDuration"""
new3 = """                do {
                    try compositionAudioTrack.insertTimeRange(
                        CMTimeRange(
                            start: .zero,
                            duration: insertDuration
                        ),
                        of: audioTrack,
                        at: cursor
                    )
                } catch {
                    print(
                        "BriefShow mux FAILED at audio insertTimeRange:",
                        "cursor:",
                        cursor,
                        "insertDuration:",
                        insertDuration,
                        "error:",
                        error.localizedDescription,
                        "fullError:",
                        String(describing: error)
                    )
                    throw error
                }

                cursor += insertDuration"""
patches.append(("Patch 3: diagnostics around audio insertTimeRange", old3, new3))

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
