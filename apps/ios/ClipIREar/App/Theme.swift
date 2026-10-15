import SwiftUI

/// The app's look, taken from the ClipIR logo: a striped sunset sun, neon outlines, orange → pink → magenta → cyan on
/// near-black. Flat colours only, no glossy or 3D shading.
enum Theme {
    static let background = Color(red: 0.04, green: 0.02, blue: 0.07)
    static let panel = Color(red: 0.09, green: 0.05, blue: 0.13)
    static let orange = Color(red: 1.00, green: 0.60, blue: 0.12)
    static let pink = Color(red: 1.00, green: 0.24, blue: 0.50)
    static let magenta = Color(red: 0.90, green: 0.17, blue: 0.72)
    static let violet = Color(red: 0.55, green: 0.36, blue: 0.96)
    static let cyan = Color(red: 0.18, green: 0.90, blue: 0.94)
    static let blue = Color(red: 0.23, green: 0.42, blue: 1.00)

    /// Top to bottom, as on the logo's sun.
    static let sun = LinearGradient(colors: [orange, pink, magenta], startPoint: .top, endPoint: .bottom)
    /// Left to right, as on the logo's wave.
    static let sea = LinearGradient(colors: [cyan, blue, violet], startPoint: .leading, endPoint: .trailing)
    /// The primary action colour.
    static let hot = LinearGradient(colors: [orange, pink], startPoint: .topLeading, endPoint: .bottomTrailing)
}

/// The logo's sun: a disc cut into horizontal bands whose gaps widen towards the bottom. While `active`, the bands
/// drift upwards and the gaps follow the input `level`, so the sun shows that the app is hearing something.
struct SunStripes: View {
    var level: Float = 0
    var active = false

    var body: some View {
        TimelineView(.animation(paused: !active)) { timeline in
            Canvas { ctx, size in
                let d = min(size.width, size.height)
                let disc = CGRect(x: (size.width - d) / 2, y: (size.height - d) / 2, width: d, height: d)
                ctx.clip(to: Path(ellipseIn: disc))
                let phase = active ? timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1) : 0
                let bands = 11
                let pitch = d / CGFloat(bands)
                let shading = GraphicsContext.Shading.linearGradient(
                    Gradient(colors: [Theme.orange, Theme.pink, Theme.magenta]),
                    startPoint: CGPoint(x: disc.midX, y: disc.minY), endPoint: CGPoint(x: disc.midX, y: disc.maxY))
                for i in -1...bands {
                    let y = disc.minY + (CGFloat(i) - CGFloat(phase)) * pitch
                    let depth = max(0, (y - disc.minY) / d)  // 0 at the top of the sun, 1 at the bottom
                    let gap = depth < 0.35 ? 0 : pitch * (0.12 + 0.55 * (depth - 0.35)) * (1 + CGFloat(level) * 0.8)
                    let height = max(0, pitch - gap + (gap == 0 ? 1 : 0))  // +1 closes hairline seams between bands
                    ctx.fill(Path(CGRect(x: disc.minX, y: y, width: d, height: height)), with: shading)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// The ClipIR logo (App/ClipIRLogo.png), with the sun as a fallback.
struct LogoMark: View {
    var size: CGFloat = 34

    var body: some View {
        Group {
            if let image = UIImage(named: "ClipIRLogo") {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                SunStripes()
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
