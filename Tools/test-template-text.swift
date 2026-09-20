// Text on the print, measured in the pixels it actually draws.
//
// This compiles the REAL BriefShow/Templates.swift — the file that ships — and
// renders through its own `briefShowComposeTemplate`. Nothing here is a copy
// of the layout.
//
// The one thing that decides whether this feature works at all: a text must
// land in the SAME PLACE and at the SAME SIZE on the preview canvas as on the
// 300 dpi print. Everything the client places on screen is placed on a canvas
// a few hundred pixels wide; what comes out of the printer is ten times that.
// A size in pixels, or a layout measured against the preview, would be a text
// that moves and resizes on its way to the paper — and he would only find out
// once it was printed.
//
//     template-text
import Foundation
import CoreGraphics
import CoreImage
import CoreText

// ---- the real click decision, pasted in by the extractor at run time ------

var failures = 0

func check(_ label: String, _ passed: Bool, _ detail: String = "") {
    if passed {
        print("  ok    \(label)")
    } else {
        failures += 1
        print("  FAIL  \(label)\(detail.isEmpty ? "" : "   \(detail)")")
    }
}

func close(_ a: Double, _ b: Double, _ tolerance: Double) -> Bool {
    abs(a - b) <= tolerance
}

let context = CIContext(options: [.useSoftwareRenderer: true])

/// A photograph of a flat colour, so any pixel that is not that colour and not
/// paper-white is ink.
func photo(width: Int, height: Int, red: CGFloat = 0.2, green: CGFloat = 0.4, blue: CGFloat = 0.8) -> CIImage {
    CIImage(color: CIColor(red: red, green: green, blue: blue))
        .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
}

struct Bitmap {
    let width: Int
    let height: Int
    let pixels: [UInt8]   // RGBA, top row first

    func at(x: Int, y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
        let i = (y * width + x) * 4
        guard i + 3 < pixels.count else { return (0, 0, 0, 0) }
        return (Int(pixels[i]), Int(pixels[i + 1]), Int(pixels[i + 2]), Int(pixels[i + 3]))
    }

    /// The bounding box of everything darker than the paper, as FRACTIONS of
    /// the canvas — which is the only way two canvases of different sizes can
    /// be compared at all.
    func inkBounds(darkerThan level: Int = 128) -> (x: Double, y: Double, width: Double, height: Double)? {
        var minX = width, maxX = -1, minY = height, maxY = -1
        for y in 0..<height {
            for x in 0..<width {
                let p = at(x: x, y: y)
                if p.r < level && p.g < level && p.b < level {
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            }
        }
        guard maxX >= 0 else { return nil }
        return (Double(minX) / Double(width),
                Double(minY) / Double(height),
                Double(maxX - minX + 1) / Double(width),
                Double(maxY - minY + 1) / Double(height))
    }
}

func render(_ image: CIImage, width: Int, height: Int) -> Bitmap {
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let rect = CGRect(x: 0, y: 0, width: width, height: height)
    pixels.withUnsafeMutableBytes { raw in
        context.render(image,
                       toBitmap: raw.baseAddress!,
                       rowBytes: width * 4,
                       bounds: rect,
                       format: .RGBA8,
                       colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }
    return Bitmap(width: width, height: height, pixels: pixels)
}

// A template with no art at all: the white paper and a slot. The text is what
// is being measured, and a drawing over it would be one more thing to explain
// when a check fails.
let slot = TemplateSlot(rect: NormalizedRect(x: 0.1, y: 0.1, width: 0.8, height: 0.6),
                        detection: nil)
let template = PrintTemplate(name: "8×10 H",
                             size: .eightByTen,
                             orientation: .horizontal,
                             slot: slot,
                             artOverPhoto: true,
                             artRef: "none",
                             artPixelWidth: 3000,
                             artPixelHeight: 2400,
                             pairID: nil)

let printed = template.canvasPixels      // 3000 × 2400
let previewScale = 0.2                   // 600 × 480, about what the editor draws

func compose(_ texts: [TemplateText], scale: Double) -> Bitmap {
    let width = Int((Double(printed.width) * scale).rounded())
    let height = Int((Double(printed.height) * scale).rounded())
    let image = briefShowComposeTemplate(photo: photo(width: 1200, height: 900),
                                         template: template,
                                         art: nil,
                                         placement: .centred,
                                         artOverPhoto: true,
                                         texts: texts,
                                         canvasScale: scale)
    return render(image, width: width, height: height)
}

// MARK: - The same place and the same size on both canvases

print("\nthe preview and the print agree about the text")

var line = TemplateText()
line.text = "Karisic Studio"
line.fontFamily = "Helvetica"
line.fontFace = "Regular"
line.sizeInches = 0.5
line.color = .black
line.alignment = .center
line.box = NormalizedRect(x: 0.1, y: 0.78, width: 0.8, height: 0.12)

let onPreview = compose([line], scale: previewScale).inkBounds()
let onPrint = compose([line], scale: 1).inkBounds()

check("the text is drawn on the preview", onPreview != nil)
check("the text is drawn on the print", onPrint != nil)

if let preview = onPreview, let print_ = onPrint {
    // A fraction of the canvas, on a canvas five times bigger. A pixel of
    // hinting difference at 600 px wide is 0.0017 of the canvas, so the
    // tolerance is a little over two of those.
    check("it starts at the same place across the paper",
          close(preview.x, print_.x, 0.004),
          String(format: "preview %.4f, print %.4f", preview.x, print_.x))
    check("and at the same height down it",
          close(preview.y, print_.y, 0.006),
          String(format: "preview %.4f, print %.4f", preview.y, print_.y))
    check("it is the same width of paper",
          close(preview.width, print_.width, 0.006),
          String(format: "preview %.4f, print %.4f", preview.width, print_.width))
    check("and the same height",
          close(preview.height, print_.height, 0.008),
          String(format: "preview %.4f, print %.4f", preview.height, print_.height))
}

// MARK: - The size is inches of print

print("\nthe size is inches of paper, not pixels of canvas")

check("an inch is 300 px on the print",
      close(briefShowPixelsPerInch(template: template, canvasWidth: Double(printed.width)), 300, 1e-9))
check("and 60 px on a canvas drawn at a fifth",
      close(briefShowPixelsPerInch(template: template,
                                   canvasWidth: Double(printed.width) * previewScale), 60, 1e-9))

do {
    // Double the size, double the ink. Measured as a fraction of the canvas,
    // which is what a print size has to be independent of.
    var big = line
    big.sizeInches = 1.0
    let small = compose([line], scale: 1).inkBounds()
    let large = compose([big], scale: 1).inkBounds()
    if let small, let large {
        let ratio = large.height / small.height
        check("0.5 in against 1.0 in is about twice the ink",
              ratio > 1.8 && ratio < 2.2, String(format: "%.2f×", ratio))
    } else {
        check("0.5 in against 1.0 in is about twice the ink", false, "nothing drawn")
    }
}

// MARK: - Alignment inside the box

print("\nthe text sits where the alignment says inside its own box")

do {
    var left = line, centre = line, right = line
    left.alignment = .left
    centre.alignment = .center
    right.alignment = .right

    let l = compose([left], scale: 1).inkBounds()
    let c = compose([centre], scale: 1).inkBounds()
    let r = compose([right], scale: 1).inkBounds()

    if let l, let c, let r {
        check("left starts at the box's left edge", close(l.x, line.box.x, 0.01),
              String(format: "%.4f against %.4f", l.x, line.box.x))
        check("right ends at its right edge",
              close(r.x + r.width, line.box.x + line.box.width, 0.01),
              String(format: "%.4f against %.4f", r.x + r.width, line.box.x + line.box.width))
        check("centre is centred in it",
              close(c.x + c.width / 2, line.box.x + line.box.width / 2, 0.01),
              String(format: "%.4f against %.4f", c.x + c.width / 2, line.box.x + line.box.width / 2))
        check("and all three are the same width of ink",
              close(l.width, c.width, 0.004) && close(c.width, r.width, 0.004),
              String(format: "%.4f / %.4f / %.4f", l.width, c.width, r.width))
    } else {
        check("the three alignments all drew", false)
    }
}

// MARK: - Above everything, both ways round

print("\ntext is on top of the print, whichever way the print is stacked")

do {
    // The art here is a solid black sheet — if the text were drawn UNDER it,
    // nothing of the text would survive.
    let art = CIImage(color: CIColor(red: 0, green: 0, blue: 0))
        .cropped(to: CGRect(x: 0, y: 0, width: 3000, height: 2400))
    var white = line
    white.color = .white

    for artOver in [true, false] {
        let image = briefShowComposeTemplate(photo: photo(width: 1200, height: 900),
                                             template: template,
                                             art: art,
                                             placement: .centred,
                                             artOverPhoto: artOver,
                                             texts: [white],
                                             canvasScale: previewScale)
        let map = render(image, width: 600, height: 480)
        var whitePixels = 0
        for y in 0..<map.height {
            for x in 0..<map.width {
                let p = map.at(x: x, y: y)
                if p.r > 200 && p.g > 200 && p.b > 200 { whitePixels += 1 }
            }
        }
        check("the text shows with the art \(artOver ? "over" : "under") the photo",
              whitePixels > 200, "\(whitePixels) lit pixels")
    }
}

// MARK: - Nothing to draw

print("\nnothing written, nothing drawn")

do {
    var empty = line
    empty.text = ""
    check("an empty text draws nothing",
          briefShowDrawTemplateText(empty, template: template,
                                    canvas: CGRect(x: 0, y: 0, width: 3000, height: 2400)) == nil)

    var invisible = line
    invisible.opacity = 0
    check("a text at zero opacity draws nothing",
          briefShowDrawTemplateText(invisible, template: template,
                                    canvas: CGRect(x: 0, y: 0, width: 3000, height: 2400)) == nil)

    let bare = compose([], scale: previewScale).inkBounds()
    check("a print with no text has no ink on its paper", bare == nil)
}

// MARK: - Placing it

print("\nthe box moves with the drag and stays on the paper")

do {
    let start = NormalizedRect(x: 0.1, y: 0.8, width: 0.8, height: 0.1)
    let moved = briefShowTextBoxAfterDrag(start, translation: CGSize(width: 60, height: -120),
                                          canvasWidth: 600, canvasHeight: 480)
    check("a drag moves it by the same fraction of the canvas",
          close(moved.x, 0.2, 1e-9) && close(moved.y, 0.55, 1e-9),
          String(format: "%.4f, %.4f", moved.x, moved.y))

    let far = briefShowTextBoxAfterDrag(start, translation: CGSize(width: 10_000, height: 10_000),
                                        canvasWidth: 600, canvasHeight: 480)
    check("it can hang half off the paper", far.x > 0.5 && far.y > 0.5,
          String(format: "%.4f, %.4f", far.x, far.y))
    check("but never all the way off",
          far.x <= 1 - far.width / 2 + 1e-9 && far.y <= 1 - far.height / 2 + 1e-9,
          String(format: "%.4f, %.4f", far.x, far.y))

    // Over the photograph is allowed — the same answer KORAK 198.6 gave for
    // the photograph itself. What is NOT allowed is off the paper.
    let onto = briefShowTextBoxAfterDrag(start, translation: CGSize(width: 0, height: -300),
                                         canvasWidth: 600, canvasHeight: 480)
    check("it may be dragged onto the picture", onto.y < 0.4, String(format: "%.4f", onto.y))
}

// MARK: - The font

print("\nthe font a record asks for")

do {
    let font = briefShowTemplateTextFont(family: "Helvetica", face: "Bold", sizePixels: 120)
    check("the family asked for is the family returned",
          (CTFontCopyFamilyName(font) as String) == "Helvetica",
          CTFontCopyFamilyName(font) as String)
    check("and the size is the size", close(Double(CTFontGetSize(font)), 120, 1e-9))

    // A family nobody has. It must still draw — a print that silently loses
    // its text is worse than a print in another face.
    let missing = briefShowTemplateTextFont(family: "No Such Family At All",
                                            face: "Regular", sizePixels: 60)
    check("a missing family still gives a font", CTFontGetSize(missing) > 0)

    var unknown = line
    unknown.fontFamily = "No Such Family At All"
    check("and a text set in it still draws",
          briefShowDrawTemplateText(unknown, template: template,
                                    canvas: CGRect(x: 0, y: 0, width: 3000, height: 2400)) != nil)

    check("the machine's families are listed", briefShowInstalledFontFamilies().count > 10)
    check("none of them is a private system face",
          !briefShowInstalledFontFamilies().contains { $0.hasPrefix(".") })
    let faces = briefShowFontFaces(in: "Helvetica")
    check("Helvetica has faces, Regular first",
          faces.first == "Regular" && faces.count > 1, "\(faces)")
}

// MARK: - On an ordinary photograph, with no template at all

print("\ntext on a photograph that is not a print")

func renderPhotoText(_ texts: [TemplateText], width: Int, height: Int,
                     originX: Double = 0, originY: Double = 0) -> Bitmap {
    let picture = CIImage(color: CIColor(red: 1, green: 1, blue: 1))
        .cropped(to: CGRect(x: originX, y: originY,
                            width: Double(width), height: Double(height)))
    let drawn = briefShowComposeTextsOnPhoto(texts, over: picture)
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    pixels.withUnsafeMutableBytes { raw in
        context.render(drawn, toBitmap: raw.baseAddress!, rowBytes: width * 4,
                       bounds: CGRect(x: originX, y: originY,
                                      width: Double(width), height: Double(height)),
                       format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }
    return Bitmap(width: width, height: height, pixels: pixels)
}

do {
    var onPhoto = line
    onPhoto.box = NormalizedRect(x: 0.1, y: 0.75, width: 0.8, height: 0.15)

    // The SAME rule as the print: the preview the client places it on is a
    // fraction of the size of the file he exports.
    let small = renderPhotoText([onPhoto], width: 1200, height: 900).inkBounds()
    let large = renderPhotoText([onPhoto], width: 6000, height: 4500).inkBounds()

    check("text is drawn on a photo with no template", small != nil && large != nil)
    if let small, let large {
        check("it starts at the same place across the picture",
              close(small.x, large.x, 0.006),
              String(format: "%.4f against %.4f", small.x, large.x))
        check("and at the same height down it",
              close(small.y, large.y, 0.008),
              String(format: "%.4f against %.4f", small.y, large.y))
        check("and it is the same fraction of the picture wide",
              close(small.width, large.width, 0.008),
              String(format: "%.4f against %.4f", small.width, large.width))
    }

    // An inch is the photograph's long edge divided by the length it is taken
    // to have — the number a size in inches is only meaningful against.
    check("an inch of a 6000 px photo is \(Int(6000 / briefShowPhotoLongEdgeInches)) px",
          close(briefShowPhotoPixelsPerInch(canvasWidth: 6000, canvasHeight: 4500),
                6000 / briefShowPhotoLongEdgeInches, 1e-9))
    check("and the long edge is what decides it, upright or not",
          close(briefShowPhotoPixelsPerInch(canvasWidth: 4500, canvasHeight: 6000),
                6000 / briefShowPhotoLongEdgeInches, 1e-9))

    check("a photo with nothing written on it is untouched",
          renderPhotoText([], width: 1200, height: 900).inkBounds() == nil)
}

do {
    // ⚠️ A CROPPED photograph's extent does not start at zero. Laid out as if
    // it did, the text would sit off the picture by however far the crop moved
    // it — and every export of a cropped photo would be missing its writing.
    var onPhoto = line
    onPhoto.box = NormalizedRect(x: 0.1, y: 0.75, width: 0.8, height: 0.15)
    let atOrigin = renderPhotoText([onPhoto], width: 1200, height: 900).inkBounds()
    let moved = renderPhotoText([onPhoto], width: 1200, height: 900,
                                originX: 500, originY: 300).inkBounds()
    check("a cropped photo has its text in the same place", moved != nil)
    if let atOrigin, let moved {
        check("and not offset by wherever the crop began",
              close(atOrigin.x, moved.x, 0.002) && close(atOrigin.y, moved.y, 0.002),
              String(format: "%.4f,%.4f against %.4f,%.4f",
                     atOrigin.x, atOrigin.y, moved.x, moved.y))
    }
}

// MARK: - Typing on the picture itself

print("\na second click on the same line opens it for typing")

do {
    let one = UUID(), two = UUID()
    let now = Date()
    let interval = 0.5

    check("a second click on the same line, soon enough, opens it",
          briefShowIsSecondTextClick(previous: (one, now.addingTimeInterval(-0.2)),
                                     id: one, at: now, interval: interval))
    check("a slow second click does not",
          !briefShowIsSecondTextClick(previous: (one, now.addingTimeInterval(-2)),
                                      id: one, at: now, interval: interval))
    check("a second click on ANOTHER line does not",
          !briefShowIsSecondTextClick(previous: (two, now.addingTimeInterval(-0.2)),
                                      id: one, at: now, interval: interval))
    check("and neither does the very first click",
          !briefShowIsSecondTextClick(previous: nil, id: one, at: now, interval: interval))
    // NTP, sleep/wake: a clock that jumps backwards must not open anything.
    check("a clock that goes backwards opens nothing",
          !briefShowIsSecondTextClick(previous: (one, now.addingTimeInterval(0.3)),
                                      id: one, at: now, interval: interval))
    check("exactly on the interval still counts",
          briefShowIsSecondTextClick(previous: (one, now.addingTimeInterval(-interval)),
                                     id: one, at: now, interval: interval))
}

// MARK: - Colour, in the app's own picker

print("\nthe colour maths behind the app's own picker")

do {
    // Round trip through HSB, on colours that are not greys.
    //
    // ⚠️ The number of them is COUNTED, not assumed. Written as a loop that
    // only reports its failures, this passes just as loudly when the loop
    // never runs at all — which is a check that cannot fail.
    var roundTripped = 0
    for swatch in briefShowTextSwatches where !(swatch.red == swatch.green && swatch.green == swatch.blue) {
        let back = briefShowColor(from: briefShowHSB(of: swatch), alpha: swatch.alpha)
        let same = abs(back.red - swatch.red) < 0.002
            && abs(back.green - swatch.green) < 0.002
            && abs(back.blue - swatch.blue) < 0.002
        if !same {
            check("\(briefShowHexString(swatch)) survives a trip through HSB", false,
                  "\(briefShowHexString(back))")
        }
        roundTripped += 1
    }
    check("all \(roundTripped) colours survive a trip through HSB", roundTripped == 7,
          "\(roundTripped) were tried, not 7")

    check("hue 0 at full saturation is red",
          briefShowHexString(briefShowColor(from: TemplateTextHSB(hue: 0, saturation: 1, brightness: 1))) == "#FF0000")
    check("a third of the way round is green",
          briefShowHexString(briefShowColor(from: TemplateTextHSB(hue: 1.0 / 3, saturation: 1, brightness: 1))) == "#00FF00")
    check("two thirds is blue",
          briefShowHexString(briefShowColor(from: TemplateTextHSB(hue: 2.0 / 3, saturation: 1, brightness: 1))) == "#0000FF")
    // ⚠️ Hue is a CIRCLE, and the check has to be one that needs it. "1.0 is
    // red" passes even with the wrap removed, because the sector is taken
    // modulo six anyway — measured, 21.09. A hue BELOW zero is what the
    // modulo cannot save: it lands on a negative sector and falls through to
    // the last branch, which is a colour nobody asked for.
    check("hue 1.0 is the same red as 0.0",
          briefShowHexString(briefShowColor(from: TemplateTextHSB(hue: 1, saturation: 1, brightness: 1))) == "#FF0000")
    check("a hue below zero wraps round the circle",
          briefShowHexString(briefShowColor(from: TemplateTextHSB(hue: -0.25, saturation: 1, brightness: 1)))
            == briefShowHexString(briefShowColor(from: TemplateTextHSB(hue: 0.75, saturation: 1, brightness: 1))),
          briefShowHexString(briefShowColor(from: TemplateTextHSB(hue: -0.25, saturation: 1, brightness: 1))))
    check("and a hue past one comes round to the same place",
          briefShowHexString(briefShowColor(from: TemplateTextHSB(hue: 1.5, saturation: 1, brightness: 1)))
            == briefShowHexString(briefShowColor(from: TemplateTextHSB(hue: 0.5, saturation: 1, brightness: 1))))
    check("no saturation is a grey", 
          briefShowHexString(briefShowColor(from: TemplateTextHSB(hue: 0.5, saturation: 0, brightness: 0.5))) == "#808080")
    check("no brightness is black",
          briefShowHexString(briefShowColor(from: TemplateTextHSB(hue: 0.5, saturation: 1, brightness: 0))) == "#000000")

    // The alpha is carried, not quietly made opaque — a half-transparent text
    // must survive a nudge of the hue.
    let faded = briefShowColor(from: TemplateTextHSB(hue: 0.2, saturation: 0.5, brightness: 0.5), alpha: 0.4)
    check("the alpha is carried through the picker", abs(faded.alpha - 0.4) < 1e-9, "\(faded.alpha)")
}

do {
    check("white is #FFFFFF", briefShowHexString(.white) == "#FFFFFF")
    check("black is #000000", briefShowHexString(.black) == "#000000")

    check("a typed hex is read", briefShowColor(fromHex: "#FF8000").map { briefShowHexString($0) } == "#FF8000")
    check("without the hash too", briefShowColor(fromHex: "ff8000").map { briefShowHexString($0) } == "#FF8000")
    check("and the three-digit form", briefShowColor(fromHex: "#fff").map { briefShowHexString($0) } == "#FFFFFF")
    check("whitespace does not stop it", briefShowColor(fromHex: "  #00FF00 ") != nil)

    // ⚠️ nil, NOT black. Half a code typed is not the colour black, and taking
    // it as one would repaint the text while the client is still typing.
    check("half a code means nothing", briefShowColor(fromHex: "#1A") == nil)
    check("so does a word", briefShowColor(fromHex: "blue") == nil)
    check("and so does a code with a letter that is not a digit",
          briefShowColor(fromHex: "#GGGGGG") == nil)
    check("an empty field means nothing", briefShowColor(fromHex: "") == nil)

    check("the swatch row has twelve", briefShowTextSwatches.count == 12)
    check("and it opens with the two a print is written in",
          briefShowTextSwatches.first == .black && briefShowTextSwatches[4] == .white)
}

// MARK: - Seeing what you type

print("\nthe plate a line is typed on")

do {
    // The report, 21.09: black text typed on the app's own near-black plate.
    // So the measurement is the one that describes it — contrast, not "is the
    // plate light".
    check("black on its plate is readable",
          briefShowContrastRatio(.black, briefShowEditingPlate(for: .black)) > 9,
          String(format: "%.1f:1", briefShowContrastRatio(.black, briefShowEditingPlate(for: .black))))
    check("white on its plate is readable",
          briefShowContrastRatio(.white, briefShowEditingPlate(for: .white)) > 9,
          String(format: "%.1f:1", briefShowContrastRatio(.white, briefShowEditingPlate(for: .white))))

    // ⚠️ THE FAULT ITSELF: the app's dark theme background under black text.
    // If this ever stops failing, the check above has stopped measuring.
    let theme = TemplateTextColor(red: 0.12, green: 0.12, blue: 0.13)
    check("black on the app's own dark panel is NOT readable — which is the bug",
          briefShowContrastRatio(.black, theme) < 2,
          String(format: "%.1f:1", briefShowContrastRatio(.black, theme)))

    // Every colour the picker offers, and the greys in between, has to be
    // typeable. 4.5:1 is the usual floor for text.
    var worst = 21.0
    var worstColour = TemplateTextColor.black
    var tried = 0
    for swatch in briefShowTextSwatches {
        let ratio = briefShowContrastRatio(swatch, briefShowEditingPlate(for: swatch))
        if ratio < worst { worst = ratio; worstColour = swatch }
        tried += 1
    }
    for step in 0...20 {
        let grey = Double(step) / 20
        let swatch = TemplateTextColor(red: grey, green: grey, blue: grey)
        let ratio = briefShowContrastRatio(swatch, briefShowEditingPlate(for: swatch))
        if ratio < worst { worst = ratio; worstColour = swatch }
        tried += 1
    }
    for step in 0...12 {
        let swatch = briefShowColor(from: TemplateTextHSB(hue: Double(step) / 12,
                                                          saturation: 1, brightness: 1))
        let ratio = briefShowContrastRatio(swatch, briefShowEditingPlate(for: swatch))
        if ratio < worst { worst = ratio; worstColour = swatch }
        tried += 1
    }
    // ⚠️ 4.5 is the floor, and the number that comes back should be about
    // 4.58 — the worst ANY colour can do against the better of white and
    // black, which happens at luminance 0.179 where the two are equally bad.
    // A first attempt used near-white and near-black plates chosen by a
    // threshold and this check caught it: the tan #B89973 read 2.5:1.
    check("all \(tried) colours tried, none below 4.5:1",
          tried == 46 && worst >= 4.5,
          String(format: "worst was %@ at %.1f:1", briefShowHexString(worstColour), worst))

    // Luminance is weighted, not averaged — a blue and a yellow that average
    // the same are nothing alike to look at, and a plate chosen on the average
    // would be wrong for one of them.
    let yellow = TemplateTextColor(red: 1, green: 1, blue: 0)
    let blue = TemplateTextColor(red: 0, green: 0, blue: 1)
    check("yellow and blue are not the same brightness",
          briefShowRelativeLuminance(yellow) > 5 * briefShowRelativeLuminance(blue),
          String(format: "%.3f against %.3f",
                 briefShowRelativeLuminance(yellow), briefShowRelativeLuminance(blue)))
    check("so they get different plates",
          briefShowEditingPlate(for: yellow) != briefShowEditingPlate(for: blue))
}

// MARK: - The eye

print("\na hidden line draws nothing, and keeps what it was")

do {
    var hidden = line
    hidden.isVisible = false
    check("a hidden line draws nothing",
          briefShowDrawTemplateText(hidden, template: template,
                                    canvas: CGRect(x: 0, y: 0, width: 3000, height: 2400)) == nil)
    check("and nothing of it reaches the print",
          compose([hidden], scale: 1).inkBounds() == nil)
    check("while the one beside it still does",
          compose([hidden, line], scale: 1).inkBounds() != nil)
    check("a hidden line on a plain photograph draws nothing either",
          renderPhotoText([hidden], width: 1200, height: 900).inkBounds() == nil)

    // ⚠️ Hiding is not "opacity 0": the line keeps whatever it was set to, so
    // turning the eye back on brings back the line the client made.
    var faded = line
    faded.opacity = 0.5
    faded.isVisible = false
    faded.isVisible = true
    check("the eye does not eat the opacity", abs(faded.opacity - 0.5) < 1e-9)

    // A record written before the eye existed is a visible line.
    let old = """
    {"id":"\(UUID().uuidString)","text":"Date:","fontFamily":"Helvetica","fontFace":"Regular",
     "sizeInches":0.25,"color":{"red":0,"green":0,"blue":0,"alpha":1},
     "alignment":"center","opacity":1,
     "box":{"x":0.1,"y":0.8,"width":0.8,"height":0.1}}
    """
    let decoded = try? JSONDecoder().decode(TemplateText.self, from: Data(old.utf8))
    check("a line written before the eye existed is visible", decoded?.isVisible == true,
          decoded == nil ? "did not decode at all" : "isVisible false")
    check("and it keeps everything else it said", decoded?.text == "Date:")

    // ⚠️ THE REASON THAT CHECK MATTERS, and it is not about the eye. The whole
    // of PhotoEditStore is ONE dictionary decoded in one go: a single line
    // that will not decode makes every edit in the app `[:]`, and the next
    // flush writes that over the client's work. So a record missing ANY field
    // has to come back, not throw.
    let bare = "{\"text\":\"Studio\"}"
    let sparse = try? JSONDecoder().decode(TemplateText.self, from: Data(bare.utf8))
    check("a record missing every other field still decodes", sparse != nil)
    check("and comes back with the defaults", sparse?.fontFamily == "Helvetica Neue"
          && sparse?.isVisible == true && sparse?.opacity == 1)
}

print(failures == 0 ? "\nall passed\n" : "\n\(failures) FAILED\n")
exit(failures == 0 ? 0 : 1)
