import SwiftUI

/// FRIDAY's visual presence.
///
/// Two implementations behind one view, for a measured reason. `Canvas` driven
/// by `TimelineView` redraws on the CPU every tick — around 30% CPU unthrottled,
/// roughly 14% throttled — which cannot meet a sub-5% idle budget. Implicit
/// SwiftUI animation is handed to the render server instead and costs the app
/// almost nothing.
///
/// So: at rest the orb breathes with implicit animation and no Canvas exists.
/// The Canvas is created only while listening, thinking or speaking, and is
/// torn down on the way back to idle.
struct OrbView: View {
    var state: FridayState
    /// Live mic level, 0…1.
    var level: Float
    var diameter: CGFloat = 104

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathing = false

    private var accent: Color {
        switch state {
        case .idle: FridayTheme.textPrimary
        case .listening, .speaking: FridayTheme.amber
        case .thinking: FridayTheme.amberLight
        case .error: FridayTheme.fault
        }
    }

    private var isActive: Bool {
        switch state {
        case .listening, .thinking, .speaking: true
        case .idle, .error: false
        }
    }

    var body: some View {
        ZStack {
            // Always present, always cheap.
            restingCore

            // Exists only while something is happening.
            if isActive, !reduceMotion {
                ActiveOrbCanvas(state: state, level: level, accent: accent)
                    .frame(width: diameter, height: diameter)
                    .transition(.opacity)
            }
        }
        .frame(width: diameter, height: diameter)
        // "Listening: expands, reacts to live mic amplitude."
        .scaleEffect(listeningScale)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: level)
        .animation(.easeInOut(duration: 0.3), value: isActive)
        .animation(.easeInOut(duration: 0.3), value: accent)
        .onAppear { breathing = true }
    }

    private var listeningScale: CGFloat {
        guard case .listening = state, !reduceMotion else { return 1 }
        return 1 + CGFloat(level) * 0.14
    }

    private var restingCore: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [accent.opacity(0.34), accent.opacity(0.04)],
                        center: .center,
                        startRadius: 1,
                        endRadius: diameter * 0.6
                    )
                )

            Circle()
                .strokeBorder(accent.opacity(0.5), lineWidth: 1.5)
        }
        // A single implicit repeatForever — no per-frame CPU work.
        .scaleEffect(breathing && !reduceMotion ? 1.0 : 0.94)
        .opacity(breathing && !reduceMotion ? 1.0 : 0.82)
        .animation(
            reduceMotion ? nil : .easeInOut(duration: 2.6).repeatForever(autoreverses: true),
            value: breathing
        )
    }
}

/// The expensive half. Only ever instantiated while the orb is active.
private struct ActiveOrbCanvas: View {
    var state: FridayState
    var level: Float
    var accent: Color

    var body: some View {
        // 30 fps is plenty for this motion and halves the redraw cost against
        // an unthrottled schedule.
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            Canvas { context, size in
                let time = timeline.date.timeIntervalSinceReferenceDate
                let centre = CGPoint(x: size.width / 2, y: size.height / 2)
                let radius = min(size.width, size.height) / 2

                draw(in: &context, centre: centre, radius: radius, time: time)
            }
        }
        .allowsHitTesting(false)
    }

    private func draw(in context: inout GraphicsContext, centre: CGPoint, radius: CGFloat, time: TimeInterval) {
        switch state {
        case .listening:
            // Amplitude ring — reacts to the voice, not to a canned curve.
            let reactive = radius * (0.55 + CGFloat(level) * 0.42)
            strokeCircle(&context, centre: centre, radius: reactive,
                         color: accent.opacity(0.75), width: 2)
            strokeCircle(&context, centre: centre, radius: reactive * 0.72,
                         color: accent.opacity(0.35), width: 1)

        case .thinking:
            // Two arcs at different speeds — internal motion, going somewhere.
            for index in 0..<2 {
                let speed = index == 0 ? 1.4 : -0.9
                let sweep = index == 0 ? 0.55 : 0.35
                arc(&context, centre: centre,
                    radius: radius * (index == 0 ? 0.78 : 0.58),
                    start: time * speed,
                    sweep: sweep,
                    color: accent.opacity(index == 0 ? 0.85 : 0.5),
                    width: index == 0 ? 2.5 : 1.5)
            }

        case .speaking:
            // Steady pulse, independent of the mic.
            let pulse = 0.62 + 0.12 * sin(time * 5.2)
            strokeCircle(&context, centre: centre, radius: radius * pulse,
                         color: accent.opacity(0.7), width: 2)

        case .idle, .error:
            break
        }
    }

    private func strokeCircle(_ context: inout GraphicsContext, centre: CGPoint,
                              radius: CGFloat, color: Color, width: CGFloat) {
        let rect = CGRect(x: centre.x - radius, y: centre.y - radius,
                          width: radius * 2, height: radius * 2)
        context.stroke(Path(ellipseIn: rect), with: .color(color), lineWidth: width)
    }

    private func arc(_ context: inout GraphicsContext, centre: CGPoint, radius: CGFloat,
                     start: Double, sweep: Double, color: Color, width: CGFloat) {
        var path = Path()
        path.addArc(
            center: centre,
            radius: radius,
            startAngle: .radians(start),
            endAngle: .radians(start + sweep * 2 * .pi),
            clockwise: false
        )
        context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round))
    }
}
