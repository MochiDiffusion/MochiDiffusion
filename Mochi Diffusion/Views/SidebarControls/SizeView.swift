//
//  SizeView.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 12/26/22.
//

import SwiftUI

struct SizeView: View {
    @EnvironmentObject private var controller: ImageController
    private let imageSizes = [
        256, 320, 384, 448, 512, 576, 640, 704, 768,
    ]

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(
                    "Width:",
                    comment: "Label for image width picker"
                )
                Picker("", selection: $controller.width) {
                    ForEach(imageSizes, id: \.self) { size in
                        Text(verbatim: String(size)).tag(size)
                    }
                }
                .labelsHidden()
            }
            VStack(alignment: .leading) {
                Text(
                    "Height:",
                    comment: "Label for image height picker"
                )
                Picker("", selection: $controller.height) {
                    ForEach(imageSizes, id: \.self) { size in
                        Text(verbatim: String(size)).tag(size)
                    }
                }
                .labelsHidden()
            }
        }
    }
}

#Preview {
    SizeView()
        .environmentObject(ImageController.shared)
}
