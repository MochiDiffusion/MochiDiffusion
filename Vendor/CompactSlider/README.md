# CompactSlider 1.2.1

Vendored from https://github.com/buh/CompactSlider at tag `1.2.1` (MIT license).
Mochi uses this local package so clean builds include the SwiftUI SDK workaround in
`ProminentCompactSliderStyle.swift`: erase the gradient to `AnyView` before applying
`opacity`, which is otherwise ambiguous between `View` and `ShapeStyle`.

Source formatting follows Mochi's formatter; an identical internal memberwise
initializer is synthesized to satisfy lint. No other behavior is changed.
