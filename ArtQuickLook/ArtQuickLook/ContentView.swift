import SwiftUI

final class SettingsStore: ObservableObject {
    private var settings: Settings
    
    @Published var previewScale: Double     { didSet { settings.previewScale = previewScale } }
    @Published var renderPath: RenderPath   { didSet { settings.renderPath = renderPath } }
    @Published var useCache: Bool           { didSet { settings.useCache = useCache } }
    @Published var cacheSizeMB: Int         { didSet { settings.cacheSizeMB = cacheSizeMB } }
    @Published var generateThumbnails: Bool { didSet { settings.generateThumbnails = generateThumbnails } }
    
    init(settings: Settings = Settings()) {
        self.settings = settings
        // Assignments in init don't fire didSet → no write-back here.
        previewScale = settings.previewScale
        renderPath = settings.renderPath
        useCache = settings.useCache
        cacheSizeMB = settings.cacheSizeMB
        generateThumbnails = settings.generateThumbnails
    }
}

struct ContentView: View {
    @StateObject private var store = SettingsStore()
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScaleRow(store: store)
            
            Picker("Render using:", selection: $store.renderPath) {
                ForEach(RenderPath.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.radioGroup)
            
//            CacheRow(store: store)
            
//            Toggle("Generate thumbnails", isOn: $store.generateThumbnails)
            
            Divider()
            
            Button(action: SystemSettingsRouter.openQuickLookExtensions) {
                Label("Extension System Settings…", systemImage: "gear")
            }
        }
        .padding(20)
        .frame(minWidth: 600, idealWidth: 650, maxWidth: 850) // min/default window size
    }
}

struct ScaleRow: View {
    @ObservedObject var store: SettingsStore
    
    static let sliderRange: ClosedRange<Double> = 0.05...2.0
    static let textRange: ClosedRange<Double> = 0.25...4.0
    static let snapPoints: [Double] = [0.25, 0.5, 0.667, 1.0, 1.333, 2.0]
    static let snapTolerance = 0.06
    static let knobHalfWidth: CGFloat = 10
    
    @State private var text = ""
    @FocusState private var textFocused: Bool
    
    var body: some View {
        HStack {
            Text("Preview image scale:")
            
            VStack(spacing: 1) {
                Slider(value: sliderBinding, in: Self.sliderRange) { editing in
                    if editing { textFocused = false } // release field editor so text tracks the drag
                }
                .overlay(tickMarks)
                
                tickLabels
            }
            
            TextField("", text: $text)
                .textFieldStyle(.squareBorder)
                .frame(width: 64)
                .multilineTextAlignment(.trailing)
                .font(.body.monospacedDigit())
                .focused($textFocused)
                .onSubmit(commit)
                .onChange(of: textFocused) { focused in
                    if !focused { commit() }
                }
            Text("×")
        }
        .onChange(of: store.previewScale) { _ in
            text = Self.display(store.previewScale)   // unconditional now
        }
        .onAppear {
            text = Self.display(store.previewScale)
            DispatchQueue.main.async {
                textFocused = false
                // Belt and braces for the launch auto-selection on macOS 12:
                if let window = NSApp.keyWindow, window.firstResponder is NSText {
                    window.makeFirstResponder(nil)
                }
            }
        }
    }
    
    private var sliderBinding: Binding<Double> {
        Binding(
            get: { min(store.previewScale, Self.sliderRange.upperBound) },
            set: { store.previewScale = Self.snap($0) }
        )
    }
    
    static func snap(_ value: Double) -> Double {
        guard let nearest = snapPoints.min(by: { abs($0 - value) < abs($1 - value) }) else { return value }
        return abs(nearest - value) <= snapTolerance ? nearest : value
    }
    
    static func display(_ value: Double) -> String {
        value.formatted(.number.grouping(.never).precision(.fractionLength(1...3)))
    }
    
    private func commit() {
        if let v = Double(text.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)) {
            store.previewScale = min(max(v, Self.textRange.lowerBound), Self.textRange.upperBound)
        }
        text = Self.display(store.previewScale)
    }
    
    private func fraction(of value: Double) -> Double {
        (value - Self.sliderRange.lowerBound) / (Self.sliderRange.upperBound - Self.sliderRange.lowerBound)
    }
    
    private var tickMarks: some View {
        GeometryReader { geo in
            let usable = geo.size.width - 2 * Self.knobHalfWidth
            ForEach(Self.snapPoints, id: \.self) { p in
                Rectangle()
                    .fill(Color.secondary.opacity(0.55))
                    .frame(width: 1, height: 9)
                    .position(x: Self.knobHalfWidth + fraction(of: p) * usable, y: geo.size.height / 2)
            }
        }
        .allowsHitTesting(false)
    }
    
    private var tickLabels: some View {
        GeometryReader { geo in
            let usable = geo.size.width - 2 * Self.knobHalfWidth
            ForEach(Self.snapPoints, id: \.self) { p in
                Text(Self.display(p))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .position(x: Self.knobHalfWidth + fraction(of: p) * usable, y: geo.size.height / 2)
            }
        }
        .frame(height: 12)
        .allowsHitTesting(false)
    }
}

struct CacheRow: View {
    @ObservedObject var store: SettingsStore
    
    static let sizeRange = 1...8192
    
    @State private var text = ""
    @FocusState private var textFocused: Bool
    
    var body: some View {
        HStack(spacing: 8) {
            Toggle("Use cache", isOn: $store.useCache)
            
            HStack(spacing: 4) {
                Text("Cache size:")
                TextField("", text: $text)
                    .textFieldStyle(.squareBorder)
                    .frame(width: 52)
                    .multilineTextAlignment(.trailing)
                    .font(.body.monospacedDigit())
                    .focused($textFocused)
                    .onSubmit(commit)
                    .onChange(of: textFocused) { focused in
                        if !focused { commit() }
                    }
                Text("MB")
                Stepper("", value: $store.cacheSizeMB, in: Self.sizeRange, step: 10)
                    .labelsHidden()
            }
            .disabled(!store.useCache)
        }
        .onChange(of: store.cacheSizeMB) { _ in
            text = String(store.cacheSizeMB)
        }
        .onAppear { text = String(store.cacheSizeMB) }
    }
    
    private func commit() {
        if let v = Int(text.filter { $0.isNumber }) {
            store.cacheSizeMB = min(max(v, Self.sizeRange.lowerBound), Self.sizeRange.upperBound)
        }
        text = String(store.cacheSizeMB)
    }
}

enum SystemSettingsRouter {
    static func openQuickLookExtensions() {
        if #available(macOS 15, *) {
            // General → Login Items & Extensions (contains Quick Look extensions)
            openURL("x-apple.systempreferences:com.apple.LoginItems-Settings.extension")
        } else if #available(macOS 13, *) {
            // Privacy & Security → Extensions
            openURL("x-apple.systempreferences:com.apple.ExtensionsPreferences")
        } else {
            openLegacyExtensionsPane() // macOS 12 Monterey
        }
    }
    
    private static func openURL(_ urlString: String) {
        let url = URL(string: urlString)!
        let wasRunning = NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == "com.apple.systempreferences"
        }
        NSWorkspace.shared.open(url)
        
        if wasRunning {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                NSWorkspace.shared.open(url)
            }
        }
    }
    
    private static func openLegacyExtensionsPane() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Library/PreferencePanes/Extensions.prefPane"))
    }
}
