import AppKit

/// The menu bar mark: a little robot-faced chat bubble with nudge marks either side. The bubble is
/// a solid visor with its eyes cut out, drawn in code as a template image, so macOS tints it for
/// light and dark menu bars.
enum NudgeIcon {
    enum Mood {
        case calm       // waiting for the next nudge
        case awake      // Keep Awake is on: eyes wide open
        case happy      // sending: ^ ^
    }

    /// shake: horizontal offset in points (the bubble jiggles while a nudge is sending).
    static func image(mood: Mood = .calm, shake: CGFloat = 0) -> NSImage {
        let size = NSSize(width: 24, height: 16)
        let img = NSImage(size: size, flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current else { return false }
            NSColor.black.set()
            let cx: CGFloat = 12 + shake, cy: CGFloat = 8.6

            // Visor, with a speech-bubble tail at the bottom left.
            NSBezierPath(roundedRect: NSRect(x: cx - 6, y: cy - 4.6, width: 12, height: 9.2), xRadius: 3.6, yRadius: 3.6).fill()
            let tail = NSBezierPath()
            tail.move(to: NSPoint(x: cx - 4.2, y: cy - 4.2))
            tail.line(to: NSPoint(x: cx - 5.6, y: cy - 7.4))
            tail.line(to: NSPoint(x: cx - 1.2, y: cy - 4.2))
            tail.close()
            tail.fill()

            // Eyes: cut out of the visor so they show the menu bar through it.
            ctx.compositingOperation = .destinationOut
            let gap: CGFloat = 2.5
            for side in [-1.0, 1.0] as [CGFloat] {
                let ex = cx + side * gap
                switch mood {
                case .calm:
                    NSBezierPath(roundedRect: NSRect(x: ex - 0.95, y: cy - 1.9, width: 1.9, height: 3.8), xRadius: 0.95, yRadius: 0.95).fill()
                case .awake:
                    NSBezierPath(ovalIn: NSRect(x: ex - 1.5, y: cy - 1.9, width: 3.0, height: 3.8)).fill()
                case .happy:
                    let arc = NSBezierPath()
                    arc.appendArc(withCenter: NSPoint(x: ex, y: cy - 1.0), radius: 1.4, startAngle: 20, endAngle: 160)
                    arc.lineWidth = 1.2
                    arc.lineCapStyle = .round
                    arc.stroke()
                }
            }
            ctx.compositingOperation = .sourceOver

            // Nudge marks: two short arcs each side. They stay put while the visor jiggles.
            for (radius, width) in [(CGFloat(8.4), CGFloat(1.4)), (CGFloat(10.6), CGFloat(1.2))] {
                for (start, end) in [(CGFloat(150), CGFloat(210)), (CGFloat(-30), CGFloat(30))] {
                    let arc = NSBezierPath()
                    arc.appendArc(withCenter: NSPoint(x: 12, y: cy), radius: radius, startAngle: start, endAngle: end)
                    arc.lineWidth = width
                    arc.lineCapStyle = .round
                    arc.stroke()
                }
            }
            return true
        }
        img.isTemplate = true
        return img
    }

    /// Offsets for one shake: a quick left-right jiggle that settles.
    static let shakeFrames: [CGFloat] = [0, -1.6, 1.6, -1.2, 1.2, -0.6, 0.6, 0]
}
