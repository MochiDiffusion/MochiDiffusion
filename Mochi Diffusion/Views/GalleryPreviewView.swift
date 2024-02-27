//
//  GalleryPreviewView.swift
//  Mochi Diffusion
//
//  Created by Hossein on 7/4/23.
//

import SwiftUI

struct GalleryPreviewView: View {
    @Environment(ImageGenerator.self) private var generator: ImageGenerator
    var image: CGImage

    var body: some View {
        ZStack {
            Image(image, scale: 1, label: Text(""))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 210, height: 210)
                .cornerRadius(10.0)
            if case let .running(progress) = generator.state, let progress = progress, progress.stepCount > 0 {
                let step = progress.step + 1
                let stepValue = Double(step) / Double(progress.stepCount + 1)

                let progressLabel = String(
                    localized: "About \(formatTimeRemaining(generator.lastStepGenerationElapsedTime, stepsLeft: progress.stepCount - step + 1))",
                    comment: "Text displaying the current time remaining"
                )

                VStack(alignment: .leading) {
                    HStack {
                        Spacer()
                        Text(verbatim: "\(step)/\(progress.stepCount + 1)")
                            .padding(6)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 4))
                    }
                    Spacer()
                    ProgressView(progressLabel, value: stepValue, total: 1)
                        .padding(8)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                }
                .padding(15)
            }
        }
    }
}
