// Does a slider on the PEOPLE layer move the people as far as the same slider
// moves them on the photo?
//
// Reported 23.09 from a real shoot: *„Kada odvojim subject i background
// Exposure pojacam do kraja a selektovan je subject on malo doda svetlosti nad
// njim, kao da sam malo pomerio … Takvi su svi slidebarovi"*.
//
// run-layer-edit-parity-test.py measures a DERIVED layer (a matte over the
// photo). People is not that — it is a PIXEL layer, a cut-out of the rendered
// frame stacked over the photo (see PeopleLayerFactory) — and its path through
// the renderer was never measured. This builds the two layers the way Select
// People does, on a real photo with a real person, and compares INSIDE the
// person:
//
//     photo     = render(photo, <slider> = v)             — what the number means
//     people    = render(photo + People(<slider> = v) + Background)
//
//     people-strength <photo> [size]
import Foundation
import CoreImage
import AppKit

let args = Array(CommandLine.arguments.dropFirst())
guard let first = args.first else { print("people-strength <photo> [size]"); exit(2) }
let url = URL(fileURLWithPath: first)
let size = args.count > 1 ? (Double(args[1]) ?? 1024) : 1024

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CIContext(options: [.workingColorSpace: srgb])

func load() -> PhotoBaseImage? { PhotoEditRenderer.loadBaseImage(from: url, maxPixelSize: CGFloat(size)) }

guard let base = load() else { print("could not open \(url.path)"); exit(1) }
let neutral = PhotoEditRenderer.render(PhotoEditSettings(), on: base)
guard let layers = PeopleLayerFactory.make(from: neutral, confinedTo: nil,
                                           backgroundName: "Background", peopleName: "People") else {
    print("Vision found nobody in \(url.lastPathComponent)"); exit(1)
}
guard let personMask = SubjectMasker.personMask(for: neutral) else { print("no mask"); exit(1) }

let extent = neutral.extent
let w = Int(extent.width), h = Int(extent.height)

func rgba(_ image: CIImage) -> [UInt8] {
    var buffer = [UInt8](repeating: 0, count: w * h * 4)
    ctx.render(image.cropped(to: extent), toBitmap: &buffer, rowBytes: w * 4,
               bounds: extent, format: .RGBA8, colorSpace: srgb)
    return buffer
}

let maskPixels = rgba(personMask)
/// Mean of the photo's luminance where the person matte is solid (> 0.9).
func personMean(_ image: CIImage) -> Double {
    let px = rgba(image)
    var sum = 0.0, n = 0
    for i in stride(from: 0, to: px.count, by: 4) where maskPixels[i] > 230 {
        sum += 0.2126 * Double(px[i]) + 0.7152 * Double(px[i + 1]) + 0.0722 * Double(px[i + 2])
        n += 1
    }
    return n > 0 ? sum / Double(n) : .nan
}

let controls: [(String, WritableKeyPath<PhotoEditSettings, Double>, WritableKeyPath<LocalAdjustmentSettings, Double>, Double)] = [
    ("Exposure +1.00", \.exposure, \.exposure, 1),
    ("Exposure -1.00", \.exposure, \.exposure, -1),
    ("Contrast +1.00", \.contrast, \.contrast, 1),
    ("Shadows +1.00", \.shadows, \.shadows, 1),
    ("Highlights -1.00", \.highlights, \.highlights, -1),
    ("Whites +1.00", \.whites, \.whites, 1),
    ("Saturation -1.00", \.saturation, \.saturation, -1),
]

let before = personMean(neutral)
print("photo: \(url.lastPathComponent)  \(w)x\(h)   person mean untouched \(String(format: "%.1f", before))\n")
print("control             photo moves   People layer moves   ratio")
print(String(repeating: "-", count: 62))
var weak: [String] = []
for (label, photoKey, layerKey, value) in controls {
    var photoSettings = PhotoEditSettings()
    photoSettings[keyPath: photoKey] = value
    let photo = personMean(PhotoEditRenderer.render(photoSettings, on: load()!))

    var people = layers.people
    people.adjustments[keyPath: layerKey] = value
    var layered = PhotoEditSettings()
    layered.layers = [layers.background, people]
    let layer = personMean(PhotoEditRenderer.render(layered, on: load()!))

    let dPhoto = photo - before, dLayer = layer - before
    let ratio = abs(dPhoto) > 0.5 ? dLayer / dPhoto : .nan
    print(String(format: "%-18@  %+10.1f   %+18.1f   %6.2f", label as NSString, dPhoto, dLayer, ratio))
    if ratio.isFinite && ratio < 0.8 { weak.append(label) }
}
// THE REPORT ITSELF: the PHOTO's slider, with People and Background on it.
// Before 23.09 the people were a frozen copy and this row moved them by ~0.
print("\nphoto slider, People + Background layers on the photo")
print("control             photo alone   photo under layers   ratio")
print(String(repeating: "-", count: 62))
for (label, photoKey, _, value) in controls {
    var photoSettings = PhotoEditSettings()
    photoSettings[keyPath: photoKey] = value
    let photo = personMean(PhotoEditRenderer.render(photoSettings, on: load()!))
    photoSettings.layers = [layers.background, layers.people]
    let under = personMean(PhotoEditRenderer.render(photoSettings, on: load()!))
    let dPhoto = photo - before, dUnder = under - before
    let ratio = abs(dPhoto) > 0.5 ? dUnder / dPhoto : .nan
    print(String(format: "%-18@  %+10.1f   %+18.1f   %6.2f", label as NSString, dPhoto, dUnder, ratio))
    if ratio.isFinite && ratio < 0.8 { weak.append("photo " + label) }
}

// NEGATIVE CONTROL: the same photo slider over a People layer made the old
// way (stored pixels, no liveSource) must come out frozen — otherwise the table
// above could be passing for a reason that has nothing to do with the fix.
do {
    var frozen = layers.people
    frozen.liveSource = nil
    var s = PhotoEditSettings()
    s.exposure = 1
    let photo = personMean(PhotoEditRenderer.render(s, on: load()!))
    s.layers = [layers.background, frozen]
    let under = personMean(PhotoEditRenderer.render(s, on: load()!))
    let ratio = (under - before) / (photo - before)
    print(String(format: "\ncontrol — frozen People (before 23.09), photo Exposure +1: ratio %.2f", ratio))
    if ratio > 0.3 { weak.append("negative control did not freeze — the check measures nothing") }
}

// And a moved People layer still carries the person, not the ground under it.
var moved = layers.people
moved.x += 0.05
let movedMean = personMean(PhotoEditRenderer.render({ var s = PhotoEditSettings(); s.layers = [layers.background, moved]; return s }(), on: load()!))
print(String(format: "\nPeople moved 5%% right: person-area mean %.1f (untouched %.1f) — it renders, and is not empty", movedMean, before))
if !movedMean.isFinite { weak.append("moved layer") }

print(weak.isEmpty ? "\nRESULT: OK" : "\nRESULT: WEAK on the People layer — \(weak.joined(separator: ", "))")
exit(weak.isEmpty ? 0 : 1)
