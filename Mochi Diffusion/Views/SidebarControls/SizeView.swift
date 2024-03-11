//
//  SizeView.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 12/26/22.
//

import SwiftUI

struct SizeView: View {
    @EnvironmentObject private var controller: ImageController
    private let sdimageSizes = [
        512, 576, 640, 768, 832, 896
    ]
    private let sdxlimageSizes = [
        512, 576, 640, 768, 832, 896, 1024, 1152, 1216, 1280, 1344, 1536
    ]
    
    var body: some View {
        HStack {
            let imageSizes: [Int] = ImageController.shared.currentModel?.isXL ?? false ? sdxlimageSizes : sdimageSizes
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
                .disabled(!(controller.currentModel?.allowsVariableSize ?? false))
            }
            VStack(alignment: .leading) {
                Spacer()
                Button {
                    let w = controller.width, h = controller.height
                    controller.width = h
                    controller.height = w
                } label: {
                    Image(systemName: "arrow.right.arrow.left.circle.fill")
                }
                .buttonBorderShape(.circle)
                .disabled(!(controller.currentModel?.allowsVariableSize ?? false))
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
                .disabled(!(controller.currentModel?.allowsVariableSize ?? false))
            }
        }
    }
}

#Preview {
    SizeView()
        .environmentObject(ImageController.shared)
}
