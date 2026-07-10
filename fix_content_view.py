import os

file_path = "ContentView.swift"

with open(file_path, "r", encoding="utf-8") as f:
    lines = f.readlines()

for i, line in enumerate(lines):
    if "private func importPhotoURLs" in line:
        clean_lines = lines[:i]
        break
else:
    clean_lines = lines

complete_end = """    private func importPhotoURLs(_ urls: [URL]) {
        let sortedURLs = urls
            .filter { url in
                UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
            }
            .sorted {
                $0.lastPathComponent < $1.lastPathComponent
            }
        
        guard !sortedURLs.isEmpty else { return }
        
        isPreparingPhotos = true
        preparedPhotoCount = 0
        
        selectedPhotoURLs.append(contentsOf: sortedURLs)
        
        DispatchQueue.global(qos: .userInitiated).async {
            var loadedImages: [NSImage] = []
            for url in sortedURLs {
                if let image = NSImage(contentsOf: url) {
                    loadedImages.append(image)
                }
                DispatchQueue.main.async {
                    preparedPhotoCount += 1
                }
            }
            
            DispatchQueue.main.async {
                previewImages.append(contentsOf: loadedImages)
                isPreparingPhotos = false
            }
        }
    }

    private func importMusicURLs(_ urls: [URL]) {
        let sortedMusic = urls.filter { url in
            UTType(filenameExtension: url.pathExtension)?.conforms(to: .audio) == true
        }
        if !sortedMusic.isEmpty {
            selectedMusicURLs = sortedMusic
            currentMusicIndex = 0
            currentMusicElapsedSeconds = 0
            prepareAudioPlayer(for: sortedMusic.first)
        }
    }

    private func prepareAudioPlayer(for url: URL?) {
        guard let url = url else { return }
        try? audioPlayer = AVAudioPlayer(contentsOf: url)
        audioPlayer?.prepareToPlay()
    }
}
"""

final_content = "".join(clean_lines) + complete_end

with open(file_path, "w", encoding="utf-8") as f:
    f.write(final_content)

print("USPEH: ContentView.swift je kompletiran i struktura je zatvorena!")
