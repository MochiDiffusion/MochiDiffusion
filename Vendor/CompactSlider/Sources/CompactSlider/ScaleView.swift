// The MIT License (MIT)
//
// Copyright (c) 2022 Alexey Bukhtin (github.com/buh).
//

import SwiftUI

extension CompactSlider {
    /// A scale visibility determines the rules for showing the scale.
    public enum ScaleVisibility {
        case hovering, always, hidden
    }
}

/// A shape that draws a scale of possible values.
struct Scale: Shape {

    let count: Int
    var minSpacing: CGFloat = 3

    func path(in rect: CGRect) -> Path {
        Path { path in
            guard count > 0, minSpacing > 1 else { return }

            let spacing = max(minSpacing, rect.width / CGFloat(count + 1))
            var x = spacing

            for _ in 0..<count {
                path.move(to: .init(x: x, y: 0))
                path.addLine(to: .init(x: x, y: rect.maxY))
                x += spacing

                if x > rect.maxX {
                    break
                }
            }
        }
    }
}

/// ScaleView shows the scale based on number of marks.
///
/// Scales are grouped and they need an additional help to layout.
/// Usage case:
/// ```
/// ZStack {
///     ScaleView().frame(height: 50, alignment: .top)
/// }
/// ```
struct ScaleView: View {

    @Environment(\.compactSliderSecondaryAppearance) var secondaryAppearance

    var steps: Int = 0
    var scaleLength: CGFloat = .scaleLength
    var secondaryScaleLength: CGFloat = .secondaryScaleLength
    var lineWidth: CGFloat = .scaleLineWidth

    var body: some View {
        Group {
            Scale(count: steps > 0 ? steps : 49)
                .stroke(
                    steps > 0
                        ? secondaryAppearance.scaleColor : secondaryAppearance.secondaryScaleColor,
                    lineWidth: lineWidth
                )
                .frameHeightIfNeeded(
                    steps > 0 ? scaleLength : secondaryScaleLength
                )

            if steps == 0 {
                Scale(count: 9)
                    .stroke(secondaryAppearance.scaleColor, lineWidth: lineWidth)
                    .frameHeightIfNeeded(scaleLength)
            }
        }
    }
}

extension View {
    @ViewBuilder
    fileprivate func frameHeightIfNeeded(_ height: CGFloat) -> some View {
        if height > 0 {
            frame(height: height)
        } else {
            self
        }
    }
}

#Preview {
    VStack(spacing: 20) {
        ZStack {
            ScaleView()
                .frame(height: 50, alignment: .top)
        }
        .background(Color.label.opacity(0.1))

        ZStack {
            ScaleView(scaleLength: 25, secondaryScaleLength: 15, lineWidth: 2)
                .frame(height: 50, alignment: .top)
        }
        .background(Color.label.opacity(0.1))

        ZStack {
            ScaleView(scaleLength: 0, secondaryScaleLength: 0)
                .frame(height: 50, alignment: .top)
        }
        .background(Color.label.opacity(0.1))

        ScaleView(steps: 30)
            .frame(height: 50, alignment: .top)
            .background(Color.label.opacity(0.1))

        ScaleView(steps: 10, scaleLength: 25, lineWidth: 5)
            .frame(height: 50, alignment: .top)
            .background(Color.label.opacity(0.1))
    }
    .frame(width: 300)
    .padding()
}
