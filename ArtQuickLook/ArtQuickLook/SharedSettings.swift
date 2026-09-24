import Foundation

/// Must exactly match the App Groups entitlement in ALL targets.
/// (If sandboxed, use the Team-ID-prefixed string Xcode generates.)
enum AppGroup {
    static let id = "group.org.potato.ArtQuickLook"
    
    static var defaults: UserDefaults {
        UserDefaults(suiteName: id) ?? .standard
    }
}

enum RenderPath: String, CaseIterable, Identifiable {
    case gpuSegments, gpuStamps, cpuStamps
    
    var id: Self { self }
    
    var label: String {
        switch self {
            case .gpuSegments: return "GPU SDF segments (Default)"
            case .gpuStamps:   return "GPU stamps"
            case .cpuStamps:   return "CPU stamps"
        }
    }
}

private enum Keys {
    static let previewScale = "previewScale"
    static let renderPath = "renderPath"
    static let useCache = "useCache"
    static let cacheSizeMB = "cacheSizeMB"
    static let generateThumbnails = "generateThumbnails"
}

/// Reads/writes the shared suite. This *is* the plist you were going to
/// write by hand — UserDefaults manages the file via cfprefsd.
struct Settings {
    private let d: UserDefaults
    
    init(defaults: UserDefaults = AppGroup.defaults) { self.d = defaults }
    
    var previewScale: Double {
        get { d.object(forKey: Keys.previewScale) as? Double ?? 1.0 }
        set { d.set(newValue, forKey: Keys.previewScale) }
    }
    var renderPath: RenderPath {
        get { RenderPath(rawValue: d.string(forKey: Keys.renderPath) ?? "") ?? .gpuSegments }
        set { d.set(newValue.rawValue, forKey: Keys.renderPath) }
    }
    var useCache: Bool {
        get { d.object(forKey: Keys.useCache) as? Bool ?? true }
        set { d.set(newValue, forKey: Keys.useCache) }
    }
    var cacheSizeMB: Int {
        get { d.object(forKey: Keys.cacheSizeMB) as? Int ?? 100 }
        set { d.set(newValue, forKey: Keys.cacheSizeMB) }
    }
    var generateThumbnails: Bool {
        get { d.object(forKey: Keys.generateThumbnails) as? Bool ?? true }
        set { d.set(newValue, forKey: Keys.generateThumbnails) }
    }
}
