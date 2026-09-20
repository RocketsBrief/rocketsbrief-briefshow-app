// The Google fonts, run rather than read.
//
// This compiles the REAL BriefShow/Fonts.swift and BriefShow/Templates.swift —
// the files that ship — and drives their own functions.
//
// Four things are being held down, and each one is a way the client ends up
// with a print in a font he did not choose:
//
//   1. a style name and a weight are the same fact read two ways, and the
//      catalogue that ships was built with the table this file inverts,
//   2. the request asks for a .ttf. Asked as a modern browser, Google answers
//      with woff2, which CoreText cannot register — the download SUCCEEDS and
//      the font never appears,
//   3. what comes back is checked for being a font at all, because an error
//      page saved under a .ttf name leaves a row claiming a family is here,
//   4. the catalogue holds three fields, which is the client's own rule.
//
// With --live it also DOWNLOADS one small family and registers it, which is
// the only way to know the two requests above still answer.
//
//     google-fonts
import Foundation
import CoreText

var failures = 0

func check(_ label: String, _ passed: Bool, _ detail: String = "") {
    if passed {
        print("  ok    \(label)")
    } else {
        failures += 1
        print("  FAIL  \(label)\(detail.isEmpty ? "" : "   \(detail)")")
    }
}

let live = CommandLine.arguments.contains("--live")
// The catalogue is read by PATH here, not out of Bundle.main: a test binary
// has no app bundle, and the file being checked is the one that ships.
let cataloguePath = CommandLine.arguments.first { $0.hasSuffix("GoogleFontsCatalogue.json") }

// MARK: - A style name is a weight

print("\na style name and a weight are one fact")

check("Regular is 400 upright", briefShowGoogleFontStyleAxes("Regular") == (400, false))
check("Bold is 700 upright", briefShowGoogleFontStyleAxes("Bold") == (700, false))
check("Italic is 400 slanted", briefShowGoogleFontStyleAxes("Italic") == (400, true))
check("Bold Italic is 700 slanted", briefShowGoogleFontStyleAxes("Bold Italic") == (700, true))
check("ExtraLight Italic is 200 slanted",
      briefShowGoogleFontStyleAxes("ExtraLight Italic") == (200, true))
check("Black is 900", briefShowGoogleFontStyleAxes("Black") == (900, false))
check("something nobody has heard of falls back to Regular upright",
      briefShowGoogleFontStyleAxes("Wobbly") == (400, false))

// MARK: - The request

print("\nthe request asks for a font file this machine can register")

if let request = briefShowGoogleFontCSSRequest(family: "Playfair Display", style: "Bold Italic") {
    let url = request.url?.absoluteString ?? ""
    check("the family's spaces survive the query", url.contains("Playfair+Display"), url)
    check("the weight and the slant are both asked for",
          url.contains("ital,wght%400,700") || url.contains("ital,wght@1,700")
            || url.contains("1,700"), url)
    // THE one that decides whether any of this works.
    check("it asks as an old browser, which is what makes the answer a .ttf",
          request.value(forHTTPHeaderField: "User-Agent") == "Mozilla/4.0",
          request.value(forHTTPHeaderField: "User-Agent") ?? "none")
} else {
    check("the request is built at all", false)
}

let canned = """
@font-face {
  font-family: 'Roboto';
  font-style: normal;
  font-weight: 700;
  src: url(https://fonts.gstatic.com/s/roboto/v51/KFOMCnqEu92Fr1ME7kSn66aGLdTylUAM.ttf) format('truetype');
}
"""
check("the font's address is read out of the answer",
      briefShowFontURL(inCSS: canned)?.absoluteString
        == "https://fonts.gstatic.com/s/roboto/v51/KFOMCnqEu92Fr1ME7kSn66aGLdTylUAM.ttf",
      briefShowFontURL(inCSS: canned)?.absoluteString ?? "none")
check("an answer with no font in it reads as none",
      briefShowFontURL(inCSS: "not a stylesheet") == nil)

// MARK: - What came back is a font

print("\nwhat came back is checked for being a font")

var truetype = Data([0x00, 0x01, 0x00, 0x00])
truetype.append(Data(repeating: 0, count: 64))
check("a TrueType file passes", FontDownloader.isFontData(truetype))
check("an OpenType/CFF file passes",
      FontDownloader.isFontData(Data("OTTO____".utf8)))
check("an HTML error page does not",
      !FontDownloader.isFontData(Data("<!DOCTYPE html><html>429".utf8)))
check("and neither does an empty answer", !FontDownloader.isFontData(Data()))

// MARK: - Where it lands

print("\nthe file name survives the families that are named oddly")

check("spaces become underscores",
      FontStore.fileName(family: "Playfair Display", style: "Bold Italic")
        == "Playfair_Display-Bold_Italic.ttf",
      FontStore.fileName(family: "Playfair Display", style: "Bold Italic"))
check("a slash in a family name cannot become a directory",
      !FontStore.fileName(family: "A/B", style: "Regular").contains("/"))
check("the folder is under the path named BriefShow, not the product's name",
      FontStore.directory?.path.contains("BriefShow/Fonts") ?? false,
      FontStore.directory?.path ?? "none")

// MARK: - The catalogue that ships

print("\nthe catalogue that ships")

if let cataloguePath,
   let data = try? Data(contentsOf: URL(fileURLWithPath: cataloguePath)) {
    // Decoded with the app's OWN type, so a field added to one and not the
    // other is a failure here rather than an empty list at runtime.
    let families = (try? JSONDecoder().decode([GoogleFontFamily].self, from: data)) ?? []
    check("it decodes with the app's own type", !families.isEmpty, "\(families.count)")
    check("it holds the whole catalogue", families.count > 1900, "\(families.count)")

    // The client's rule: three fields, and no more.
    let raw = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
    let keys = Set(raw.flatMap { $0.keys })
    check("and EXACTLY three fields — name, category, styles",
          keys == ["name", "category", "styles"], "\(keys.sorted())")

    check("every family has a name and at least one style",
          families.allSatisfy { !$0.name.isEmpty && !$0.styles.isEmpty })
    check("Regular comes first wherever a family has it",
          families.allSatisfy { !$0.styles.contains("Regular") || $0.styles.first == "Regular" })

    // Every style name in the catalogue must be a name this file can turn
    // back into a weight — the two tables are written in two languages and
    // this is the only place they meet.
    var unmapped = Set<String>()
    for family in families {
        for style in family.styles {
            let axes = briefShowGoogleFontStyleAxes(style)
            let base = style.replacingOccurrences(of: "Italic", with: "")
                .trimmingCharacters(in: .whitespaces)
            if axes.weight == 400 && !base.isEmpty && base != "Regular" {
                unmapped.insert(style)
            }
        }
    }
    check("every style in it maps to a weight", unmapped.isEmpty, "\(unmapped.sorted().prefix(8))")

    check("the catalogue is small enough to be free", data.count < 300_000,
          "\(data.count) bytes")
} else {
    check("the shipped catalogue was handed to the test", false,
          "pass the path to GoogleFontsCatalogue.json")
}

// MARK: - The live half

if live {
    print("\nfetching one family for real")

    // Small, and with two styles, so the test measures a family rather than a
    // file: three requests in all.
    let family = GoogleFontFamily(name: "ABeeZee", category: "Sans Serif",
                                  styles: ["Regular", "Italic"])
    for style in family.styles {
        if let url = FontStore.fileURL(family: family.name, style: style) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    let waiting = DispatchSemaphore(value: 0)
    var outcome: Result<FontDownloadResult, Error>?
    FontDownloader.download(family) { result in
        outcome = result
        waiting.signal()
    }
    // The callback lands on the main queue, so the main queue cannot be the
    // one that waits.
    while waiting.wait(timeout: .now() + 0.05) == .timedOut {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }

    switch outcome {
    case .success(let done):
        check("both styles arrived", done.styles.count == 2, "\(done.styles)")
        check("and they are real bytes", done.bytes > 10_000, "\(done.bytes) bytes")
        check("CoreText now knows the family",
              briefShowFontFaces(in: done.registeredFamily).count >= 1,
              "\(briefShowFontFaces(in: done.registeredFamily))")
        check("a licence was written beside it", done.licence?.isEmpty == false)
        if let url = FontStore.licenceURL(family: family.name) {
            check("and it is on disk", FileManager.default.fileExists(atPath: url.path))
        }
        // The point of the whole step: a text set in it DRAWS in it.
        let font = briefShowTemplateTextFont(family: done.registeredFamily,
                                             face: "Regular", sizePixels: 60)
        check("a text set in it draws in it",
              (CTFontCopyFamilyName(font) as String) == done.registeredFamily,
              CTFontCopyFamilyName(font) as String)
    case .failure(let error):
        check("the download went through", false, error.localizedDescription)
    case nil:
        check("the download answered at all", false, "timed out")
    }
} else {
    print("\n(the live download is skipped — run with --live to fetch one family)")
}

print(failures == 0 ? "\nall passed\n" : "\n\(failures) FAILED\n")
exit(failures == 0 ? 0 : 1)
