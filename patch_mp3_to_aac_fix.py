from pathlib import Path

path = Path("BriefShow/ContentView.swift")
src = path.read_text()

patches = []

# 1. Dodaj helper funkciju za konverziju MP3 -> AAC pre muxVideoWithMusic
old1 = """private func muxVideoWithMusic("""
new1 = """private func convertMusicURLToAAC(_ sourceURL: URL) throws -> URL {
    let sourceAsset = AVURLAsset(url: sourceURL)

    let tempURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("m4a")

    guard let exportSession = AVAssetExportSession(
        asset: sourceAsset,
        presetName: AVAssetExportPresetAppleM4A
    ) else {
        throw BriefShowExportError.couldNotExportWithAudio
    }

    exportSession.outputURL = tempURL
    exportSession.outputFileType = .m4a

    let semaphore = DispatchSemaphore(value: 0)
    exportSession.exportAsynchronously {
        semaphore.signal()
    }
    semaphore.wait()

    guard exportSession.status == .completed else {
        print(
            "BriefShow mux: FAILED converting music to AAC:",
            sourceURL.lastPathComponent,
            String(describing: exportSession.error)
        )
        throw exportSession.error ?? BriefShowExportError.couldNotExportWithAudio
    }

    print("BriefShow mux: converted", sourceURL.lastPathComponent, "-> AAC temp file")

    return tempURL
}

private func muxVideoWithMusic("""
patches.append(("Patch 1: add MP3->AAC conversion helper", old1, new1))

# 2. Konvertuj svaki music URL pre ucitavanja track-a
old2 = """    let musicSources: [(track: AVAssetTrack, duration: CMTime)] = musicURLs.compactMap { url in
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
new2 = """    var musicSources: [(track: AVAssetTrack, duration: CMTime)] = []

    for url in musicURLs {
        let convertedURL: URL

        do {
            convertedURL = try convertMusicURLToAAC(url)
        } catch {
            print(
                "BriefShow mux: SKIPPING music track, AAC conversion failed:",
                url.lastPathComponent,
                String(describing: error)
            )
            continue
        }

        let asset = AVURLAsset(url: convertedURL)
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
            continue
        }

        musicSources.append((track, assetDuration))
    }

    print("BriefShow mux: usable musicSources count =", musicSources.count)"""
patches.append(("Patch 2: convert each music URL to AAC before use", old2, new2))

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
