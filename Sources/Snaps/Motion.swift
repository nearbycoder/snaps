import SwiftUI

/// Durations and curves from transitions.dev. Pick a token by what is moving, not by the closest number.
enum Motion {
    /// Closing small surfaces, swapping text.
    static let quick: Double = 0.15
    /// Opening small surfaces, swapping icons, sliding a selection.
    static let fast: Double = 0.25

    /// The default curve for anything that opens, closes or changes position.
    static func smoothOut(_ duration: Double) -> Animation {
        .timingCurve(0.22, 1, 0.36, 1, duration: duration)
    }

    /// A glass pill that pops in and fades out faster than it came. Reduce Motion keeps only the fade.
    static func pill(reduceMotion: Bool) -> AnyTransition {
        let insertion: AnyTransition = reduceMotion ? .opacity : .scale(scale: 0.96).combined(with: .opacity)
        return .asymmetric(
            insertion: insertion.animation(smoothOut(fast)),
            removal: .opacity.animation(.easeOut(duration: quick))
        )
    }
}
