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

                let progressLabel = String(
                    localized: "About \(formatTimeRemaining(generator.lastStepGenerationElapsedTime, stepsLeft: progress.stepCount - step))",
                    comment: "Text displaying the current time remaining"
                )

                VStack(alignment: .leading) {
                    HStack {
                        Spacer()
                        Text("\(step)/\(progress.stepCount)")
                            .padding(6)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 4))
                    }
                    Spacer()
                    ProgressView(progressLabel, value: stepValue, total: 1)
                        .padding(6)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 4))
                        .foregroundStyle(.secondary)
                }
                .padding(4)
            }
        }
        .padding(2)
    }
}
