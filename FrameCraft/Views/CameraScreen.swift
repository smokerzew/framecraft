import PhotosUI
import SwiftUI

/// The camera, laid out like Camera Glass Pro (iOS Camera style): status icons over the top of the viewfinder,
/// zoom + LOOK + shutter + ⠿ over its bottom, and a black bar with the library thumbnail, the mode capsule and
/// the camera switch.
struct CameraScreen: View {
    @Bindable var app: AppModel
    let motion: MotionLevel
    @Environment(\.cameraReduceMotion) private var reduceMotion
    @State private var pickerItems: [PhotosPickerItem] = []

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                ZStack(alignment: .topLeading) {
                    GeometryReader { proxy in
                        LiveViewfinderView(app: app, motion: motion, size: proxy.size)
                    }
                    VStack(spacing: 0) {
                        StatusRow(app: app)
                        Spacer(minLength: 0)
                        ShutterControls(app: app)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()

                BottomBar(app: app)
            }

            if app.isPopUpOpen {
                Color.black.opacity(0.001)
                    .ignoresSafeArea()
                    .onTapGesture { withAnimation(reduceMotion ? nil : .spring(duration: 0.35)) { app.closePopUps() } }
                    .accessibilityHidden(true)
                    .zIndex(0.5)
            }

            ZStack(alignment: .bottom) {
                if app.showLookPicker {
                    LookPicker(app: app).padding(.bottom, 6)
                        .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                }
                if app.showManualControls {
                    ManualControlsView(app: app).padding(.bottom, 6)
                        .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                }
                if app.isControlPanelOpen {
                    ControlPanel(app: app).padding(.bottom, 6)
                        .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                }
            }
            .zIndex(1)

            if let seconds = app.countdown {
                Text("\(seconds)")
                    .font(.system(size: 96, weight: .light).monospacedDigit())
                    .foregroundStyle(.white)
                    .shadow(radius: 6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
                    .zIndex(2)
            }

            if let toast = app.toast {
                VStack {
                    Text(toast)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .frame(minHeight: 38)
                        .cameraGlass(.regular, in: Capsule())
                        .padding(.top, 12)
                    Spacer()
                }
                .allowsHitTesting(false)
                .zIndex(4)
            }
        }
        .photosPicker(isPresented: $app.showPhotosPicker, selection: $pickerItems, maxSelectionCount: 20,
                      selectionBehavior: .ordered, matching: .images, preferredItemEncoding: .current)
        .onChange(of: pickerItems) { _, items in
            guard !items.isEmpty else { return }
            app.importPhotos(items)
            pickerItems = []
        }
        .animation(reduceMotion ? nil : .spring(duration: 0.4, bounce: 0.18), value: app.isControlPanelOpen)
        .animation(reduceMotion ? nil : .spring(duration: 0.4, bounce: 0.18), value: app.showLookPicker)
        .animation(reduceMotion ? nil : .spring(duration: 0.4, bounce: 0.18), value: app.showManualControls)
        .sensoryFeedback(.impact(weight: .light), trigger: app.flashPulse)
        .sensoryFeedback(.selection, trigger: app.mode)
    }
}

/// Centered row of plain status icons over the top of the viewfinder: flash, scan, EV and the look.
private struct StatusRow: View {
    @Bindable var app: AppModel

    var body: some View {
        HStack(spacing: 22) {
            item(app.flash.systemImage, active: app.flash != .off, label: "Flash", value: app.flash.label) {
                app.perform(.flash)
            }
            .disabled(!app.isAvailable(.flash))
            .opacity(app.isAvailable(.flash) ? 1 : 0.4)

            item("viewfinder", active: app.camera.isCoaching, label: "Auto frame", value: app.camera.isCoaching ? "On" : "Off") {
                app.perform(.scan)
            }
            .disabled(!app.camera.isRunning)

            Button {
                app.isExposureDialVisible = true
                app.isControlPanelOpen = true
            } label: {
                VStack(spacing: -1) {
                    Text(String(format: "%.1f", app.camera.exposureBias)).font(.system(size: 15, weight: .semibold).monospacedDigit())
                    Text("EV").font(.system(size: 8, weight: .semibold))
                }
                .foregroundStyle(app.camera.exposureBias != 0 ? Color.yellow : .white)
                .rotatesWithDevice()
                .frame(minWidth: 36, minHeight: 36)
                .contentShape(Rectangle())
            }
            .accessibilityLabel("Exposure")
            .accessibilityValue(String(format: "%+.1f EV", app.camera.exposureBias))

            item("square.3.layers.3d", active: app.look != .none, label: "Look", value: app.look.label) {
                app.closePopUps()
                app.showLookPicker = true
            }
        }
        .buttonStyle(PressableButtonStyle())
        .shadow(color: .black.opacity(0.45), radius: 2)
        .padding(.top, 10)
    }

    private func item(_ symbol: String, active: Bool, label: String, value: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(active ? Color.yellow : .white)
                .rotatesWithDevice()
                .frame(minWidth: 36, minHeight: 36)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(label)
        .accessibilityValue(value)
    }
}

/// Composition notes, zoom row, LOOK button, shutter and ⠿ floating over the bottom of the viewfinder.
private struct ShutterControls: View {
    @Bindable var app: AppModel
    @Environment(\.cameraReduceMotion) private var reduceMotion
    @State private var dialStartZoom: CGFloat?

    var body: some View {
        VStack(spacing: 14) {
            LiveCompositionArea(app: app)

            if app.camera.isRunning {
                zoomArea
            }

            HStack {
                RingedCircleButton(isActive: app.look != .none, label: "Looks", value: app.look.label,
                                   hint: "Film looks, previewed live and applied to the photo") {
                    app.closePopUps()
                    app.showLookPicker = true
                } content: {
                    Image(systemName: "camera.filters").font(.system(size: 18, weight: .medium))
                }

                Spacer()
                ShutterButton(app: app)
                Spacer()

                RingedCircleButton(isActive: app.isControlPanelOpen, label: "More controls",
                                   value: app.isControlPanelOpen ? "Expanded" : "Collapsed",
                                   hint: "Flash, timer, aspect, exposure, grid, scan, custom frame, manual and RAW") {
                    withAnimation(reduceMotion ? nil : .spring(duration: 0.4, bounce: 0.18)) {
                        app.isExposureDialVisible = false
                        let open = !app.isControlPanelOpen
                        app.closePopUps()
                        app.isControlPanelOpen = open
                    }
                } content: {
                    SixDotGlyph()
                }
            }
            .padding(.horizontal, 32)
        }
        .padding(.bottom, 14)
    }

    private var zoomArea: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottom) {
                if app.isZoomDialVisible {
                    ZoomDial(zoom: app.zoom)
                        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottom)))
                } else {
                    ZoomSelector(zoom: app.zoom, presets: app.zoomPresets,
                                 onSelect: { preset in
                                     withAnimation(reduceMotion ? nil : .spring(duration: 0.35, bounce: 0.12)) { app.setZoom(preset) }
                                 },
                                 onToggleSlider: { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { app.showZoomDial() } })
                        .transition(.opacity)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .bottom)
            .contentShape(Rectangle())
            .simultaneousGesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { value in
                        let start = dialStartZoom ?? app.zoom
                        dialStartZoom = start
                        if !app.isZoomDialVisible {
                            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { app.showZoomDial() }
                        } else {
                            app.showZoomDial()
                        }
                        app.setZoom(ZoomDial.zoom(from: start, dragDistance: value.translation.width, radius: proxy.size.width * 0.95))
                    }
                    .onEnded { _ in dialStartZoom = nil }
            )
        }
        .frame(height: app.isZoomDialVisible ? 86 : 44)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: app.isZoomDialVisible)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Zoom")
        .accessibilityValue("\(ZoomLimits.label(for: app.zoom)) times")
    }
}

/// Black bar under the viewfinder: library thumbnail, mode capsule, camera switch.
private struct BottomBar: View {
    @Bindable var app: AppModel
    @Environment(\.cameraReduceMotion) private var reduceMotion
    @State private var isSlidingModes = false

    private let sideButtonSize: CGFloat = 50
    private let horizontalPadding: CGFloat = 20

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                CameraModeSelector(selection: $app.mode, isInteracting: $isSlidingModes,
                                   collapsedWidth: max(160, proxy.size.width - 2 * (horizontalPadding + sideButtonSize + 12))) {
                    withAnimation(.spring(duration: 0.4, bounce: 0.18)) { app.isControlPanelOpen = true }
                }
                .onChange(of: app.mode) { app.modeChanged() }

                HStack(spacing: 12) {
                    Button { app.refreshProjects(); app.showLibrary = true } label: {
                        Group {
                            if let image = app.latestThumbnail {
                                Image(decorative: image, scale: 1).resizable().scaledToFill()
                            } else {
                                Color.white.opacity(0.08)
                            }
                        }
                        .rotatesWithDevice()
                        .frame(width: 50, height: 50)
                        .clipShape(Circle())
                        .cameraGlass(.regular, in: Circle())
                    }
                    .buttonStyle(PressableButtonStyle())
                    .accessibilityLabel("Library")
                    .accessibilityValue("\(app.projects.count) photos")
                    .accessibilityHint("Your photos and their edits")

                    Spacer(minLength: 0)

                    GlassIconButton(systemImage: "arrow.triangle.2.circlepath", label: "Switch camera",
                                    hint: "Front or back camera", size: sideButtonSize) {
                        Task {
                            await app.camera.flip()
                            app.setZoom(1)
                        }
                    }
                    .disabled(!app.camera.capabilities.canFlip)
                }
                .padding(.horizontal, horizontalPadding)
                .opacity(isSlidingModes ? 0 : 1)
                .scaleEffect(isSlidingModes && !reduceMotion ? 0.85 : 1)
                .allowsHitTesting(!isSlidingModes)
                .animation(reduceMotion ? nil : .spring(duration: 0.35, bounce: 0.1), value: isSlidingModes)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .frame(height: 70)
    }
}

/// Dark glass circle that gains a yellow ring and glyph when active.
struct RingedCircleButton<Content: View>: View {
    let isActive: Bool
    let label: String
    var value: String = ""
    var hint: String = ""
    let action: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        Button(action: action) {
            content
                .foregroundStyle(isActive ? Color.yellow : .white)
                .rotatesWithDevice()
                .frame(width: 48, height: 48)
                .overlay { if isActive { Circle().strokeBorder(.yellow, lineWidth: 1.5) } }
                .contentShape(Circle())
        }
        .buttonStyle(PressableButtonStyle())
        .cameraGlass(.interactive, in: Circle())
        .accessibilityLabel(label)
        .accessibilityValue(value)
        .accessibilityHint(hint)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

/// 3×2 dot grid of the "more controls" button.
struct SixDotGlyph: View {
    var body: some View {
        VStack(spacing: 3.5) {
            ForEach(0..<2, id: \.self) { _ in
                HStack(spacing: 3.5) {
                    ForEach(0..<3, id: \.self) { _ in Circle().frame(width: 4.5, height: 4.5) }
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// The shutter. Touch and hold to import from Photos instead.
private struct ShutterButton: View {
    @Bindable var app: AppModel

    var body: some View {
        let busy = app.camera.isCapturing || app.isSaving
        Button { app.shutterPressed() } label: {
            ZStack {
                Circle().strokeBorder(Color.black.opacity(0.35), lineWidth: 5).frame(width: 82, height: 82)
                Circle().strokeBorder(.white.opacity(0.9), lineWidth: 3).frame(width: 82, height: 82)
                Circle().fill(.white).frame(width: busy ? 60 : 68, height: busy ? 60 : 68).opacity(busy ? 0.6 : 1)
                if app.countdown != nil {
                    Image(systemName: "xmark").font(.system(size: 22, weight: .semibold)).foregroundStyle(.black.opacity(0.55))
                }
            }
            .frame(width: 88, height: 88)
            .contentShape(Circle())
        }
        .buttonStyle(PressableButtonStyle())
        .disabled(!app.camera.isRunning)
        .contextMenu {
            Button("Import from Photos", systemImage: "photo.on.rectangle") { app.showPhotosPicker = true }
        }
        .accessibilityLabel(app.countdown != nil ? "Cancel timer" : "Take photo")
        .accessibilityHint("Touch and hold to import a photo instead.")
        .animation(.spring(duration: 0.25), value: busy)
    }
}

/// Small label over the viewfinder (yellow, or white for "off" and neutral states).
struct CameraTag: View {
    let text: String
    var isOff = false

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .tracking(0.4)
            .foregroundStyle(.black)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(isOff ? Color.white : Color.yellow, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}
