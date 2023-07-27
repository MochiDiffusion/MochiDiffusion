//
//  GalleryPreviewView.swift
//  Mochi Diffusion
//
//  Created by Hossein on 7/4/23.
//

import SwiftUI

struct GalleryPreviewView: View {
    @EnvironmentObject private var generator: ImageGenerator
    var image: CGImage

    var body: some View {
        ZStack(alignment: .bottom) {
            Image(image, scale: 1, label: Text(""))
                .resizable()
                .aspectRatio(contentMode: .fit)
            if case let .running(progress) = generator.state, let progress = progress, progress.stepCount > 0 {
                let step = Int(progress.step) + 1
                let stepValue = Double(step) / Double(progress.stepCount)
                let stepLabel = String(
                    localized: "Step \(step) of \(progress.stepCount)",
                    comment: "Text displaying the current step progress and count"
                )
                ProgressView(stepLabel, value: stepValue, total: 1)
                    .padding(8)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .padding(12)
            }
        }
        .padding(4)
    }
}
