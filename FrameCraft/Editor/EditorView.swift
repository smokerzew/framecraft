import SwiftUI

/// The editor a photo opens in right after it's taken (already edited: a look, a measured correction, a little
/// grain). Looks · Adjust · Effects · Frames, a ruler slider for the selected setting, and Delete · undo · redo ·
/// Save. Non-destructive: the original stays as captured and the edit saves as you go.
struct EditorView: View {
    @Bindable var app: AppModel
    @Bindable var session: EditSession
    @Environment(\.cameraReduceMotion) private var reduceMotion
    @State private var tab: EditorTab = .looks
    @State private var showExport = false
    @State private var confirmDelete = false
    @State private var isSaving = false
    @State private var effect: EffectTool = .grain
    @State private var effectOption: EffectOption?
    @State private var adjust: AdjustTool = .exposure
    @State private var showLookStrength = false
    @State private var detail: AdjustTool?
    @State private var lookTiles: [FilmLook: CGImage] = [:]

    var body: some View {
        VStack(spacing: 0) {
            photo
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            tabs
                .padding(.top, 10)
            panel
                .frame(height: 196)
            bottomBar
        }
        .background(Color.black.ignoresSafeArea())
        .sheet(isPresented: $showExport) { ExportSheet(app: app, session: session) }
        .sheet(item: $detail) { tool in
            NavigationStack {
                ScrollView {
                    Group {
                        switch tool {
                        case .hsl: MixerSection(session: session)
                        case .grading: GradeSection(session: session)
                        case .curves: CurvesSection(session: session)
                        case .calibration: CalibrationSection(session: session)
                        default: CropSection(session: session)
                        }
                    }
                    .padding(16)
                }
                .navigationTitle(tool.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { detail = nil } } }
            }
            .presentationDetents([.medium, .large])
            .presentationBackground(.ultraThinMaterial)
        }
        .confirmationDialog("Delete this photo?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete from FrameCraft", role: .destructive) { app.delete(session.project) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes FrameCraft's copy and its edit. Photos you saved to the Photos app stay there.")
        }
        .appAlert(app)
        .task(id: session.preview == nil) { await renderLookTiles() }
    }

    // MARK: Photo

    private var photo: some View {
        ZStack(alignment: .top) {
            if let image = session.displayed {
                GeometryReader { proxy in
                    let fitted = fit(CGSize(width: image.width, height: image.height), in: proxy.size)
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .scaledToFit()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .contentShape(Rectangle())
                        .gesture(leakDrag(fitted))
                        .simultaneousGesture(LongPressGesture(minimumDuration: 0.25).onChanged { _ in session.showOriginal = true }
                            .sequenced(before: DragGesture(minimumDistance: 0)).onEnded { _ in session.showOriginal = false })
                        .accessibilityLabel(session.showOriginal ? "Original photo" : "Edited photo")
                        .accessibilityAction(named: "Show original") { session.showOriginal.toggle() }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            } else {
                ProgressView().tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            HStack {
                circleButton("xmark", label: "Back to the camera") { app.closeEditor() }
                Spacer()
                if session.showOriginal { CameraTag(text: "ORIGINAL", isOff: true) }
                Spacer()
                circleButton("ellipsis", label: "Export and share") { showExport = true }
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)

            if tab == .effects, effect == .lightLeak {
                Text("Drag on the photo to place the leak")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(.black.opacity(0.55), in: Capsule())
                    .frame(maxHeight: .infinity)
                    .allowsHitTesting(false)
            }
        }
    }

    private func circleButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(.black.opacity(0.45), in: Circle())
        }
        .accessibilityLabel(label)
    }

    private func fit(_ image: CGSize, in box: CGSize) -> CGRect {
        guard image.width > 0, image.height > 0 else { return CGRect(origin: .zero, size: box) }
        let s = min(box.width / image.width, box.height / image.height)
        let size = CGSize(width: image.width * s, height: image.height * s)
        return CGRect(x: (box.width - size.width) / 2, y: (box.height - size.height) / 2, width: size.width, height: size.height)
    }

    /// While Light leak is selected, dragging on the photo moves where the leak comes in.
    private func leakDrag(_ fitted: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard tab == .effects, effect == .lightLeak, fitted.width > 0 else { return }
                let x = Double(min(max((value.location.x - fitted.minX) / fitted.width, 0), 1))
                let y = Double(min(max((value.location.y - fitted.minY) / fitted.height, 0), 1))
                session.update {
                    $0.leakX = x
                    $0.leakY = y
                    if $0.lightLeak == 0 { $0.lightLeak = 0.4 }
                }
            }
    }

    // MARK: Tabs

    private var tabs: some View {
        HStack(spacing: 4) {
            ForEach(EditorTab.allCases) { item in
                Button { withAnimation(reduceMotion ? nil : .spring(duration: 0.3)) { tab = item } } label: {
                    Text(item.title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(tab == item ? Color.white : .white.opacity(0.55))
                        .padding(.horizontal, 12)
                        .frame(minHeight: 32)
                        .background { if tab == item { Capsule().fill(.white.opacity(0.16)) } }
                        .overlay(alignment: .topTrailing) {
                            if isModified(item) { Circle().fill(Color.yellow).frame(width: 5, height: 5).offset(x: -3, y: 5) }
                        }
                }
                .accessibilityLabel(item.title)
                .accessibilityValue(isModified(item) ? "Edited" : "")
                .accessibilityAddTraits(tab == item ? .isSelected : [])
            }
        }
        .padding(4)
        .background(.white.opacity(0.07), in: Capsule())
        .frame(maxWidth: .infinity)
        .overlay(alignment: .trailing) {
            if isModified(tab) {
                Button("Reset") { reset(tab) }
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.yellow)
                    .padding(.trailing, 16)
            }
        }
    }

    private func isModified(_ tab: EditorTab) -> Bool {
        let e = session.edit, d = EditState()
        switch tab {
        case .looks: return e.look != d.look || e.lookStrength != d.lookStrength
        case .adjust: return e.resetting(.light).resetting(.color).resetting(.crop) != e
        case .effects: return e.resetting(.effects) != e
        case .frames: return !session.project.finish.isEmpty
        }
    }

    private func reset(_ tab: EditorTab) {
        switch tab {
        case .looks: session.reset(.look)
        case .adjust: session.replace(with: session.edit.resetting(.light).resetting(.color).resetting(.crop))
        case .effects: session.reset(.effects)
        case .frames: session.setFinish(FinishSettings())
        }
    }

    // MARK: Panels

    @ViewBuilder
    private var panel: some View {
        switch tab {
        case .looks: looksPanel
        case .adjust: adjustPanel
        case .effects: effectsPanel
        case .frames: framesPanel
        }
    }

    private var looksPanel: some View {
        VStack(spacing: 14) {
            if showLookStrength, session.edit.look != .none {
                chipRow { chip("Strength \(Int((session.edit.lookStrength * 100).rounded()))", selected: true) {} }
                RulerSlider(value: session.edit.lookStrength, range: 0...1) { v in session.update { $0.lookStrength = v } }
            } else {
                Spacer(minLength: 0)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(FilmLook.allCases) { look in
                        let selected = session.edit.look == look
                        Button {
                            if selected { showLookStrength.toggle() } else {
                                var next = session.edit
                                next.look = look
                                session.replace(with: next)
                                showLookStrength = false
                            }
                        } label: {
                            VStack(spacing: 7) {
                                ZStack {
                                    if let tile = lookTiles[look] {
                                        Image(decorative: tile, scale: 1).resizable().scaledToFill()
                                    } else {
                                        Color.white.opacity(0.08)
                                    }
                                    if selected, look != .none {
                                        Image(systemName: "slider.horizontal.3")
                                            .font(.system(size: 16, weight: .semibold))
                                            .foregroundStyle(.white)
                                            .shadow(radius: 3)
                                    }
                                }
                                .frame(width: 62, height: 78)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .strokeBorder(selected ? Color.yellow : .clear, lineWidth: 2)
                                }
                                Text(look.label.uppercased())
                                    .font(.system(size: 10, weight: .medium))
                                    .tracking(0.8)
                                    .foregroundStyle(selected ? Color.yellow : .white.opacity(0.6))
                                    .lineLimit(1)
                            }
                        }
                        .accessibilityLabel("\(look.label), \(look.summary)")
                        .accessibilityHint(selected ? "Tap to adjust its strength" : "")
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
                .padding(.horizontal, 16)
            }
        }
        .padding(.vertical, 10)
    }

    private var adjustPanel: some View {
        VStack(spacing: 14) {
            if let parameter = adjust.parameter {
                chipRow { chip("\(parameter.title) \(parameter.format(session.edit[parameter]))", selected: true) {} }
                RulerSlider(value: session.edit[parameter], range: parameter.range, bipolar: parameter.range.lowerBound < 0) { v in
                    session.update { $0[parameter] = v }
                }
            } else {
                Spacer(minLength: 0)
            }
            toolRow(AdjustTool.allCases, selected: adjust, isOn: { tool in
                tool.parameter.map { session.edit[$0] != $0.defaultValue } ?? toolModified(tool)
            }) { tool in
                if tool.parameter == nil { detail = tool } else { adjust = tool }
            }
        }
        .padding(.vertical, 10)
    }

    private func toolModified(_ tool: AdjustTool) -> Bool {
        let e = session.edit
        switch tool {
        case .hsl: return !e.mixer.isNeutral
        case .grading: return e.gradeShadowAmount > 0 || e.gradeHighlightAmount > 0
        case .curves: return !e.curves.isIdentity
        case .calibration: return !e.calibration.isNeutral
        case .crop: return e.hasGeometry
        default: return false
        }
    }

    private var effectsPanel: some View {
        VStack(spacing: 14) {
            chipRow {
                let main = effect.parameter
                chip("\(effect.title) \(Int((session.edit[main] * 100).rounded()))", selected: effectOption == nil) { effectOption = nil }
                ForEach(effect.options) { option in
                    chip(option.title, selected: effectOption == option) { effectOption = option }
                }
                if effect.shuffles {
                    Button {
                        session.update { $0.effectSeed = Int.random(in: 1...999_999) }
                    } label: {
                        Image(systemName: "shuffle")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.8))
                            .frame(width: 34, height: 26)
                            .background(.white.opacity(0.1), in: Capsule())
                    }
                    .accessibilityLabel("Shuffle \(effect.title)")
                }
            }
            if let option = effectOption, effect.options.contains(option) {
                RulerSlider(value: session.edit[keyPath: option.keyPath], range: option.range, bipolar: option.range.lowerBound < 0) { v in
                    session.update { $0[keyPath: option.keyPath] = v }
                }
            } else {
                RulerSlider(value: session.edit[effect.parameter], range: effect.parameter.range,
                            bipolar: effect.parameter.range.lowerBound < 0) { v in
                    session.update { $0[effect.parameter] = v }
                }
            }
            toolRow(EffectTool.allCases, selected: effect, isOn: { session.edit[$0.parameter] != 0 }) { tool in
                effect = tool
                effectOption = nil
            }
        }
        .padding(.vertical, 10)
    }

    private var framesPanel: some View {
        VStack(spacing: 14) {
            chipRow {
                chip(session.project.finish.dateStamp ? "Date stamp on" : "Date stamp", selected: session.project.finish.dateStamp) {
                    var f = session.project.finish
                    f.dateStamp.toggle()
                    session.setFinish(f)
                }
                .disabled(session.metadata.date == nil)
                .opacity(session.metadata.date == nil ? 0.4 : 1)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(FrameStyle.allCases) { style in
                        let selected = session.project.finish.frame == style
                        Button {
                            var f = session.project.finish
                            f.frame = style
                            session.setFinish(f)
                        } label: {
                            VStack(spacing: 7) {
                                FramePreviewTile(style: style)
                                    .frame(width: 62, height: 78)
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .strokeBorder(selected ? Color.yellow : .clear, lineWidth: 2)
                                    }
                                Text(style.label.uppercased())
                                    .font(.system(size: 10, weight: .medium))
                                    .tracking(0.8)
                                    .foregroundStyle(selected ? Color.yellow : .white.opacity(0.6))
                            }
                        }
                        .accessibilityLabel("\(style.label) frame")
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
                .padding(.horizontal, 16)
            }
        }
        .padding(.vertical, 10)
    }

    // MARK: Pieces

    private func chipRow<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 8) { content() }
            .frame(maxWidth: .infinity)
            .frame(height: 28)
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .medium).monospacedDigit())
                .foregroundStyle(selected ? Color.white : .white.opacity(0.55))
                .padding(.horizontal, 10)
                .frame(minHeight: 26)
                .background(.white.opacity(selected ? 0.16 : 0.08), in: Capsule())
        }
    }

    private func toolRow<Tool: EditorTool>(_ tools: [Tool], selected: Tool, isOn: @escaping (Tool) -> Bool,
                                           action: @escaping (Tool) -> Void) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(tools) { tool in
                    let current = tool == selected
                    Button { action(tool) } label: {
                        VStack(spacing: 6) {
                            Image(systemName: tool.symbol)
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(current ? Color.yellow : .white.opacity(0.75))
                                .frame(width: 42, height: 42)
                                .background(Circle().fill(.white.opacity(current ? 0.14 : 0.07)))
                                .overlay { if current { Circle().strokeBorder(.white.opacity(0.8), lineWidth: 1.2) } }
                                .overlay(alignment: .topTrailing) {
                                    if isOn(tool) { Circle().fill(Color.yellow).frame(width: 5, height: 5).offset(x: -2, y: 2) }
                                }
                            Text(tool.title)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(current ? Color.white : .white.opacity(0.55))
                                .lineLimit(1)
                        }
                        .frame(width: 58)
                    }
                    .accessibilityLabel(tool.title)
                    .accessibilityValue(isOn(tool) ? "On" : "Off")
                    .accessibilityAddTraits(current ? .isSelected : [])
                }
            }
            .padding(.horizontal, 12)
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 18) {
            Button { confirmDelete = true } label: {
                Text("Delete")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 22)
                    .frame(minHeight: 44)
                    .background(.white.opacity(0.12), in: Capsule())
            }
            Spacer()
            Button { session.undo() } label: { Image(systemName: "arrow.uturn.backward").font(.system(size: 17, weight: .semibold)) }
                .foregroundStyle(.white.opacity(session.canUndo ? 1 : 0.3))
                .disabled(!session.canUndo)
                .accessibilityLabel("Undo")
            Button { session.redo() } label: { Image(systemName: "arrow.uturn.forward").font(.system(size: 17, weight: .semibold)) }
                .foregroundStyle(.white.opacity(session.canRedo ? 1 : 0.3))
                .disabled(!session.canRedo)
                .accessibilityLabel("Redo")
            Spacer()
            Button { save() } label: {
                HStack(spacing: 6) {
                    if isSaving { ProgressView().tint(.black) } else { Image(systemName: "checkmark") }
                    Text("Save")
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.black)
                .padding(.horizontal, 22)
                .frame(minHeight: 44)
                .background(Color.yellow, in: Capsule())
            }
            .disabled(isSaving)
            .accessibilityHint("Saves the finished photo to Photos and goes back to the camera")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// Saves the finished photo (full resolution, with its frame) to Photos, then back to the camera.
    private func save() {
        isSaving = true
        let original = session.original
        let edit = session.edit
        let options = ExportOptions(format: ExportFormat(rawValue: UserDefaults.standard.string(forKey: SettingsKey.exportFormat) ?? "") ?? .jpeg,
                                    finish: session.project.finish,
                                    removeLocation: UserDefaults.standard.bool(forKey: SettingsKey.removeLocation))
        Task {
            defer { isSaving = false }
            do {
                let url = try await ExportService().export(original: original, edit: edit, options: options)
                try await ExportService.saveToPhotos(url)
                app.showToast("Saved to Photos")
                app.closeEditor()
            } catch {
                app.alert = AppAlert(title: "Couldn't Save", message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    private func renderLookTiles() async {
        guard let preview = session.preview else { return }
        let base = session.edit
        lookTiles = await Task.detached(priority: .userInitiated) { () -> [FilmLook: CGImage] in
            let renderer = PhotoRenderer.shared
            let full = CIImage(cgImage: preview)
            let scale = 200 / max(full.extent.width, full.extent.height, 1)
            let small = full.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            var result: [FilmLook: CGImage] = [:]
            for look in FilmLook.allCases {
                // Each tile shows the photo with that look, keeping the photo's other adjustments.
                var edit = base
                edit.look = look
                edit.lookStrength = 1
                edit.grain = 0
                edit.dust = 0
                edit.scratches = 0
                let output = renderer.render(edit, to: small)
                if let image = renderer.context.createCGImage(output, from: output.extent) { result[look] = image }
            }
            return result
        }.value
    }
}

// MARK: - Editor tools

enum EditorTab: String, CaseIterable, Identifiable {
    case looks, adjust, effects, frames
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

protocol EditorTool: Identifiable, Hashable {
    var title: String { get }
    var symbol: String { get }
}

enum AdjustTool: String, CaseIterable, Identifiable, EditorTool {
    case exposure, contrast, highlights, shadows, whites, blacks, fade, temperature, tint, saturation, vibrance
    case hsl, grading, curves, calibration, crop

    var id: String { rawValue }
    var parameter: EditParameter? { EditParameter(rawValue: rawValue) }
    var title: String {
        switch self {
        case .hsl: "HSL"
        case .grading: "Grading"
        case .temperature: "Warmth"
        default: parameter?.title ?? rawValue.capitalized
        }
    }
    var symbol: String {
        switch self {
        case .hsl: "paintpalette"
        case .grading: "circle.lefthalf.filled.righthalf.striped.horizontal"
        case .curves: "chart.line.uptrend.xyaxis"
        case .calibration: "circle.hexagongrid"
        case .crop: "crop.rotate"
        default: parameter?.systemImage ?? "slider.horizontal.3"
        }
    }
}

enum EffectTool: String, CaseIterable, Identifiable, EditorTool {
    case grain, motion, lightLeak, scratches, halation, dust, glow, fringe, vignette

    var id: String { rawValue }
    var parameter: EditParameter {
        switch self {
        case .grain: .grain
        case .motion: .motionBlur
        case .lightLeak: .lightLeak
        case .scratches: .scratches
        case .halation: .halation
        case .dust: .dust
        case .glow: .glow
        case .fringe: .fringe
        case .vignette: .vignette
        }
    }
    var title: String { self == .motion ? "Motion" : parameter.title }
    var symbol: String {
        switch self {
        case .grain: "circle.grid.3x3.fill"
        case .motion: "arrow.left.arrow.right"
        case .lightLeak: "bolt"
        case .scratches: "line.diagonal"
        case .halation: "drop"
        case .dust: "leaf"
        case .glow: "sparkles"
        case .fringe: "circle.lefthalf.striped.horizontal"
        case .vignette: "circle"
        }
    }
    var options: [EffectOption] {
        switch self {
        case .grain: [.grainSize]
        case .motion: [.motionAngle]
        case .lightLeak: [.leakSize, .leakWarmth]
        case .halation: [.halationSpread]
        default: []
        }
    }
    var shuffles: Bool { self == .lightLeak || self == .scratches || self == .dust }
}

enum EffectOption: String, Identifiable, Hashable {
    case grainSize, motionAngle, leakSize, leakWarmth, halationSpread

    var id: String { rawValue }
    var title: String {
        switch self {
        case .grainSize, .leakSize: "Size"
        case .motionAngle: "Angle"
        case .leakWarmth: "Warmth"
        case .halationSpread: "Spread"
        }
    }
    var keyPath: WritableKeyPath<EditState, Double> {
        switch self {
        case .grainSize: \.grainSize
        case .motionAngle: \.motionAngle
        case .leakSize: \.leakSize
        case .leakWarmth: \.leakWarmth
        case .halationSpread: \.halationSpread
        }
    }
    var range: ClosedRange<Double> {
        switch self {
        case .motionAngle: -90...90
        case .leakWarmth: -1...1
        default: 0...1
        }
    }
}

/// A ruler of ticks with a yellow fill from zero (or the middle, for settings that go both ways) to the value.
/// Drag anywhere along it.
struct RulerSlider: View {
    let value: Double
    var range: ClosedRange<Double> = 0...1
    var bipolar = false
    let onChange: (Double) -> Void

    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            let t = CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))
            let origin: CGFloat = bipolar ? 0.5 : 0
            ZStack(alignment: .leading) {
                HStack(spacing: 0) {
                    ForEach(0..<41, id: \.self) { i in
                        Rectangle()
                            .fill(.white.opacity(i % 10 == 0 ? 0.55 : 0.25))
                            .frame(width: 1, height: i % 10 == 0 ? 14 : 8)
                        if i < 40 { Spacer(minLength: 0) }
                    }
                }
                Rectangle()
                    .fill(Color.yellow)
                    .frame(width: abs(t - origin) * w, height: 2)
                    .offset(x: min(t, origin) * w)
                Rectangle()
                    .fill(Color.yellow)
                    .frame(width: 2, height: 20)
                    .offset(x: t * w - 1)
            }
            .frame(height: 24)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                let p = Double(min(max(g.location.x / max(w, 1), 0), 1))
                onChange(range.lowerBound + p * (range.upperBound - range.lowerBound))
            })
        }
        .frame(height: 24)
        .padding(.horizontal, 24)
        .accessibilityElement()
        .accessibilityValue("\(Int(((value - range.lowerBound) / (range.upperBound - range.lowerBound) * 100).rounded())) percent")
        .accessibilityAdjustableAction { direction in
            let step = (range.upperBound - range.lowerBound) / 50
            onChange(min(max(value + (direction == .increment ? step : -step), range.lowerBound), range.upperBound))
        }
    }
}

/// A small drawing of each frame style for the Frames tab.
struct FramePreviewTile: View {
    let style: FrameStyle

    var body: some View {
        let colors: (Color, Color) = switch style {
        case .none: (.clear, .clear)
        case .plain, .white, .specs: (.white, .white)
        case .paper: (Color(red: 0.95, green: 0.93, blue: 0.88), Color(red: 0.95, green: 0.93, blue: 0.88))
        case .black: (Color(white: 0.06), Color(white: 0.06))
        case .negative: (Color(red: 0.09, green: 0.06, blue: 0.04), Color(red: 0.09, green: 0.06, blue: 0.04))
        }
        let inset: (CGFloat, CGFloat) = switch style {
        case .none: (0, 0)
        case .plain: (3, 3)
        case .white, .black: (6, 6)
        case .paper: (6, 16)
        case .negative: (4, 9)
        case .specs: (4, 14)
        }
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(style == .none ? Color.white.opacity(0.08) : colors.0)
            LinearGradient(colors: [Color(red: 0.45, green: 0.5, blue: 0.6), Color(red: 0.25, green: 0.22, blue: 0.2)],
                           startPoint: .top, endPoint: .bottom)
                .padding(.horizontal, inset.0)
                .padding(.top, style == .negative ? 9 : inset.0)
                .padding(.bottom, inset.1)
            if style == .none {
                Image(systemName: "nosign").foregroundStyle(.white.opacity(0.6))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// A labeled slider (caption, yellow slider, value), used inside the HSL, grading and crop sheets.
struct SliderRow: View {
    let title: String
    let value: Double
    var range: ClosedRange<Double> = 0...1
    var display: (Double) -> String = { "\(Int(($0 * 100).rounded()))" }
    let onChange: (Double) -> Void

    private var neutral: Double { range.lowerBound < 0 ? 0 : range.lowerBound }

    var body: some View {
        HStack(spacing: 10) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .tracking(0.8)
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 92, alignment: .leading)
                .onTapGesture(count: 2) { onChange(neutral) }
            Slider(value: Binding(get: { value }, set: onChange), in: range)
                .tint(.yellow)
                .accessibilityLabel(title)
                .accessibilityValue(display(value))
            Text(display(value))
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(value == neutral ? Color.white.opacity(0.6) : Color.yellow)
                .frame(width: 58, alignment: .trailing)
        }
    }
}

/// HSL: pick one of eight colors, then shift its hue, saturation and luminance.
private struct MixerSection: View {
    @Bindable var session: EditSession
    @State private var band: ColorBand = .red

    private func swatch(_ band: ColorBand) -> Color { Color(hue: band.hue / 360, saturation: 0.85, brightness: 0.95) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("HSL")
            HStack(spacing: 0) {
                ForEach(ColorBand.allCases) { item in
                    Button { band = item } label: {
                        Circle().fill(swatch(item)).frame(width: 24, height: 24)
                            .overlay(Circle().stroke(Color.white, lineWidth: band == item ? 2.5 : 0).padding(-4))
                            .frame(maxWidth: .infinity, minHeight: 40)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(item.label)
                    .accessibilityAddTraits(band == item ? .isSelected : [])
                }
            }
            ForEach(MixerChannel.allCases) { channel in
                SliderRow(title: channel.label, value: session.edit.mixer[band, channel], range: -1...1,
                          display: { $0 == 0 ? "0" : String(format: "%+d", Int(($0 * 100).rounded())) }) { v in
                    session.update { $0.mixer[band, channel] = v }
                }
            }
        }
    }
}

/// Color grading: a hue and amount for shadows and for highlights.
private struct GradeSection: View {
    @Bindable var session: EditSession

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Color Grading")
            SliderRow(title: "Shadow Hue", value: session.edit.gradeShadowHue, range: 0...360, display: { "\(Int($0))°" }) { v in
                session.update { $0.gradeShadowHue = v }
            }
            SliderRow(title: "Shadows", value: session.edit.gradeShadowAmount) { v in session.update { $0.gradeShadowAmount = v } }
            SliderRow(title: "Highlight Hue", value: session.edit.gradeHighlightHue, range: 0...360, display: { "\(Int($0))°" }) { v in
                session.update { $0.gradeHighlightHue = v }
            }
            SliderRow(title: "Highlights", value: session.edit.gradeHighlightAmount) { v in session.update { $0.gradeHighlightAmount = v } }
        }
    }
}

/// Crop: ratio presets (centered), quarter turns and straighten.
private struct CropSection: View {
    @Bindable var session: EditSession

    private let ratios: [(String, CGFloat?)] = [("ORIGINAL", nil), ("3:4", 3.0 / 4), ("4:5", 4.0 / 5), ("1:1", 1), ("9:16", 9.0 / 16),
                                                 ("4:3", 4.0 / 3), ("16:9", 16.0 / 9)]

    var body: some View {
        VStack(spacing: 14) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(ratios.indices, id: \.self) { index in
                        let item = ratios[index]
                        Button(item.0) {
                            var next = session.edit
                            next.cropRect = item.1.map { CropMath.centered(ratio: $0, imageSize: rotatedSize) } ?? EditState.fullCrop
                            session.replace(with: next)
                        }
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .frame(minHeight: 30)
                        .cameraGlass(.interactive, in: Capsule())
                    }
                }
            }
            HStack(spacing: 10) {
                Button {
                    var next = session.edit
                    next.rotation = (next.rotation + 1) % 4
                    next.cropRect = EditState.fullCrop
                    session.replace(with: next)
                } label: {
                    Label("Rotate", systemImage: "rotate.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 32)
                        .cameraGlass(.interactive, in: Capsule())
                }
                Spacer()
            }
            SliderRow(title: "Straighten", value: session.edit.straighten, range: -45...45,
                      display: { String(format: "%.1f°", $0) }) { v in session.update { $0.straighten = v } }
            SliderRow(title: "Move ↔", value: Double(session.edit.cropRect.midX), range: 0...1,
                      display: { String(format: "%.0f%%", $0 * 100) }) { v in move(x: v) }
                .disabled(session.edit.cropRect.width > 0.999)
            SliderRow(title: "Move ↕", value: Double(session.edit.cropRect.midY), range: 0...1,
                      display: { String(format: "%.0f%%", $0 * 100) }) { v in move(y: v) }
                .disabled(session.edit.cropRect.height > 0.999)
        }
    }

    /// The photo's size after its quarter turns (ratios are measured in pixels).
    private var rotatedSize: CGSize {
        guard let p = session.preview else { return CGSize(width: 3, height: 4) }
        return session.edit.rotation % 2 == 0 ? CGSize(width: p.width, height: p.height) : CGSize(width: p.height, height: p.width)
    }

    private func move(x: Double? = nil, y: Double? = nil) {
        session.update { edit in
            var r = edit.cropRect
            if let x { r.origin.x = min(max(CGFloat(x) - r.width / 2, 0), 1 - r.width) }
            if let y { r.origin.y = min(max(CGFloat(y) - r.height / 2, 0), 1 - r.height) }
            edit.cropRect = r
        }
    }
}

enum CropMath {
    /// Largest centered normalized crop with `ratio` (pixel width / height) inside an image of `imageSize`.
    static func centered(ratio: CGFloat, imageSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, ratio > 0 else { return EditState.fullCrop }
        let imageRatio = imageSize.width / imageSize.height
        let w = ratio < imageRatio ? ratio / imageRatio : 1
        let h = ratio < imageRatio ? 1 : imageRatio / ratio
        return CGRect(x: (1 - w) / 2, y: (1 - h) / 2, width: w, height: h)
    }
}

func sectionTitle(_ text: String) -> some View {
    Text(text.uppercased())
        .font(.caption.weight(.semibold))
        .tracking(1.1)
        .foregroundStyle(.white.opacity(0.9))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 6)
}

extension View {
    func appAlert(_ app: AppModel) -> some View {
        alert(app.alert?.title ?? "", isPresented: Binding(get: { app.alert != nil }, set: { if !$0 { app.alert = nil } }),
              presenting: app.alert) { _ in
            Button("OK", role: .cancel) {}
        } message: { alert in
            Text(alert.message)
        }
    }
}
