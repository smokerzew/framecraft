import SwiftUI

@main
struct FrameCraftApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

/// The camera, with the editor over it while a photo is open.
struct RootView: View {
    @State private var app = AppModel()
    @State private var motion = MotionLevel()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        ZStack {
            CameraScreen(app: app, motion: motion)
            if let session = app.session {
                EditorView(app: app, session: session)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom))
                    .zIndex(1)
            }
        }
        .animation(reduceMotion ? nil : .spring(duration: 0.4), value: app.session == nil)
        .environment(\.colorScheme, .dark)
        .environment(\.cameraReduceMotion, reduceMotion)
        .environment(\.cameraHighContrast, contrast == .increased)
        .environment(\.cameraIconRotation, motion.iconRotation)
        .statusBarHidden()
        .sheet(isPresented: $app.showLibrary) { LibraryView(app: app) }
        .appAlert(app)
        .task { app.startUp() }
        .onAppear { motion.start() }
        .onDisappear { motion.stop() }
        .onChange(of: scenePhase) { _, phase in app.sceneActive(phase == .active) }
    }
}
