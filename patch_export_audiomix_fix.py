from pathlib import Path

path = Path("BriefShow/ContentView.swift")
src = path.read_text()

old = """    let preferredPreset: String

    if preferHEVC {
        // The rendered source video is already HEVC.
        // Add music without re-encoding the 4K video.
        preferredPreset = AVAssetExportPresetPassthrough
    } else {
        preferredPreset = AVAssetExportPresetHighestQuality
    }"""

new = """    let preferredPreset: String

    if preferHEVC && audioMix == nil {
        // The rendered source video is already HEVC.
        // Passthrough only works when there is no audio
        // mix to apply - volume ramps require re-encoding,
        // so we cannot use Passthrough once fades exist.
        preferredPreset = AVAssetExportPresetPassthrough
    } else {
        preferredPreset = AVAssetExportPresetHighestQuality
    }"""

count = src.count(old)
if count != 1:
    print(f"FAIL: found {count} occurrences, expected 1. No changes written.")
else:
    path.write_text(src.replace(old, new, 1))
    print("=== PATCH APPLIED SUCCESSFULLY ===")
