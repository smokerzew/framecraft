import SwiftUI

/// The app's small set of glass treatments. Kept deliberately short for visual consistency.
enum GlassStyle {
    /// Static chrome: toolbars, pills.
    case regular
    /// Tappable controls; reacts to touch on iOS 26.
    case interactive
    /// Light-touch surfaces over the photo (badges).
    case subtle
    /// The currently selected control.
    case selected
}

/// Native Liquid Glass on iOS 26+, a material-based fallback on iOS 18–25,
/// and a solid treatment when Reduce Transparency or the "Solid" control style is on.
struct CameraGlassModifier<S: InsettableShape>: ViewModifier {
    var style: GlassStyle
    let shape: S

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.cameraHighContrast) private var highContrast
    @AppStorage(SettingsKey.controlStyle) private var controlStyle = ControlStyle.glass

    func body(content: Content) -> some View {
        if reduceTransparency || controlStyle == .solid {
            solid(content)
        } else {
            #if compiler(>=6.2) // iOS 26 SDK (Xcode 26) is required to reference Liquid Glass APIs
            if #available(iOS 26.0, *) {
                content
                    .glassEffect(nativeGlass, in: shape)
                    .overlay {
                        if highContrast { shape.strokeBorder(.white.opacity(0.45), lineWidth: 1) }
                    }
            } else {
                materialFallback(content)
            }
            #else
            materialFallback(content)
            #endif
        }
    }

    #if compiler(>=6.2)
    @available(iOS 26.0, *)
    private var nativeGlass: Glass {
        switch style {
        case .regular: .regular
        case .interactive: .regular.interactive()
        case .subtle: .clear
        case .selected: .regular.tint(.white.opacity(0.18)).interactive()
        }
    }
    #endif

    private func materialFallback(_ content: Content) -> some View {
        content
            .background {
                ZStack {
                    shape.fill(style == .subtle ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(.thinMaterial))
                    if style == .selected { shape.fill(.white.opacity(0.14)) }
                }
            }
            .overlay {
                // Fine border plus a soft specular edge along the top.
                shape.strokeBorder(.white.opacity(highContrast ? 0.5 : 0.16), lineWidth: 0.8)
                shape.strokeBorder(
                    LinearGradient(colors: [.white.opacity(0.35), .clear], startPoint: .top, endPoint: .center),
                    lineWidth: 0.8
                )
            }
            .shadow(color: .black.opacity(0.22), radius: 10, y: 4)
    }

    private func solid(_ content: Content) -> some View {
        content
            .background(Color(white: style == .selected ? 0.28 : 0.13), in: shape)
            .overlay { shape.strokeBorder(.white.opacity(highContrast ? 0.6 : 0.18), lineWidth: 1) }
    }
}

extension View {
    func cameraGlass<S: InsettableShape>(_ style: GlassStyle = .regular, in shape: S) -> some View {
        modifier(CameraGlassModifier(style: style, shape: shape))
            // The whole glass shape takes taps, not just the label's text (glass alone isn't hit-tested).
            .contentShape(shape)
    }
}

/// Groups related glass elements so iOS 26 can blend and morph them together.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 12
    @ViewBuilder var content: Content

    var body: some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
        #else
        content
        #endif
    }
}

/// Glass sheet background on iOS 26 (system default), a material on earlier systems.
struct GlassSheetBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
        } else {
            content.presentationBackground(.regularMaterial)
        }
    }
}
