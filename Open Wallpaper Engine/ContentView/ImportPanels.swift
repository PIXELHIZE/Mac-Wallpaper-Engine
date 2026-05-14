//
//  ImportPanels.swift
//  Open Wallpaper Engine
//
//  Created by Haren on 2023/8/4.
//

import Cocoa
import UniformTypeIdentifiers

struct WPImportError: LocalizedError {
    var errorDescription: String?
    var failureReason: String?
    var helpAnchor: String?
    var recoverySuggestion: String?
    
    static let permissionDenied         = WPImportError(errorDescription: "Permission Denied",
                                                failureReason: "This app doesn't have the permission to access to the folder(s) you selected",
                                                helpAnchor: "File Permission",
                                                recoverySuggestion: "Try enable it in 'System Settings' - 'Privacy & Security'")
    
    static let doesNotContainWallpaper  = WPImportError(errorDescription: "No Wallpaper(s) Inside",
                                                       failureReason: "Maybe you selected the wrong folder which doesn't contain any wallpapers",
                                                       helpAnchor: "Contents in Folder(s)",
                                                       recoverySuggestion: "Check the folder(s) you selected and try again")
    
    static let unkown                   = WPImportError(errorDescription: "Unkown Error",
                                                        failureReason: "",
                                                        helpAnchor: "",
                                                        recoverySuggestion: "")
}

extension AppDelegate {
    @objc func openImportFromFolderPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.folder, .zip]
        panel.beginSheetModal(for: self.mainWindowController.window) { [weak self] response in
            if response != .OK { return }
            guard !panel.urls.isEmpty else { return }

            let fm = FileManager.default
            let docsDir = fm.wallpapersDirectory

            var wallpaperURLs: [URL] = []
            var zipURLs: [URL] = []

            for url in panel.urls {
                if url.pathExtension.lowercased() == "zip" {
                    zipURLs.append(url)
                } else if fm.fileExists(atPath: url.appending(path: "project.json").path) {
                    wallpaperURLs.append(url)
                } else {
                    wallpaperURLs.append(contentsOf: ZipImporter.findWallpaperFolders(in: url))
                }
            }

            guard !wallpaperURLs.isEmpty || !zipURLs.isEmpty else {
                DispatchQueue.main.async {
                    self?.contentViewModel.alertImportModal(which: .doesNotContainWallpaper)
                }
                return
            }

            DispatchQueue.main.async {
                for url in wallpaperURLs {
                    let dest = docsDir.appending(path: url.lastPathComponent)
                    if !fm.fileExists(atPath: dest.path) {
                        try? fm.copyItem(at: url, to: dest)
                    }
                }
                for url in zipURLs {
                    ZipImporter.importZip(at: url)
                }
                self?.contentViewModel.refresh()
            }
        }
    }
    
    @objc func openImportFromFoldersPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.beginSheetModal(for: self.mainWindowController.window) { response in
            if response != .OK { return }
            print(String(describing: panel.urls))
            
            DispatchQueue.main.async {
                self.contentViewModel.wallpaperUrls.append(contentsOf: panel.urls)
            }
        }
    }
}
