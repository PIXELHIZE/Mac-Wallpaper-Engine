import Foundation

enum ZipImporter {
    /// Extracts a zip file and copies any wallpaper folders (containing project.json) to the wallpapers directory.
    /// Returns the number of wallpapers successfully imported.
    @discardableResult
    static func importZip(at zipURL: URL) -> Int {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appending(path: UUID().uuidString)

        defer { try? fm.removeItem(at: tempDir) }

        // Extract zip using macOS built-in ditto
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-xk", zipURL.path, tempDir.path]
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            print("ZipImporter: ditto failed: \(error)")
            return 0
        }
        guard process.terminationStatus == 0 else {
            print("ZipImporter: ditto exited with status \(process.terminationStatus)")
            return 0
        }

        // Find wallpaper folders inside extracted content. Some third-party zip
        // archives include a wrapper folder plus unrelated files next to it.
        let wallpaperURLs = findWallpaperFolders(in: tempDir)
        let dest = fm.wallpapersDirectory
        var imported = 0

        for url in wallpaperURLs {
            let target = dest.appending(path: url.lastPathComponent)
            if !fm.fileExists(atPath: target.path) {
                do {
                    try fm.copyItem(at: url, to: target)
                    imported += 1
                } catch {
                    print("ZipImporter: copy failed for \(url.lastPathComponent): \(error)")
                }
            }
        }

        return imported
    }

    /// Recursively searches for directories containing project.json.
    static func findWallpaperFolders(in directory: URL) -> [URL] {
        let fm = FileManager.default
        var results: [URL] = []

        if fm.fileExists(atPath: directory.appending(path: "project.json").path) {
            return [directory]
        }

        guard let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        for case let child as URL in enumerator {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: child.path, isDirectory: &isDir), isDir.boolValue else { continue }

            if fm.fileExists(atPath: child.appending(path: "project.json").path) {
                results.append(child)
                enumerator.skipDescendants()
            }
        }

        return results
    }
}
