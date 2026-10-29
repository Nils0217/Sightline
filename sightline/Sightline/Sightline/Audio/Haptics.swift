// labels: production, needs-review
// Haptic cues (2026-10-29 blindfold test: "I don't know what the screen wants me to do").
// Every tap gets one at once, before any speech, so the user knows it registered.

import UIKit

enum Haptics {
    private static let light = UIImpactFeedbackGenerator(style: .light)
    private static let heavy = UIImpactFeedbackGenerator(style: .heavy)
    private static let note = UINotificationFeedbackGenerator()

    /// A tap was registered.
    static func tap() { light.impactOccurred() }
    /// Long press: reset.
    static func reset() { heavy.impactOccurred() }
    /// Found it / got it.
    static func success() { note.notificationOccurred(.success) }
    /// Not found / not the right object / stopped.
    static func warning() { note.notificationOccurred(.warning) }
}
