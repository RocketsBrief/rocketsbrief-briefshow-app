//  Fonts.swift
//  KORAK 198, step 6 — the Google fonts, seen from the first launch and used
//  once they are on this Mac.
//
//  The client's answer to question 5, 20.09: *the whole catalogue is visible,
//  with its styles; a font is USED once it has been downloaded, and once
//  downloaded it works on that computer forever.*
//
//  What that means in practice, and the line worth saying out loud because it
//  looks like an omission and is not: the NAME of a font cannot be drawn in
//  that font before the font is on the machine — they are the same file. So a
//  row carries its name, its category and its styles until it is downloaded,
//  and the real thing comes one click later. The alternative is downloading
//  all 1946 families, which is about 1.5 GB, and that does not go in an app.
//
//  ⚠️ THREE LOCKED FACTS:
//
//  1. THE CATALOGUE IS IN THE APP AND HOLDS THREE FIELDS — name, category,
//     styles. His words: *„neka bude ono sto nam treba za fontove, ime,
//     kategorija i stilovi"*. Anything else added to it changes the size of
//     the release, and keeping the release the same size is the whole reason
//     the catalogue is in there. See Tools/make-google-font-catalogue.py.
//  2. THE FONT FILES ARE NOT IN THE APP. They are downloaded on demand into
//     Application Support — the client's disk, not the delivery — and they are
//     registered at every launch, so an export with no network draws exactly
//     what the screen drew.
//  3. THE LICENCE TRAVELS WITH THE FONT. These prints go to a lab, so every
//     downloaded family gets its licence written beside it.

import Foundation
import Combine
import CoreText

// MARK: - The catalogue that ships

/// One family, as the app ships it: three fields and nothing else.
struct GoogleFontFamily: Codable, Equatable, Identifiable {
    var name: String
    var category: String
    var styles: [String]

    var id: String { name }
}

enum GoogleFontCatalogue {

    /// Read once, off the bundle. No network, no first-launch fetch — the list
    /// is there the moment the app opens, which is what the client chose.
    static let families: [GoogleFontFamily] = {
        guard let url = Bundle.main.url(forResource: "GoogleFontsCatalogue", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([GoogleFontFamily].self, from: data) else {
            // An app whose catalogue is missing still has to run: the text
            // tool then offers what the machine already has, which is what it
            // offered before this step existed.
            return []
        }
        return decoded
    }()

    /// The families whose name contains `query`, ignoring case. Empty query is
    /// the whole catalogue.
    static func families(matching query: String) -> [GoogleFontFamily] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return families }
        return families.filter { $0.name.range(of: trimmed, options: .caseInsensitive) != nil }
    }
}

// MARK: - Which weight a style name is

/// "Bold Italic" → weight 700, slanted. The inverse of the table the
/// catalogue was built with, and the one place the two have to agree.
func briefShowGoogleFontStyleAxes(_ style: String) -> (weight: Int, italic: Bool) {
    let italic = style.lowercased().contains("italic")
    var name = style
    if italic {
        name = name.replacingOccurrences(of: "Italic", with: "")
            .trimmingCharacters(in: .whitespaces)
    }
    if name.isEmpty { name = "Regular" }
    let weights: [String: Int] = [
        "Thin": 100, "ExtraLight": 200, "Light": 300, "Regular": 400,
        "Medium": 500, "SemiBold": 600, "Bold": 700, "ExtraBold": 800, "Black": 900
    ]
    return (weights[name] ?? 400, italic)
}

/// The css2 request for one face of one family.
///
/// ⚠️ The user agent is what decides the FORMAT that comes back, and it is
/// MEASURED, 20.09, not assumed:
///
///     Safari 17          -> format('woff2')   CoreText cannot register it
///     Mozilla/4.0        -> format('truetype')
///     CFNetwork's own    -> format('truetype')
///
/// So the header is not fixing a format that would otherwise be wrong today —
/// URLSession's own agent gets a .ttf as things stand. It PINS the answer. The
/// day this app sends anything browser-shaped, a download that "succeeded"
/// would leave a font that never appears and a row claiming a family is here.
func briefShowGoogleFontCSSRequest(family: String, style: String) -> URLRequest? {
    let axes = briefShowGoogleFontStyleAxes(style)
    let name = family.replacingOccurrences(of: " ", with: "+")
    let spec = "\(name):ital,wght@\(axes.italic ? 1 : 0),\(axes.weight)"
    var components = URLComponents(string: "https://fonts.googleapis.com/css2")
    components?.queryItems = [URLQueryItem(name: "family", value: spec)]
    guard let url = components?.url else { return nil }
    var request = URLRequest(url: url)
    request.setValue("Mozilla/4.0", forHTTPHeaderField: "User-Agent")
    request.timeoutInterval = 30
    return request
}

/// The font file's address out of a css2 answer.
func briefShowFontURL(inCSS css: String) -> URL? {
    guard let open = css.range(of: "src: url("),
          let close = css.range(of: ")", range: open.upperBound..<css.endIndex) else {
        return nil
    }
    return URL(string: String(css[open.upperBound..<close.lowerBound]))
}

// MARK: - Where downloaded fonts live

enum FontStore {

    /// ⚠️ THE NAME ON DISK IS "BriefShow" AND IT STAYS THAT WAY — the same
    /// rule, and the same reason, as FlattenedImageStore and LayerPixelStore:
    /// it is a path to the client's data, not the product's name. A rename
    /// here orphans every font he has downloaded.
    static var directory: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask).first else {
            return nil
        }
        let directory = base.appendingPathComponent("BriefShow/Fonts", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// A file name that survives a family called "Press Start 2P".
    static func fileName(family: String, style: String) -> String {
        let safe = "\(family)-\(style)"
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        return safe + ".ttf"
    }

    static func fileURL(family: String, style: String) -> URL? {
        directory?.appendingPathComponent(fileName(family: family, style: style))
    }

    static func isDownloaded(family: String, style: String) -> Bool {
        guard let url = fileURL(family: family, style: style) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    static func licenceURL(family: String) -> URL? {
        directory?.appendingPathComponent(
            family.replacingOccurrences(of: " ", with: "_") + "-LICENSE.txt")
    }

    /// Every font already on this machine, handed to CoreText.
    ///
    /// ⚠️ This is what makes "once downloaded it works forever, offline"
    /// true — including in an export, which draws with no window and no
    /// network. Registering only when a font is picked would mean a print
    /// made after a restart quietly came out in the system face.
    @discardableResult
    static func registerDownloadedFonts() -> Int {
        guard let directory,
              let files = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil) else {
            return 0
        }
        var registered = 0
        for file in files where file.pathExtension.lowercased() == "ttf" {
            // `.process` — this app, this run. A font is the client's, not the
            // system's; nothing here installs anything for other apps.
            if CTFontManagerRegisterFontsForURL(file as CFURL, .process, nil) {
                registered += 1
            }
            // A false here is usually "already registered", which is not a
            // failure worth telling anybody about.
        }
        return registered
    }

    /// The family name CORETEXT knows a file by, which is what a record has to
    /// carry — not the name the catalogue lists it under.
    ///
    /// They are the same for nearly every family, and when they are not, the
    /// text would be set in a family CoreText has never heard of and would
    /// silently draw in the system face.
    static func registeredFamilyName(of file: URL) -> String? {
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(file as CFURL)
                as? [CTFontDescriptor], let first = descriptors.first else {
            return nil
        }
        return CTFontDescriptorCopyAttribute(first, kCTFontFamilyNameAttribute) as? String
    }

    static func registeredStyleName(of file: URL) -> String? {
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(file as CFURL)
                as? [CTFontDescriptor], let first = descriptors.first else {
            return nil
        }
        return CTFontDescriptorCopyAttribute(first, kCTFontStyleNameAttribute) as? String
    }
}

// MARK: - Downloading

enum FontDownloadError: LocalizedError {
    case noPlaceToPutIt
    case noAnswer(String)
    case notAFont(String)

    var errorDescription: String? {
        switch self {
        case .noPlaceToPutIt: return "Could not find a place to keep the font."
        case .noAnswer(let style): return "Google did not answer for \(style)."
        case .notAFont(let style): return "What came back for \(style) was not a font file."
        }
    }
}

/// What one family costs and what came of downloading it.
struct FontDownloadResult: Equatable {
    var family: String
    /// CoreText's own name for it, which is what a record stores.
    var registeredFamily: String
    var styles: [String]
    var bytes: Int
    var licence: String?
}

enum FontDownloader {

    /// Fetches every style of one family, registers them, and writes the
    /// licence beside them.
    ///
    /// ⚠️ ALL of a family's styles, not the one that happens to be selected.
    /// A client who has downloaded "Playfair Display" and then picks Bold from
    /// the style list must not be told to download it again — the row said the
    /// family was here.
    static func download(_ family: GoogleFontFamily,
                         completion: @escaping (Result<FontDownloadResult, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let result = try downloadSynchronously(family)
                DispatchQueue.main.async { completion(.success(result)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    private static func downloadSynchronously(_ family: GoogleFontFamily) throws -> FontDownloadResult {
        guard FontStore.directory != nil else { throw FontDownloadError.noPlaceToPutIt }

        var written: [String] = []
        var bytes = 0
        var registeredFamily = family.name

        for style in family.styles {
            guard let destination = FontStore.fileURL(family: family.name, style: style) else {
                throw FontDownloadError.noPlaceToPutIt
            }
            if FileManager.default.fileExists(atPath: destination.path) {
                written.append(style)
                continue
            }
            guard let request = briefShowGoogleFontCSSRequest(family: family.name, style: style),
                  let css = try? fetchString(request) else {
                throw FontDownloadError.noAnswer(style)
            }
            guard let fontURL = briefShowFontURL(inCSS: css) else {
                throw FontDownloadError.notAFont(style)
            }
            let data = try fetchData(URLRequest(url: fontURL))
            // A font file starts with one of four tags. Checked because an
            // error page saved under a .ttf name registers as nothing and
            // leaves a row claiming a family is here when it is not.
            guard data.count > 4, isFontData(data) else {
                throw FontDownloadError.notAFont(style)
            }
            try data.write(to: destination, options: .atomic)
            bytes += data.count
            written.append(style)

            CTFontManagerRegisterFontsForURL(destination as CFURL, .process, nil)
            if let name = FontStore.registeredFamilyName(of: destination) {
                registeredFamily = name
            }
        }

        let licence = try? fetchLicence(for: family.name)
        if let licence, let url = FontStore.licenceURL(family: family.name) {
            try? licence.write(to: url, atomically: true, encoding: .utf8)
        }

        return FontDownloadResult(family: family.name,
                                  registeredFamily: registeredFamily,
                                  styles: written,
                                  bytes: bytes,
                                  licence: licence)
    }

    /// ttf/otf/ttc, by the four bytes every one of them starts with.
    static func isFontData(_ data: Data) -> Bool {
        let tag = data.prefix(4)
        let known: [[UInt8]] = [
            [0x00, 0x01, 0x00, 0x00],           // TrueType
            Array("OTTO".utf8),                 // CFF
            Array("true".utf8),
            Array("ttcf".utf8)
        ]
        return known.contains(Array(tag))
    }

    /// The licence, fetched at download time rather than shipped in the
    /// catalogue — the catalogue holds three fields and that is the client's
    /// own rule (see the header of this file).
    private static func fetchLicence(for family: String) throws -> String {
        let escaped = family.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? family
        guard let metadata = URL(string: "https://fonts.google.com/metadata/fonts/" + escaped) else {
            throw FontDownloadError.noAnswer("licence")
        }
        var request = URLRequest(url: metadata)
        request.timeoutInterval = 20
        var text = try fetchString(request)
        // Google guards the endpoint against being read as script.
        if text.hasPrefix(")]}'") {
            text = String(text.drop(while: { $0 != "\n" }))
        }
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let licence = object["license"] as? String else {
            throw FontDownloadError.noAnswer("licence")
        }

        let slug = family.lowercased().replacingOccurrences(of: " ", with: "")
        for file in ["OFL.txt", "LICENSE.txt", "UFL.txt"] {
            let url = URL(string: "https://raw.githubusercontent.com/google/fonts/main/"
                          + "\(licence)/\(slug)/\(file)")!
            if let body = try? fetchString(URLRequest(url: url)), body.count > 200 {
                return body
            }
        }
        // The id alone is still worth keeping: it says WHICH licence this font
        // is under, which is the question a lab or a client would ask.
        return "This font is distributed under the \(licence.uppercased()) licence.\n"
             + "Family: \(family)\n"
             + "See https://fonts.google.com/specimen/\(slug) for the full text.\n"
    }

    private static func fetchData(_ request: URLRequest) throws -> Data {
        var result: Result<Data, Error>?
        let waiting = DispatchSemaphore(value: 0)
        var request = request
        request.timeoutInterval = max(request.timeoutInterval, 30)
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                result = .failure(error)
            } else if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                result = .failure(FontDownloadError.noAnswer("HTTP \(http.statusCode)"))
            } else if let data {
                result = .success(data)
            } else {
                result = .failure(FontDownloadError.noAnswer("nothing"))
            }
            waiting.signal()
        }.resume()
        // ⚠️ This whole type runs on a background queue (see `download`), so
        // the wait never blocks the editor. It is a semaphore rather than
        // async/await because the caller is a panel button, not a task.
        _ = waiting.wait(timeout: .now() + 60)
        switch result {
        case .success(let data): return data
        case .failure(let error): throw error
        case nil: throw FontDownloadError.noAnswer("timed out")
        }
    }

    private static func fetchString(_ request: URLRequest) throws -> String {
        let data = try fetchData(request)
        guard let text = String(data: data, encoding: .utf8) else {
            throw FontDownloadError.noAnswer("unreadable")
        }
        return text
    }
}

// MARK: - What the panel watches

/// Which families are on this Mac, and which one is being fetched right now.
///
/// One shared instance: the picker reads it, the download writes it, and the
/// renderer asks CoreText — which has been told about every file this object
/// knows of.
final class FontLibrary: ObservableObject {

    static let shared = FontLibrary()

    /// Catalogue names of the families that are downloaded.
    @Published private(set) var downloaded: Set<String> = []
    /// The family being fetched, so its row can say so and cannot be asked twice.
    @Published private(set) var downloading: String?
    @Published var lastError: String?

    private init() {
        FontStore.registerDownloadedFonts()
        refresh()
    }

    func refresh() {
        guard let directory = FontStore.directory,
              let files = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil) else {
            downloaded = []
            return
        }
        // A file is named "<Family>-<Style>.ttf" with spaces turned to
        // underscores, so the family is read back off the name rather than
        // kept in a second list that could disagree with the disk.
        var names = Set<String>()
        for file in files where file.pathExtension.lowercased() == "ttf" {
            let base = file.deletingPathExtension().lastPathComponent
            guard let dash = base.lastIndex(of: "-") else { continue }
            names.insert(String(base[base.startIndex..<dash]).replacingOccurrences(of: "_", with: " "))
        }
        downloaded = names
    }

    func isDownloaded(_ family: GoogleFontFamily) -> Bool {
        downloaded.contains(family.name)
    }

    /// The name CORETEXT knows this family by, which is what goes into the
    /// record — asked of the font FILE when the two disagree.
    ///
    /// ⚠️ They disagree rarely and silently. A record carrying the catalogue's
    /// name for a family CoreText files under another one draws in the system
    /// face, on screen and on the print, with nothing anywhere saying why.
    func coreTextFamilyName(for family: GoogleFontFamily) -> String? {
        guard isDownloaded(family) else { return nil }
        if !briefShowFontFaces(in: family.name).isEmpty,
           briefShowInstalledFontFamilies().contains(family.name) {
            return family.name
        }
        for style in family.styles {
            if let file = FontStore.fileURL(family: family.name, style: style),
               FileManager.default.fileExists(atPath: file.path),
               let name = FontStore.registeredFamilyName(of: file) {
                return name
            }
        }
        return nil
    }

    func download(_ family: GoogleFontFamily,
                  then handOver: ((FontDownloadResult) -> Void)? = nil) {
        guard downloading == nil, !isDownloaded(family) else { return }
        downloading = family.name
        lastError = nil
        FontDownloader.download(family) { [weak self] result in
            guard let self else { return }
            self.downloading = nil
            switch result {
            case .success(let done):
                self.refresh()
                // The machine has a family it did not have a moment ago, and
                // the list of installed families is cached — see
                // briefShowInstalledFontFamilies().
                briefShowRefreshInstalledFontFamilies()
                handOver?(done)
            case .failure(let error):
                // Said out loud rather than swallowed: a Download button that
                // does nothing and explains nothing is the fault this app has
                // written up twice already.
                self.lastError = error.localizedDescription
            }
        }
    }
}
