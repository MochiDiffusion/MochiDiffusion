//
//  GalleryItemView.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 1/4/23.
//

import SwiftUI

private struct WandStar: View {
    let size: CGFloat
    var body: some View {
        Image(systemName: "wand.and.stars")
            .foregroundColor(.white)
            .font(.system(size: size))
            .animation(nil, value: UUID())
    }
}

private struct UpscalingAnimationView: View {
    @State private var isAnimated = false
    private let lowBlur: CGFloat = 1.5
    private let highBlur: CGFloat = 5
    private let highOpacity: CGFloat = 0.5
    private let sizeRange: ClosedRange<Int> = 12...88
    private let durationRange: ClosedRange<Float> = 0.5...1
    private let delayRange: ClosedRange<Float> = 0.1...0.3

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                /// Blur Background
                Rectangle()
                    .foregroundColor(.black)
                    .blur(radius: 50)
                    .opacity(0.3)
                /// Random WandStars
                ForEach(0..<8) { index in
                    let x = CGFloat.random(
                        in: (index < 2 || (index >= 4 && index < 6))
                            ? 0...(geometry.size.width / 2)
                            : (geometry.size.width / 2)...geometry.size.width
                    )
                    let y = CGFloat.random(
                        in: (index < 4)
                            ? 0...(geometry.size.height / 2)
                            : (geometry.size.height / 2)...geometry.size.height
                    )
                    WandStar(size: CGFloat(Int.random(in: sizeRange)))
                        .blur(radius: isAnimated ? lowBlur : highBlur)
                        .opacity(isAnimated ? highOpacity : 0.0)
                        .position(x: x, y: y)
                        .animation(
                            Animation
                                .easeInOut(duration: Double(Float.random(in: durationRange)))
                                .delay(Double(Float.random(in: delayRange)))
                                .repeatForever(autoreverses: true),
                            value: isAnimated
                        )
                }
            }
            .onAppear {
                isAnimated = true
            }
        }
        .padding(10)
        .clipped()
    }
}

struct GalleryItemView: View {
    let sdi: SDImage

    var body: some View {
        if let image = sdi.image {
            ZStack {
                Image(image, scale: 1, label: Text(verbatim: String(sdi.seed)))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(4)
                if sdi.isUpscaling {
                    UpscalingAnimationView()
                }
                Text(finderTagColorNumberToString(self.sdi.finderTagColorNumber))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(8)
            }
        } else {
            Color.clear
        }
    }
}

#Preview {
    VStack {
        UpscalingAnimationView()
            .frame(width: 300, height: 300)
            .border(.selection, width: 5)
    }
    .frame(width: 350, height: 350)
}
