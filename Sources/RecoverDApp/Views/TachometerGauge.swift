import SwiftUI

/// A tachometer-style progress gauge — a quiet nod to Initial D's redline downhill runs. The
/// needle sweeps an RPM dial from idle (lower-left) to the redline (lower-right) as `fraction`
/// goes 0 → 1, so a finished scan ends "at redline". Purely cosmetic: it visualizes the same scan
/// fraction the old linear bar showed, with a digital readout in the center.
struct TachometerGauge: View {
    /// Scan progress, 0...1 — drives the needle.
    var fraction: Double
    /// Where the red zone begins on the dial (fraction of full sweep).
    var redline: Double = 0.8
    /// Digital readout in the dial center (e.g. "42%").
    var centerText: String
    /// Dimmed needle when the scan is paused/idle.
    var active: Bool = true

    private let startTop = 225.0   // needle angle (clockwise from 12 o'clock) at fraction 0
    private let sweep = 270.0      // total dial sweep in degrees
    private let dialRed = Color(red: 0.85, green: 0.06, blue: 0.12) // Initial-D red

    var body: some View {
        Canvas { ctx, size in
            let f = min(max(fraction, 0), 1)
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = min(size.width, size.height) / 2 - 12

            // Dial track + red zone.
            ctx.stroke(dialArc(center, radius, from: 0, to: 1),
                       with: .color(.secondary.opacity(0.25)),
                       style: StrokeStyle(lineWidth: 6, lineCap: .round))
            ctx.stroke(dialArc(center, radius, from: redline, to: 1),
                       with: .color(dialRed),
                       style: StrokeStyle(lineWidth: 6, lineCap: .round))

            // Major/minor ticks (9 majors: 0,1,…,8 ×1000 r/min) with numerals on the majors.
            for i in 0...16 {
                let tf = Double(i) / 16.0
                let major = i % 2 == 0
                let inRed = tf >= redline
                let outer = point(center, radius - 3, frac: tf)
                let inner = point(center, radius - (major ? 14 : 8), frac: tf)
                var tick = Path(); tick.move(to: outer); tick.addLine(to: inner)
                ctx.stroke(tick, with: .color(inRed ? dialRed : .secondary),
                           lineWidth: major ? 2 : 1)
                if major {
                    let n = i / 2
                    let label = ctx.resolve(
                        Text("\(n)").font(.system(size: 9, design: .rounded))
                            .foregroundStyle(inRed ? dialRed : .secondary))
                    ctx.draw(label, at: point(center, radius - 26, frac: tf))
                }
            }

            // Needle (+ short counterweight tail) and hub.
            let needleColor: Color = !active ? .secondary : (f >= redline ? dialRed : .primary)
            var needle = Path()
            needle.move(to: point(center, 18, angle: angle(f) + 180))
            needle.addLine(to: point(center, radius - 10, frac: f))
            ctx.stroke(needle, with: .color(needleColor),
                       style: StrokeStyle(lineWidth: 3, lineCap: .round))
            let hub = 7.0
            ctx.fill(Path(ellipseIn: CGRect(x: center.x - hub, y: center.y - hub,
                                            width: hub * 2, height: hub * 2)),
                     with: .color(.primary))
        }
        .overlay {
            VStack(spacing: 1) {
                Text(centerText)
                    .font(.system(.title3, design: .rounded)).bold().monospacedDigit()
                Text("×1000 r/min")
                    .font(.system(size: 8, design: .rounded))
                    .foregroundStyle(.tertiary)
            }
            .offset(y: 34)
        }
        .frame(width: 190, height: 190)
        .animation(.easeOut(duration: 0.4), value: fraction)
        .accessibilityLabel("Scan progress")
        .accessibilityValue(centerText)
    }

    // MARK: Geometry

    /// Degrees clockwise from 12 o'clock for a given progress fraction.
    private func angle(_ f: Double) -> Double { startTop + min(max(f, 0), 1) * sweep }

    /// A point on the dial at `frac` of the sweep, `radius` from center.
    private func point(_ c: CGPoint, _ radius: CGFloat, frac: Double) -> CGPoint {
        point(c, radius, angle: angle(frac))
    }

    /// A point at an absolute angle (degrees, clockwise from 12 o'clock).
    private func point(_ c: CGPoint, _ radius: CGFloat, angle deg: Double) -> CGPoint {
        let r = deg * .pi / 180
        return CGPoint(x: c.x + radius * sin(r), y: c.y - radius * cos(r))
    }

    /// A polyline arc following the dial between two fractions.
    private func dialArc(_ c: CGPoint, _ radius: CGFloat, from f0: Double, to f1: Double) -> Path {
        var p = Path()
        let steps = 72
        for i in 0...steps {
            let f = f0 + (f1 - f0) * Double(i) / Double(steps)
            let pt = point(c, radius, frac: f)
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        return p
    }
}
