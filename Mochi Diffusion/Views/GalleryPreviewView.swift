//
//  GalleryPreviewView.swift
//  Mochi Diffusion
//
//  Created by Hossein on 7/4/23.
//

import SwiftUI

struct GalleryPreviewView: View {
    @Environment(ImageGenerator.self) private var generator: ImageGenerator
    @Environment(ImageStore.self) private var store: ImageStore
    @State private var strokeColor = Color.black

    let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        if let image = store.currentGeneratingImage, case .running = generator.state {
            ZStack {
                Image(image, scale: 1, label: Text(""))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            }
                .overlay(
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(strokeColor, lineWidth: 4)
                )
                .onReceive(timer) { _ in
                    withAnimation(.linear(duration: 1)) {
                        strokeColor = (strokeColor == .black) ? .cyan : .black
                    }
                }
        }
    }
}
