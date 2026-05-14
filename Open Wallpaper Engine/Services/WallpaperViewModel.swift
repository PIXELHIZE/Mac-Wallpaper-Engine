//
//  WallpaperViewModel.swift
//  Open Wallpaper Engine
//
//  Created by Haren on 2023/8/14.
//

import Cocoa
import ApplicationServices
import SwiftUI

/// Provide Wallpaper Database for WallpaperView and ContentView etc.
class WallpaperViewModel: ObservableObject {
    @Published var nextCurrentWallpaper: WEWallpaper =
    WEWallpaper(using: .invalid, where: Bundle.main.url(forResource: "WallpaperNotFound", withExtension: "mp4")!) {
        willSet {
            if ["web", "application"].contains(newValue.project.type) {
                if let trustedWallpapers = UserDefaults.standard.array(forKey: "TrustedWallpapers") as? [String],
                   trustedWallpapers.contains(newValue.wallpaperDirectory.path(percentEncoded: false)) {
                    self.setWallpaper(newValue, for: selectedScreenId)
                } else {
                    AppDelegate.shared.contentViewModel.warningUnsafeWallpaperModal(which: newValue)
                }
            } else {
                self.setWallpaper(newValue, for: selectedScreenId)
            }
        }
    }

    /// Per-screen wallpaper assignments, keyed by CGDirectDisplayID as String.
    @Published var wallpapers: [String: WEWallpaper] = [:] {
        didSet { saveWallpapers() }
    }

    /// Screens where wallpaper display is enabled.
    @Published var enabledScreens: Set<String> = [] {
        didSet {
            UserDefaults.standard.set(Array(enabledScreens), forKey: "EnabledScreens")
        }
    }

    /// The screen currently selected in the UI for configuration.
    @Published var selectedScreenId: String = ""

    static let defaultWallpaper = WEWallpaper(using: .invalid, where: Bundle.main.url(forResource: "WallpaperNotFound", withExtension: "mp4")!)

    // MARK: - Recent wallpapers

    private static let maxRecents = 10
    private static let recentsKey = "RecentWallpapers"

    @Published var recentWallpapers: [WEWallpaper] = []

    private func loadRecents() {
        guard let data = UserDefaults.standard.data(forKey: Self.recentsKey),
              let saved = try? JSONDecoder().decode([WEWallpaper].self, from: data) else { return }
        recentWallpapers = saved.filter { $0.project != .invalid }
    }

    private func saveRecents() {
        if let data = try? JSONEncoder().encode(recentWallpapers) {
            UserDefaults.standard.set(data, forKey: Self.recentsKey)
        }
    }

    func addToRecents(_ wallpaper: WEWallpaper) {
        guard wallpaper.project != .invalid else { return }
        recentWallpapers.removeAll { $0.wallpaperDirectory == wallpaper.wallpaperDirectory }
        recentWallpapers.insert(wallpaper, at: 0)
        if recentWallpapers.count > Self.maxRecents {
            recentWallpapers = Array(recentWallpapers.prefix(Self.maxRecents))
        }
        saveRecents()
    }

    // MARK: - Wallpaper access

    /// Convenience: wallpaper for the currently selected screen in the UI.
    var currentWallpaper: WEWallpaper {
        get {
            wallpapers[selectedScreenId] ?? Self.defaultWallpaper
        }
        set {
            setWallpaper(newValue, for: selectedScreenId)
        }
    }

    /// Get wallpaper for a specific screen.
    func wallpaper(for screenId: String) -> WEWallpaper {
        wallpapers[screenId] ?? Self.defaultWallpaper
    }

    /// Set wallpaper for a specific screen.
    func setWallpaper(_ wallpaper: WEWallpaper, for screenId: String) {
        wallpapers[screenId] = wallpaper
        addToRecents(wallpaper)
    }

    func isScreenEnabled(_ screenId: String) -> Bool {
        enabledScreens.contains(screenId)
    }

    func toggleScreen(_ screenId: String) {
        if enabledScreens.contains(screenId) {
            enabledScreens.remove(screenId)
        } else {
            enabledScreens.insert(screenId)
        }
        AppDelegate.shared.rebuildWallpaperWindows()
    }

    /// Remove a wallpaper from all screens (e.g., when unsubscribing).
    func removeWallpaperFromAllScreens(directory: URL) {
        for (key, wp) in wallpapers {
            if wp.wallpaperDirectory == directory {
                wallpapers[key] = Self.defaultWallpaper
            }
        }
    }

    var lastPlayRate: Float = 1.0
    @Published public var renderingSuspended: Bool = false {
        didSet {
            guard oldValue != renderingSuspended else { return }
            WEAudioSpectrum.shared.setSuspended(renderingSuspended)
        }
    }

    var effectivePlayRate: Float {
        renderingSuspended ? 0 : playRate
    }

    @Published public var playRate: Float = 1.0 {
        willSet {
            if newValue == 0.0 {
                for (index, item) in AppDelegate.shared.statusItem.menu!.items.enumerated() {
                    if item.title == "Pause" {
                        AppDelegate.shared.statusItem.menu!.items[index] =
                            .init(title: "Resume", systemImage: "play.fill", action: #selector(AppDelegate.shared.resume), keyEquivalent: "")
                    }
                }
            } else {
                for (index, item) in AppDelegate.shared.statusItem.menu!.items.enumerated() {
                    if item.title == "Resume" {
                        AppDelegate.shared.statusItem.menu!.items[index] =
                            .init(title: "Pause", systemImage: "pause.fill", action: #selector(AppDelegate.shared.pause), keyEquivalent: "")
                    }
                }
            }
        }
        didSet {
            self.lastPlayRate = oldValue
        }
    }

    var lastPlayVolume: Float = 1.0
    @Published public var playVolume: Float = 1.0 {
        willSet {
            if newValue == 0.0 {
                for (index, item) in AppDelegate.shared.statusItem.menu!.items.enumerated() {
                    if item.title == "Mute" {
                        AppDelegate.shared.statusItem.menu!.items[index] =
                            .init(title: String(localized: "Unmute"), systemImage: "speaker.fill", action: #selector(AppDelegate.shared.unmute), keyEquivalent: "")
                    }
                }
            } else {
                for (index, item) in AppDelegate.shared.statusItem.menu!.items.enumerated() {
                    if item.title == "Unmute" {
                        AppDelegate.shared.statusItem.menu!.items[index] =
                            .init(title: String(localized: "Mute"), systemImage: "speaker.slash.fill", action: #selector(AppDelegate.shared.mute), keyEquivalent: "")
                    }
                }
            }
        }
        didSet {
            self.lastPlayVolume = oldValue
        }
    }

    init() {
        // Load per-screen wallpapers
        if let data = UserDefaults.standard.data(forKey: "ScreenWallpapers"),
           let saved = try? JSONDecoder().decode([String: WEWallpaper].self, from: data) {
            // Filter out any compound keys (screenId_spaceId) from previous per-space experiment
            self.wallpapers = saved.filter { !$0.key.contains("_") }
        }
        // Migrate legacy single wallpaper
        else if let json = UserDefaults.standard.data(forKey: "CurrentWallpaper"),
                let wallpaper = try? JSONDecoder().decode(WEWallpaper.self, from: json) {
            let mainId = Self.mainScreenId()
            self.wallpapers = [mainId: wallpaper]
        }

        // Load enabled screens (default: all connected screens enabled)
        if let saved = UserDefaults.standard.array(forKey: "EnabledScreens") as? [String] {
            self.enabledScreens = Set(saved)
        } else {
            self.enabledScreens = Set(NSScreen.screens.map { Self.screenId(for: $0) })
        }

        // Default selected screen to main
        self.selectedScreenId = Self.mainScreenId()

        // Load recent wallpapers
        loadRecents()
    }

    // MARK: - Screen ID helpers

    static func screenId(for screen: NSScreen) -> String {
        let displayId = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
        return String(displayId)
    }

    static func mainScreenId() -> String {
        guard let main = NSScreen.main else { return "0" }
        return screenId(for: main)
    }

    static func screenName(for screen: NSScreen) -> String {
        screen.localizedName
    }

    // MARK: - Persistence

    private func saveWallpapers() {
        if let data = try? JSONEncoder().encode(wallpapers) {
            UserDefaults.standard.set(data, forKey: "ScreenWallpapers")
        }
        // Keep legacy key updated for backward compat
        if let data = try? JSONEncoder().encode(currentWallpaper) {
            UserDefaults.standard.set(data, forKey: "CurrentWallpaper")
        }
    }
}

final class WallpaperVisibilityMonitor {
    private static let debugResumeDelay: TimeInterval = 3

    private weak var wallpaperViewModel: WallpaperViewModel?
    private var timer: Timer?
    private var delayedResumeTimer: Timer?
    private var observers: [NSObjectProtocol] = []

    init(wallpaperViewModel: WallpaperViewModel) {
        self.wallpaperViewModel = wallpaperViewModel
    }

    deinit {
        stop()
    }

    func start() {
        stop()
        let timer = Timer(timeInterval: 0.75, repeats: true) { [weak self] _ in
            self?.updateVisibilityState()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        let center = NSWorkspace.shared.notificationCenter
        observers = [
            center.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in self?.updateVisibilityState() },
            center.addObserver(
                forName: NSWorkspace.activeSpaceDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in self?.updateVisibilityState() },
            NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in self?.updateVisibilityState() }
        ]

        updateVisibilityState()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        delayedResumeTimer?.invalidate()
        delayedResumeTimer = nil
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observers.removeAll()
    }

    private func updateVisibilityState() {
        guard let wallpaperViewModel else { return }
        let shouldSuspend = shouldSuspendRendering(for: wallpaperViewModel)

        if shouldSuspend {
            delayedResumeTimer?.invalidate()
            delayedResumeTimer = nil
            if !wallpaperViewModel.renderingSuspended {
                wallpaperViewModel.renderingSuspended = true
                SceneWallpaperViewModel.log("Wallpaper rendering suspended by desktop visibility monitor")
            }
            return
        }

        guard wallpaperViewModel.renderingSuspended, delayedResumeTimer == nil else { return }
        let timer = Timer(timeInterval: Self.debugResumeDelay, repeats: false) { [weak self] _ in
            guard let self, let wallpaperViewModel = self.wallpaperViewModel else { return }
            self.delayedResumeTimer = nil
            guard !self.shouldSuspendRendering(for: wallpaperViewModel),
                  wallpaperViewModel.renderingSuspended else {
                return
            }
            wallpaperViewModel.renderingSuspended = false
            SceneWallpaperViewModel.log("Wallpaper rendering resumed after \(Self.debugResumeDelay)s debug delay")
        }
        RunLoop.main.add(timer, forMode: .common)
        delayedResumeTimer = timer
        SceneWallpaperViewModel.log("Wallpaper rendering resume delayed by \(Self.debugResumeDelay)s for fullscreen debug")
    }

    private func shouldSuspendRendering(for wallpaperViewModel: WallpaperViewModel) -> Bool {
        let enabledScreens = NSScreen.screens.filter {
            wallpaperViewModel.isScreenEnabled(WallpaperViewModel.screenId(for: $0))
        }
        guard !enabledScreens.isEmpty else { return false }
        guard let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return false }
        if frontmostApplicationIsMacFullscreen(processID: frontmostPID) { return true }

        let windows = currentRelevantWindows()
        guard !windows.isEmpty else { return false }

        return enabledScreens.contains { screen in
            let displayBoundsCandidates = Self.displayBoundsCandidates(for: screen)
            return displayBoundsCandidates.contains { displayBounds in
                windows.contains { window in
                    window.ownerPID == frontmostPID && isFullscreenWindow(window.bounds, on: displayBounds)
                }
            }
        }
    }

    private func frontmostApplicationIsMacFullscreen(processID: pid_t) -> Bool {
        guard AXIsProcessTrusted() else { return false }

        let application = AXUIElementCreateApplication(processID)
        if let focusedWindow = axElementAttribute(application, kAXFocusedWindowAttribute as CFString),
           axBoolAttribute(focusedWindow, "AXFullScreen" as CFString) == true {
            return true
        }

        guard let windows = axArrayAttribute(application, kAXWindowsAttribute as CFString) else {
            return false
        }
        return windows.contains { axBoolAttribute($0, "AXFullScreen" as CFString) == true }
    }

    private func axElementAttribute(_ element: AXUIElement, _ attribute: CFString) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return (value as! AXUIElement)
    }

    private func axArrayAttribute(_ element: AXUIElement, _ attribute: CFString) -> [AXUIElement]? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        return value as? [AXUIElement]
    }

    private func axBoolAttribute(_ element: AXUIElement, _ attribute: CFString) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        return value as? Bool
    }

    private func currentRelevantWindows() -> [VisibleWindow] {
        guard let windowInfo = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
        }

        return windowInfo.compactMap { info in
            guard let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue,
                  layer == 0,
                  let isOnscreen = (info[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue,
                  isOnscreen,
                  let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue,
                  alpha > 0.01,
                  let boundsValue = info[kCGWindowBounds as String] else {
                return nil
            }

            let boundsDictionary = boundsValue as! CFDictionary
            guard let bounds = CGRect(dictionaryRepresentation: boundsDictionary),
                  bounds.width >= 80,
                  bounds.height >= 80,
                  bounds.area >= 10_000 else {
                return nil
            }

            let ownerPID = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
            return VisibleWindow(bounds: bounds, ownerPID: ownerPID)
        }
    }

    private func isFullscreenWindow(_ windowBounds: CGRect, on displayBounds: CGRect) -> Bool {
        guard !windowBounds.isEmpty, !displayBounds.isEmpty else { return false }

        let tolerance = max(8, min(displayBounds.width, displayBounds.height) * 0.018)
        let intersection = windowBounds.intersection(displayBounds)

        let widthRatio = windowBounds.width / max(displayBounds.width, 1)
        let heightRatio = windowBounds.height / max(displayBounds.height, 1)

        return intersection.area >= displayBounds.area * 0.94
            && widthRatio >= 0.96
            && heightRatio >= 0.92
            && abs(windowBounds.minX - displayBounds.minX) <= tolerance
            && abs(windowBounds.maxX - displayBounds.maxX) <= tolerance
            && abs(windowBounds.minY - displayBounds.minY) <= max(tolerance, displayBounds.height * 0.08)
            && abs(windowBounds.maxY - displayBounds.maxY) <= max(tolerance, displayBounds.height * 0.08)
    }

    private static func displayBoundsCandidates(for screen: NSScreen) -> [CGRect] {
        let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
        let cgBounds = CGDisplayBounds(displayID)
        let candidates = [screen.frame, screen.visibleFrame, cgBounds].filter { !$0.isEmpty }
        return candidates.reduce(into: [CGRect]()) { result, bounds in
            if !result.contains(where: { abs($0.minX - bounds.minX) < 0.5
                && abs($0.minY - bounds.minY) < 0.5
                && abs($0.width - bounds.width) < 0.5
                && abs($0.height - bounds.height) < 0.5 }) {
                result.append(bounds)
            }
        }
    }

    private struct VisibleWindow {
        let bounds: CGRect
        let ownerPID: pid_t?
    }
}

private extension CGRect {
    var area: CGFloat {
        max(0, width) * max(0, height)
    }
}
