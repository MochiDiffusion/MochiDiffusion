//
//  CircularProgressView.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 1/6/23.
//

import SwiftUI

struct CircularProgressView: View {
    let progress: Double
    let color = Color.accentColor
    let lineWidth = 3.0

    var body: some View {
        ZStack {
            Circle()
                .stroke(
                    color.opacity(0.1),
                    lineWidth: lineWidth
                )
            Circle()
                .trim(from: 0, to: min(progress, 1.0))
                .stroke(
                    color,
                    style: StrokeStyle(
                        lineWidth: lineWidth,
                        lineCap: .round
                    )
                )
                .rotationEffect(.degrees(-90))
                .animation(.easeOut, value: min(progress, 1.0))
        }
    }
}

#Preview {
    CircularProgressView(progress: 0.4)
}
