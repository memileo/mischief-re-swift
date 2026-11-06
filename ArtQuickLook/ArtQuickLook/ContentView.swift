import AppKit
import SwiftUI
import UniformTypeIdentifiers

final class SettingsStore: ObservableObject {
    private var settings: Settings

    /// Write-backs to the backing plist (App-Group defaults via cfprefsd) are
    /// coalesced per key: rapid changes (a slider drag fires an update per
    /// mouse event) must not hit the defaults daemon on every tick. Each
    /// key's write fires once changes to it have settled for `writeDelay` —
    /// i.e. after editing ends.
    private var pendingWrites: [String: DispatchWorkItem] = [:]
    private static let writeDelay: TimeInterval = 0.3

    @Published var previewScale: Double {
        didSet { debouncedWrite("previewScale") { $0.settings.previewScale = $0.previewScale } }
    }
    @Published var renderPath: RenderPath {
        didSet { debouncedWrite("renderPath") { $0.settings.renderPath = $0.renderPath } }
    }
    @Published var useCache: Bool {
        didSet { debouncedWrite("useCache") { $0.settings.useCache = $0.useCache } }
    }
    @Published var cacheSizeMB: Int {
        didSet { debouncedWrite("cacheSizeMB") { $0.settings.cacheSizeMB = $0.cacheSizeMB } }
    }
    @Published var generateThumbnails: Bool {
        didSet { debouncedWrite("generateThumbnails") { $0.settings.generateThumbnails = $0.generateThumbnails } }
    }
    @Published var liveMaxFPS: Double {
        didSet { debouncedWrite("liveMaxFPS") { $0.settings.liveMaxFPS = $0.liveMaxFPS } }
    }

    init(settings: Settings = Settings()) {
        self.settings = settings
        // Assignments in init don't fire didSet → no write-back here.
        previewScale = settings.previewScale
        renderPath = settings.renderPath
        useCache = settings.useCache
        cacheSizeMB = settings.cacheSizeMB
        generateThumbnails = settings.generateThumbnails
        liveMaxFPS = settings.liveMaxFPS
        // Quitting while a write is still debounced: flush now, so the last
        // change never dies with the process.
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(appWillTerminate),
                                               name: NSApplication.willTerminateNotification,
                                               object: nil)
    }

    private func debouncedWrite(_ key: String, _ apply: @escaping (SettingsStore) -> Void) {
        pendingWrites[key]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            apply(self)
        }
        pendingWrites[key] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.writeDelay, execute: work)
    }

    @objc private func appWillTerminate() {
        flush()
    }

    /// Runs every pending write immediately.
    func flush() {
        for (key, work) in pendingWrites {
            work.cancel()
            pendingWrites[key] = nil
            work.perform()
        }
    }
}

struct ContentView: View {
    @StateObject private var store = SettingsStore()
    @State private var isImportingDocument = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScaleRow(store: store)
            
            Picker("Render using:", selection: $store.renderPath) {
                ForEach(RenderPath.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.radioGroup)
            
            if store.renderPath.isLiveView {
                LiveViewHelp(store: store)
                FrameRateRow(store: store)
            }
            
//            CacheRow(store: store)
            
//            Toggle("Generate thumbnails", isOn: $store.generateThumbnails)
            
            Divider()

            // Opens the document in its own live-view window — also the way to get a
            // profileable process (Instruments attaches to the app, not to a Quick Look
            // preview, which is hosted out-of-process).
            Button {
                isImportingDocument = true
            } label: {
                Label("Open Document…", systemImage: "doc")
            }

            Button(action: SystemSettingsRouter.openQuickLookExtensions) {
                Label("Extension System Settings…", systemImage: "gear")
            }
        }
        .padding(20)
        .frame(minWidth: 600, idealWidth: 650, maxWidth: 850) // min/default window size
        .fileImporter(isPresented: $isImportingDocument,
                      allowedContentTypes: [UTType(filenameExtension: "art") ?? .data],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                for url in urls { openDocument(url) }
            }
        }
    }

    /// macOS 12 replacement for `openWindow(id:value:)`.
    private func openDocument(_ url: URL) {
        DocumentWindowCoordinator.shared.open(url: url)
    }
}

/// Frame-rate cap for the live view: presets plus a free-form value (0 = uncapped).
///
/// Rendering faster than the display can show only burns GPU and, with the interactive
/// path, competes with the render thread for the frame budget.
struct FrameRateRow: View {
    @ObservedObject var store: SettingsStore

    /// Non-nil while the user is editing a custom value.
    @State private var custom: String?

    private let presets: [Double] = [0, 30, 60, 120]

    /// Tag for the "Custom…" entry — negative, so it can never collide with a preset.
    private static let customTag: Double = -1

    var body: some View {
        HStack(spacing: 8) {
            Text("Max frames/second")
                .font(.body)

            Picker("", selection: Binding(
                get: { custom == nil ? store.liveMaxFPS : Self.customTag },
                set: { value in
                    if value == Self.customTag {
                        // Seeding with the current value keeps the field usable; leaving it
                        // empty is why picking "Custom" used to show nothing at all.
                        custom = presets.contains(store.liveMaxFPS)
                            ? String(Int(store.liveMaxFPS))
                            : String(Int(store.liveMaxFPS))
                    } else {
                        custom = nil
                        store.liveMaxFPS = value
                    }
                }
            )) {
                ForEach(presets, id: \.self) { fps in
                    Text(fps == 0 ? "Uncapped" : "\(Int(fps))").tag(fps)
                }
                Text("Custom…").tag(Self.customTag)
            }
            .labelsHidden()
            .frame(width: 130)

            if custom != nil {
                TextField("fps", text: Binding(
                    get: { custom ?? String(Int(store.liveMaxFPS)) },
                    set: { custom = $0 }
                ))
                .frame(width: 70)
                .onSubmit {
                    let value = Double(custom ?? "") ?? store.liveMaxFPS
                    store.liveMaxFPS = max(0, value)
                    custom = nil
                }
            }
        }
        .onAppear {
            custom = presets.contains(store.liveMaxFPS) ? nil : String(Int(store.liveMaxFPS))
        }
        .help("The display cannot show more frames than its refresh rate. “Uncapped” is the old behaviour.")
    }
}

/// Shortcut reference for the live view, shown while the live view is selected.
struct LiveViewHelp: View {
    @ObservedObject var store: SettingsStore

    private let rows: [(String, String)] = [
        ("LMB or MMB", "Pan"),
        ("⇧ + LMB or ⇧ + MMB", "Rotate"),
        ("⌘ + LMB or ⌘ + MMB", "Zoom"),
        ("Scroll wheel", "Zoom at the pointer"),
        ("Right click", "Reset menu")
    ]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(rows, id: \.0) { keys, action in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(keys)
                        .font(.caption) // .font(.caption.monospaced())
                        .frame(width: 108, alignment: .leading)
                    Text(action)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
//            Text("""
//                 The document is re-rendered on the GPU for the current view, so zooming in \
//                 keeps full detail. “Preview image scale” sets the geometry cache's resolution.
//                 """)
//                .font(.caption2)
//                .foregroundStyle(.secondary)
//                .fixedSize(horizontal: false, vertical: true)
//                .padding(.top, 4)

        }
    }
}

struct ScaleRow: View {
    @ObservedObject var store: SettingsStore
    
    static let sliderRange: ClosedRange<Double> = 0.05...2.0
    static let textRange: ClosedRange<Double> = 0.25...4.0
    static let snapPoints: [Double] = [0.25, 0.5, 0.6667, 1.0, 1.333, 2.0]
    static let snapTolerance = 0.04
    static let knobHalfWidth: CGFloat = 10
    
    @State private var text = ""
    @FocusState private var textFocused: Bool
    
    var body: some View {
        HStack (
            alignment: .firstTextBaseline
        ) {
            Text("Preview image scale:")
            
            VStack(spacing: 1) {
                SnappingSlider(value: sliderBinding,
                               range: Self.sliderRange,
                               snapPoints: Self.snapPoints,
                               snapTolerance: Self.snapTolerance)
                    .frame(maxWidth: .infinity)
                    .overlay(tickMarks)
                
                tickLabels
            }
            
            TextField("", text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 68)
                .multilineTextAlignment(.leading)
                .font(.body.monospacedDigit())
                .focused($textFocused)
                .onSubmit(commit)
                .overlay(Text("×")
                    .padding(.leading, 42)
                    .multilineTextAlignment(.trailing))
                .onChange(of: textFocused) { focused in
                    if !focused { commit() }
                }
//            Text("✕")
        }
        .onChange(of: store.previewScale) { _ in
            text = Self.display(store.previewScale) // + " ×"   // unconditional now
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

// MARK: - Snapping slider (animated snap on release)

/// `NSViewRepresentable` around `NSSlider` that commits the snapped value on
/// release instead of mid-drag.
///
/// All mouse interaction stays native (`NSSlider`'s own cell tracking), so the
/// knob gets the standard pressed appearance and the standard track-click
/// glide while the button is held. The control only adds a release step: the
/// binding is committed with the snapped value and the knob glides any
/// remaining distance to it. Clicking empty track therefore animates to the
/// clicked (or snapped) position instead of teleporting, and a release before
/// the native glide finishes never jumps.
///
/// Swift-land constraints that fall out of this:
///
/// * While the knob is actually being dragged, each action pulls the knob to
///   the snap point (sticky, like Apple's tick-mark sliders — e.g. the Sound
///   alert volume). The cell re-derives the value from the pointer per event,
///   so this write cannot accumulate error.
/// * During the track-click glide the pointer never moves; the action
///   detector distinguishes the two by pointer movement and leaves
///   `doubleValue` alone in the glide so the native animation is not cut.
/// * `updateNSView` must not force values over a live knob (`isEditing`) nor
///   over a release glide in flight (`isAnimating`).
struct SnappingSlider: NSViewRepresentable {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let snapPoints: [Double]
    let snapTolerance: Double

    func makeNSView(context: Context) -> SnapSliderControl {
        let control = SnapSliderControl(value: value,
                                        minValue: range.lowerBound,
                                        maxValue: range.upperBound,
                                        target: nil, action: nil)
        control.snapPoints = snapPoints
        control.snapTolerance = snapTolerance
        control.onValueChange = { value = $0 }
        // The cell's action dispatch (native tracking while pressed and the
        // keyboard nudges) feeds the binding through one handler.
        control.target = control
        control.action = #selector(SnapSliderControl.sliderAction(_:))
        return control
    }

    func updateNSView(_ control: SnapSliderControl, context: Context) {
        guard !control.isEditing, !control.isAnimating else { return }
        control.doubleValue = value
    }
}

final class SnapSliderControl: NSSlider {

    /// Same tolerance semantics as ScaleRow.snap.
    var snapPoints: [Double] = []
    var snapTolerance: Double = 0.04
    /// Write-back to the binding while the knob moves.
    var onValueChange: ((Double) -> Void)?

    /// Native tracking (`super.mouseDown`) is in progress.
    private(set) var isEditing = false
    /// A release glide to a snap point is animating the knob.
    private(set) var isAnimating = false
    private var animationTimer: Timer?

    /// Screen-space pointer position at mouse-down. A real drag keeps
    /// producing mouse-dragged events (which update `NSEvent.mouseLocation`);
    /// the track-click glide never does — that is how the action handler
    /// tells them apart.
    private var downScreen = NSPoint.zero
    private static let dragJitter: CGFloat = 4
    private var dragging = false

    private func snapped(_ value: Double) -> Double {
        guard let nearest = snapPoints.min(by: { abs($0 - value) < abs($1 - value) }) else {
            return value
        }
        return abs(nearest - value) <= snapTolerance ? nearest : value
    }

    // MARK: Interaction

    /// Only the release is custom; everything else is the cell's own tracking.
    override func mouseDown(with event: NSEvent) {
        stopAnimation()
        downScreen = NSEvent.mouseLocation
        dragging = false
        isEditing = true
        super.mouseDown(with: event)
        isEditing = false
        dragging = false

        // Editing is over: commit the snapped value and glide the knob the
        // remaining distance if the pointer landed between snap points. This
        // also covers a click released mid-glide, which can leave the knob
        // anywhere along the way.
        let target = snapped(doubleValue)
        onValueChange?(target)
        if target != doubleValue {
            animateKnob(from: doubleValue, to: target)
        }
    }

    /// Continuous action dispatch while the knob moves.
    ///
    /// Once the pointer has moved a real distance from the press point, the
    /// interaction is a drag: the knob becomes sticky — each update pulls it
    /// to the snap point, matching the tick-mark sliders in Apple's own
    /// preference panes. Before that (i.e. the whole track-click glide, whose
    /// only "events" are animation frames while the pointer is pinned), the
    /// handler does nothing at all: no binding commits to churn the text
    /// field, and no `doubleValue` writes to cut the native glide short.
    @objc func sliderAction(_ sender: NSSlider) {
        if hypot(NSEvent.mouseLocation.x - downScreen.x,
                 NSEvent.mouseLocation.y - downScreen.y) >= Self.dragJitter {
            dragging = true
        }
        guard dragging else { return }

        let value = snapped(sender.doubleValue)
        doubleValue = value
        onValueChange?(value)
    }

    // MARK: Release glide

    /// Eases the knob to the target (display only — the binding already holds
    /// the committed value, which the text field reflects immediately).
    private func animateKnob(from start: Double, to target: Double) {
        let duration = 0.18
        let startTime = Date().timeIntervalSinceReferenceDate
        let timer = Timer(timeInterval: 1 / 120, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            let progress = min((Date().timeIntervalSinceReferenceDate - startTime) / duration, 1)
            let eased = 1 - pow(1 - progress, 3)      // ease-out cubic
            self.doubleValue = start + (target - start) * eased
            self.needsDisplay = true
            if progress >= 1 {
                timer.invalidate()
                self.animationTimer = nil
                self.isAnimating = false
            }
        }
        animationTimer = timer
        // .common keeps it ticking inside any active event-tracking loop.
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopAnimation() {
        animationTimer?.invalidate()
        animationTimer = nil
        isAnimating = false
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
