import CoreMotion
import Foundation
import Observation

/// Reads the phone's sideways tilt from the accelerometer/gyro (CoreMotion device motion).
/// Drives the level guide and turns the camera icons upright in landscape, like the Camera app.
/// Device motion needs no permission prompt. Without it (the Simulator) everything stays upright and level.
@MainActor
@Observable
final class MotionLevel {
    /// Rotation of the phone around the screen's axis, in radians. 0 = upright portrait.
    private(set) var angle: Double = 0
    /// False while the phone lies flat (face up/down), where sideways tilt is meaningless.
    private(set) var isUpright = true
    private(set) var isTracking = false
    /// How far icons are turned so they read upright: 0 (portrait), 90 or -90 (landscape), in degrees.
    private(set) var iconRotation: Double = 0

    private let manager = CMMotionManager()

    /// Within this many radians the guide snaps to level and turns yellow (~1°).
    nonisolated static let levelTolerance = 1.0 * .pi / 180

    /// Tilt measured against the current orientation's horizon (portrait or landscape).
    var levelAngle: Double { angle + iconRotation * .pi / 180 }

    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 30
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let gravity = motion?.gravity else { return }
            MainActor.assumeIsolated {
                self?.update(gx: gravity.x, gy: gravity.y, gz: gravity.z)
            }
        }
        isTracking = true
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
        isTracking = false
        angle = 0
        iconRotation = 0
    }

    private func update(gx: Double, gy: Double, gz: Double) {
        // Assign only on change: every write notifies observers, even with the same value.
        let upright = abs(gz) < 0.85
        if upright != isUpright { isUpright = upright }
        let raw = Self.roll(gx: gx, gy: gy)
        let smoothed = angle + (raw - angle) * 0.25 // light smoothing so the line doesn't jitter
        if abs(smoothed - angle) > 0.0005 { angle = smoothed } // ~0.03°, below what the guide can show
        if upright {
            let rotation = Self.nextIconRotation(current: iconRotation, rollDegrees: raw * 180 / .pi)
            if rotation != iconRotation { iconRotation = rotation }
        }
    }

    /// Sideways tilt for a portrait phone: 0 when gravity points straight down the screen.
    nonisolated static func roll(gx: Double, gy: Double) -> Double {
        atan2(gx, -gy)
    }

    nonisolated static func isLevel(_ angle: Double) -> Bool {
        abs(angle) <= levelTolerance
    }

    /// Portrait ↔ landscape icon rotation with hysteresis (switch past 55°, return under 35°)
    /// so icons don't flicker around 45°. Upside-down keeps the current rotation.
    nonisolated static func nextIconRotation(current: Double, rollDegrees: Double) -> Double {
        if rollDegrees < -55 && rollDegrees > -125 { return 90 }
        if rollDegrees > 55 && rollDegrees < 125 { return -90 }
        if abs(rollDegrees) < 35 { return 0 }
        return current
    }
}
