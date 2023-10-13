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
                    localized: "Step \(step) of \(progress.stepCount) | Estimated Time: \(calculateGenerateEstimation(generator.lastStepGenerationElapsedTime, stepsLeft: progress.stepCount - step))",
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

    func calculateGenerateEstimation(_ interval: Double?, stepsLeft: Int) -> String {
        guard let interval else {return "-"}

        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .short

        let formattedString = formatter.string(from: TimeInterval((interval / 1_000_000_000) * Double(stepsLeft)))

        return formattedString ?? "-"
    }
}
