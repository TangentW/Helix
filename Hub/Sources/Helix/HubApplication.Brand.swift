#if os(macOS)
import SwiftUI

extension HubApplication {
enum Brand {}
}

extension HubApplication.Brand {
static let navy = Color(red: 7.0 / 255.0, green: 27.0 / 255.0, blue: 61.0 / 255.0)
static let azure = Color(red: 23.0 / 255.0, green: 107.0 / 255.0, blue: 1)
static let coral = Color(red: 1, green: 107.0 / 255.0, blue: 87.0 / 255.0)

struct Mark: View {
    enum Style: Equatable {
        case color
        case template
    }

    var style: Style = .color
    var disconnected = false

    var body: some View {
        Canvas { context, size in
            let scale = min(size.width / 512, size.height / 320)
            let transform = CGAffineTransform(
                translationX: (size.width - 512 * scale) / 2,
                y: (size.height - 320 * scale) / 2
            ).scaledBy(x: scale, y: scale)
            let lineWidth = 54 * scale

            func stroke(_ path: Path, color: Color) {
                context.stroke(
                    path.applying(transform),
                    with: .color(color),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt)
                )
            }

            func terminal(_ point: CGPoint, color: Color) {
                let bounds = CGRect(
                    x: point.x - 27,
                    y: point.y - 27,
                    width: 54,
                    height: 54
                )
                context.fill(
                    Path(ellipseIn: bounds).applying(transform),
                    with: .color(color)
                )
            }

            let rearColor = style == .template
                ? Color.primary : HubApplication.Brand.navy
            let frontColor = style == .template
                ? Color.primary : HubApplication.Brand.azure
            let patchColor = style == .template
                ? Color.primary : HubApplication.Brand.coral

            stroke(
                style == .template ? Self.templateRearLeading : Self.rearLeading,
                color: rearColor
            )
            if disconnected {
                let offsetPatch = Self.templatePatch.applying(
                    CGAffineTransform(translationX: 12, y: 20)
                )
                stroke(offsetPatch, color: patchColor)
            } else {
                stroke(
                    style == .template ? Self.templatePatch : Self.patch,
                    color: patchColor
                )
            }
            stroke(
                style == .template ? Self.templateRearTrailing : Self.rearTrailing,
                color: style == .template ? rearColor : HubApplication.Brand.azure
            )
            stroke(Self.front, color: frontColor)
            terminal(CGPoint(x: 72, y: 102), color: rearColor)
            terminal(
                CGPoint(x: 440, y: 225),
                color: style == .template ? rearColor : HubApplication.Brand.azure
            )
            terminal(CGPoint(x: 72, y: 225), color: frontColor)
            terminal(CGPoint(x: 440, y: 102), color: frontColor)
        }
        .aspectRatio(512.0 / 320.0, contentMode: .fit)
    }

    private static var rearLeading: Path {
        Path { path in
            path.move(to: CGPoint(x: 72, y: 102))
            path.addCurve(
                to: CGPoint(x: 278.06, y: 194.44),
                control1: CGPoint(x: 152.24, y: 99.28),
                control2: CGPoint(x: 191.79, y: 157.13)
            )
        }
    }

    private static var patch: Path {
        Path { path in
            path.move(to: CGPoint(x: 278.06, y: 194.44))
            path.addCurve(
                to: CGPoint(x: 358.01, y: 218.24),
                control1: CGPoint(x: 300.89, y: 204.31),
                control2: CGPoint(x: 327, y: 212.75)
            )
        }
    }

    private static var rearTrailing: Path {
        Path { path in
            path.move(to: CGPoint(x: 358.01, y: 218.24))
            path.addCurve(
                to: CGPoint(x: 440, y: 225),
                control1: CGPoint(x: 382.12, y: 222.51),
                control2: CGPoint(x: 409.2, y: 225)
            )
        }
    }

    private static var front: Path {
        Path { path in
            path.move(to: CGPoint(x: 72, y: 225))
            path.addCurve(
                to: CGPoint(x: 440, y: 102),
                control1: CGPoint(x: 190, y: 225),
                control2: CGPoint(x: 220, y: 98)
            )
        }
    }

    // Template paths leave visible seams around the replaceable segment.
    private static var templateRearLeading: Path {
        Path { path in
            path.move(to: CGPoint(x: 72, y: 102))
            path.addCurve(
                to: CGPoint(x: 271.54, y: 191.61),
                control1: CGPoint(x: 151.3, y: 99.31),
                control2: CGPoint(x: 190.43, y: 155.64)
            )
        }
    }

    private static var templatePatch: Path {
        Path { path in
            path.move(to: CGPoint(x: 285.49, y: 197.64))
            path.addCurve(
                to: CGPoint(x: 352.33, y: 217.18),
                control1: CGPoint(x: 305.28, y: 206.13),
                control2: CGPoint(x: 327.30, y: 212.78)
            )
        }
    }

    private static var templateRearTrailing: Path {
        Path { path in
            path.move(to: CGPoint(x: 366.37, y: 219.70))
            path.addCurve(
                to: CGPoint(x: 440, y: 225),
                control1: CGPoint(x: 384.57, y: 222.78),
                control2: CGPoint(x: 410.73, y: 225)
            )
        }
    }
}
}
#endif
