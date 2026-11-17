// macOS 14 stand-ins for two macOS 15 colour helpers.
import AppKit
import SwiftUI

private func linearised(_ component: CGFloat) -> Double {
    let v = Double(component)
    return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
}

private func encoded(_ value: Double) -> Double {
    let v = min(max(value, 0), 1)
    return v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055
}

extension Color {
    /// Stand-in for `Color.mix(with:by:in:)`, which is macOS 15 only.
    ///
    /// SwiftUI's version mixes perceptually (Oklab); this mixes in linear-light
    /// sRGB, which follows the same curve closely enough for chart shading —
    /// the lightening and darkening here stay even rather than banding toward
    /// the highlights. A colour that cannot be converted is returned unchanged.
    func blended(with other: Color, by fraction: Double) -> Color {
        let amount = min(max(fraction, 0), 1)
        guard
            let base = NSColor(self).usingColorSpace(.sRGB),
            let target = NSColor(other).usingColorSpace(.sRGB)
        else { return self }

        func mixed(_ from: CGFloat, _ to: CGFloat) -> Double {
            let a = linearised(from)
            let b = linearised(to)
            return encoded(a + (b - a) * amount)
        }

        let alpha = Double(base.alphaComponent)
            + (Double(target.alphaComponent) - Double(base.alphaComponent)) * amount

        return Color(
            .sRGB,
            red: mixed(base.redComponent, target.redComponent),
            green: mixed(base.greenComponent, target.greenComponent),
            blue: mixed(base.blueComponent, target.blueComponent),
            opacity: alpha)
    }
}
