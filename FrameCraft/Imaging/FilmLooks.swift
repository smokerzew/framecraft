import CoreGraphics
import Foundation

/// FrameCraft's own film-inspired looks. Names and values are original; each one is a starting point that
/// the editor can adjust further (Strength, then every other slider).
enum FilmLook: String, CaseIterable, Codable, Identifiable, Sendable {
    case none
    case daylightNeg, ember200, coldChrome, softBloom, push1600, silverTone
    case sunFaded, paperSepia, deepPrint, quietCinema, goldenSplit, clean

    var id: String { rawValue }

    var label: String { recipe?.label ?? "Original" }

    /// What it's modeled on, in plain words (shown under the look).
    var summary: String {
        switch self {
        case .none: "No look"
        case .daylightNeg: "Natural color negative"
        case .ember200: "Warm negative"
        case .coldChrome: "Cool slide film"
        case .softBloom: "Soft portrait tones"
        case .push1600: "Fast film, pushed, grainy"
        case .silverTone: "Neutral black and white"
        case .sunFaded: "Faded print"
        case .paperSepia: "Vintage paper"
        case .deepPrint: "Rich contrast"
        case .quietCinema: "Muted cinematic color"
        case .goldenSplit: "Warm highlights, cool shadows"
        case .clean: "Clean, neutral starting point"
        }
    }

    var recipe: LookRecipe? {
        switch self {
        case .none: nil
        case .daylightNeg:
            LookRecipe("Daylight Neg", temperature: 120, curve: [(0, 0.02), (0.25, 0.24), (0.5, 0.5), (0.75, 0.77), (1, 0.985)],
                       saturation: 1.04, shadows: (0, 0.004, 0.006), highlights: (0.008, 0.004, 0), grain: 0.2)
        case .ember200:
            LookRecipe("Ember 200", temperature: 420, curve: [(0, 0.03), (0.25, 0.25), (0.5, 0.52), (0.75, 0.78), (1, 0.97)],
                       saturation: 1.06, shadows: (0.006, 0.002, -0.004), highlights: (0.02, 0.01, -0.008), grain: 0.25)
        case .coldChrome:
            LookRecipe("Cold Chrome", temperature: -260, curve: [(0, 0), (0.25, 0.2), (0.5, 0.5), (0.75, 0.81), (1, 1)],
                       saturation: 1.12, vibrance: 0.15, shadows: (-0.006, 0.002, 0.016), clarity: 0.15)
        case .softBloom:
            LookRecipe("Soft Bloom", exposure: 0.05, temperature: 150, curve: [(0, 0.03), (0.25, 0.255), (0.5, 0.52), (0.75, 0.77), (1, 0.98)],
                       saturation: 0.94, highlights: (0.008, 0.004, 0.002), glow: 0.2)
        case .push1600:
            LookRecipe("Push 1600", exposure: 0.05, curve: [(0, 0.03), (0.25, 0.21), (0.5, 0.5), (0.75, 0.8), (1, 0.98)],
                       saturation: 0.9, shadows: (-0.004, 0.006, 0.01), grain: 0.6, halation: 0.25)
        case .silverTone:
            LookRecipe("Silver Tone", mono: (0.3, 0.59, 0.11), curve: [(0, 0.015), (0.25, 0.23), (0.5, 0.5), (0.75, 0.78), (1, 0.99)],
                       grain: 0.3)
        case .sunFaded:
            LookRecipe("Sun Faded", temperature: 350, curve: [(0, 0.07), (0.25, 0.27), (0.5, 0.51), (0.75, 0.75), (1, 0.95)],
                       saturation: 0.82, highlights: (0.014, 0.008, -0.004), grain: 0.2)
        case .paperSepia:
            LookRecipe("Paper Sepia", mono: (0.3, 0.59, 0.11), curve: [(0, 0.06), (0.25, 0.27), (0.5, 0.52), (0.75, 0.76), (1, 0.93)],
                       shadows: (0.02, 0.008, -0.01), highlights: (0.03, 0.018, -0.008), grain: 0.25)
        case .deepPrint:
            LookRecipe("Deep Print", curve: [(0, 0), (0.25, 0.18), (0.5, 0.5), (0.75, 0.83), (1, 1)],
                       saturation: 1.12, vibrance: 0.15, clarity: 0.2)
        case .quietCinema:
            LookRecipe("Quiet Cinema", exposure: -0.05, temperature: -80, curve: [(0, 0.03), (0.25, 0.22), (0.5, 0.49), (0.75, 0.77), (1, 0.97)],
                       saturation: 0.78, shadows: (-0.006, 0.004, 0.012), highlights: (0.008, 0.006, 0), halation: 0.2)
        case .goldenSplit:
            LookRecipe("Golden Split", curve: [(0, 0.01), (0.25, 0.225), (0.5, 0.5), (0.75, 0.785), (1, 0.99)],
                       saturation: 1.02, shadows: (-0.012, 0.002, 0.02), highlights: (0.022, 0.01, -0.012))
        case .clean:
            LookRecipe("Clean", curve: [(0, 0), (0.25, 0.235), (0.5, 0.5), (0.75, 0.77), (1, 1)], saturation: 1.02)
        }
    }
}

/// The ingredients of a look, all rendered by `PhotoRenderer.renderLook`.
struct LookRecipe {
    let label: String
    var exposure: Double = 0
    /// Warmer (+) or cooler (−) white balance shift, in kelvin.
    var temperature: CGFloat = 0
    /// Black and white with these channel weights.
    var mono: (CGFloat, CGFloat, CGFloat)?
    /// Five-point tone curve (x, y in 0...1).
    var curve: [(CGFloat, CGFloat)]
    var saturation: Double = 1
    var vibrance: Double = 0
    /// Split toning: tint added to shadows (fading out toward pure black) and to highlights.
    var shadows: (CGFloat, CGFloat, CGFloat) = (0, 0, 0)
    var highlights: (CGFloat, CGFloat, CGFloat) = (0, 0, 0)
    var glow: Double = 0
    var clarity: Double = 0
    /// The film's own texture (scaled by the look's strength; the Grain and Halation sliders add to it).
    var grain: Double = 0
    var halation: Double = 0

    init(_ label: String, exposure: Double = 0, temperature: CGFloat = 0, mono: (CGFloat, CGFloat, CGFloat)? = nil,
         curve: [(CGFloat, CGFloat)], saturation: Double = 1, vibrance: Double = 0,
         shadows: (CGFloat, CGFloat, CGFloat) = (0, 0, 0), highlights: (CGFloat, CGFloat, CGFloat) = (0, 0, 0),
         glow: Double = 0, clarity: Double = 0, grain: Double = 0, halation: Double = 0) {
        self.label = label
        self.exposure = exposure
        self.temperature = temperature
        self.mono = mono
        self.curve = curve
        self.saturation = saturation
        self.vibrance = vibrance
        self.shadows = shadows
        self.highlights = highlights
        self.glow = glow
        self.clarity = clarity
        self.grain = grain
        self.halation = halation
    }
}
