from pathlib import Path

path = Path("BriefShow/ContentView.swift")
src = path.read_text()

old = """    for url in musicURLs {
        let convertedURL: URL

        do {
            convertedURL = try convertMusicURLToAAC(url)
        } catch {"""
new = """    for url in musicURLs {
        let didStartAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        print(
            "BriefShow mux: security-scoped access started =",
            didStartAccess,
            "for",
            url.lastPathComponent
        )

        let convertedURL: URL

        do {
            convertedURL = try convertMusicURLToAAC(url)
        } catch {"""

count = src.count(old)
if count != 1:
    print(f"FAIL: found {count} occurrences, expected 1. No changes written.")
else:
    path.write_text(src.replace(old, new, 1))
    print("=== PATCH APPLIED SUCCESSFULLY ===")
