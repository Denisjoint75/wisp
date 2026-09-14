import AppKit
import CoreGraphics
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers
import WispCore

struct ScreenshotResult {
    var path: String
    var width: Int
    var height: Int
    var scale: Double       // image pixels per point
    var originX: Double     // screen point of image origin (top-left)
    var originY: Double

    var json: JSON {
        ["path": .string(path), "width": .int(width), "height": .int(height), "scale": .number(scale),
         "origin": [.number(originX), .number(originY)]]
    }
}

enum ScreenshotService {
    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    static func captureWindow(id: CGWindowID, frame: CGRect, maxPixels: Int = 2_400_000) async throws -> ScreenshotResult {
        guard hasPermission else {
            await MainActor.run { PermissionsMonitor.shared.promptScreenRecordingIfNeeded() }
            throw WispError(.permissionsNotGranted, "Screen Recording permission is required for screenshots. Allow Wisp in System Settings > Privacy & Security > Screen Recording (the menu bar item has a shortcut), then retry.")
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let win = content.windows.first(where: { $0.windowID == id }) else {
            throw WispError(.windowNotFound, "window \(id) is not capturable (maybe minimized or on another space)")
        }
        let filter = SCContentFilter(desktopIndependentWindow: win)
        let config = SCStreamConfiguration()
        let scale = NSScreen.screens.first(where: { $0.frame.intersects(flip(frame)) })?.backingScaleFactor ?? 2
        var pw = Int(frame.width * scale), ph = Int(frame.height * scale)
        if pw * ph > maxPixels {
            let f = (Double(maxPixels) / Double(pw * ph)).squareRoot()
            pw = Int(Double(pw) * f); ph = Int(Double(ph) * f)
        }
        config.width = max(1, pw)
        config.height = max(1, ph)
        config.showsCursor = false
        config.captureResolution = .best
        config.ignoreShadowsSingleWindow = true
        if #available(macOS 14.2, *) { config.includeChildWindows = true }
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        let path = try write(image)
        return ScreenshotResult(path: path, width: image.width, height: image.height,
                                scale: Double(image.width) / max(1, frame.width), originX: frame.origin.x, originY: frame.origin.y)
    }

    static func captureDisplay(index: Int) async throws -> ScreenshotResult {
        guard hasPermission else {
            await MainActor.run { PermissionsMonitor.shared.promptScreenRecordingIfNeeded() }
            throw WispError(.permissionsNotGranted, "Screen Recording permission is required for screenshots. Allow Wisp in System Settings > Privacy & Security > Screen Recording, then retry.")
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let displays = content.displays
        guard index >= 0, index < displays.count else { throw WispError(.invalidParams, "display \(index) not found; \(displays.count) displays") }
        let d = displays[index]
        let filter = SCContentFilter(display: d, excludingWindows: [])
        let config = SCStreamConfiguration()
        let scale = 2.0
        config.width = Int(Double(d.width) * scale)
        config.height = Int(Double(d.height) * scale)
        config.showsCursor = true
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        let path = try write(image)
        return ScreenshotResult(path: path, width: image.width, height: image.height, scale: Double(image.width) / Double(d.width),
                                originX: Double(d.frame.origin.x), originY: Double(d.frame.origin.y))
    }

    static func write(_ image: CGImage) throws -> String {
        let url = WispPaths.screenshotDir.appendingPathComponent("wisp-\(UUID().uuidString.prefix(8)).png")
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw WispError(.internalError, "could not create image destination")
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw WispError(.internalError, "could not write screenshot") }
        return url.path
    }

    /// Converts a CG (top-left origin) rect to AppKit screen coordinates.
    static func flip(_ r: CGRect) -> CGRect {
        let h = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: r.origin.x, y: h - r.origin.y - r.height, width: r.width, height: r.height)
    }

    /// Cheap perceptual hash of a window for change detection (uses a tiny capture).
    static func quickHash(windowID: CGWindowID, frame: CGRect) async -> Int? {
        guard hasPermission else { return nil }
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false),
              let win = content.windows.first(where: { $0.windowID == windowID }) else { return nil }
        let filter = SCContentFilter(desktopIndependentWindow: win)
        let config = SCStreamConfiguration()
        config.width = 64
        config.height = 64
        config.showsCursor = false
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config),
              let data = image.dataProvider?.data as Data? else { return nil }
        var h = 5381
        data.withUnsafeBytes { buf in
            for b in buf.bindMemory(to: UInt8.self) { h = ((h << 5) &+ h) &+ Int(b >> 4) }
        }
        return h
    }
}
