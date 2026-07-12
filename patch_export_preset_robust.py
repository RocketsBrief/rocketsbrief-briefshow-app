from pathlib import Path

path = Path("BriefShow/ContentView.swift")
src = path.read_text()

old = """    let preferredPreset: String

    if preferHEVC && audioMix == nil {
        // The rendered source video is already HEVC.
        // Passthrough only works when there is no audio
        // mix to apply - volume ramps require re-encoding,
        // so we cannot use Passthrough once fades exist.
        preferredPreset = AVAssetExportPresetPassthrough
    } else {
        preferredPreset = AVAssetExportPresetHighestQuality
    }

    print(
        "BriefShow mux preset:",
        preferredPreset,
        "preferHEVC:",
        preferHEVC
    )

    guard let exportSession = AVAssetExportSession(
        asset: composition,
        presetName: preferredPreset
    ) else {
        throw BriefShowExportError.couldNotExportWithAudio
    }

    exportSession.outputURL = outputURL
    exportSession.outputFileType = .mp4
    exportSession.audioMix = audioMix
    exportSession.shouldOptimizeForNetworkUse = true

    let semaphore = DispatchSemaphore(value: 0)
    exportSession.exportAsynchronously {
        semaphore.signal()
    }
    semaphore.wait()

    if exportSession.status != .completed {
        throw exportSession.error ?? BriefShowExportError.couldNotExportWithAudio
    }
}"""

new = """    // Passthrough is only safe on AVMutableComposition when
    // AVFoundation itself reports it as compatible, and never
    // when we need to apply an audio mix (volume ramps require
    // re-encoding, which Passthrough cannot do).
    let compatiblePresets = AVAssetExportSession.exportPresets(compatibleWith: composition)
    let passthroughIsSafe = audioMix == nil
        && compatiblePresets.contains(AVAssetExportPresetPassthrough)

    let preferredPreset: String = (preferHEVC && passthroughIsSafe)
        ? AVAssetExportPresetPassthrough
        : AVAssetExportPresetHighestQuality

    print(
        "BriefShow mux preset:",
        preferredPreset,
        "preferHEVC:",
        preferHEVC,
        "passthroughIsSafe:",
        passthroughIsSafe,
        "compatiblePresets:",
        compatiblePresets
    )

    guard let exportSession = AVAssetExportSession(
        asset: composition,
        presetName: preferredPreset
    ) else {
        throw BriefShowExportError.couldNotExportWithAudio
    }

    exportSession.outputURL = outputURL
    exportSession.outputFileType = .mp4
    exportSession.audioMix = audioMix
    exportSession.shouldOptimizeForNetworkUse = true

    let semaphore = DispatchSemaphore(value: 0)
    exportSession.exportAsynchronously {
        semaphore.signal()
    }
    semaphore.wait()

    if exportSession.status != .completed {
        let underlyingError = exportSession.error
        print(
            "BriefShow mux FAILED - status:",
            exportSession.status.rawValue,
            "error:",
            underlyingError?.localizedDescription ?? "nil",
            "fullError:",
            String(describing: underlyingError)
        )
        throw underlyingError ?? BriefShowExportError.couldNotExportWithAudio
    }
}"""

count = src.count(old)
if count != 1:
    print(f"FAIL: found {count} occurrences, expected 1. No changes written.")
else:
    path.write_text(src.replace(old, new, 1))
    print("=== PATCH APPLIED SUCCESSFULLY ===")
