//
//  ControlNetView.swift
//  Mochi Diffusion
//
//  Created by Stuart Moore on 4/27/23.
//

import CoreML
import SwiftUI

struct ControlNetView: View {
    @EnvironmentObject private var controller: ImageController

    var body: some View {
        Text("ControlNet")
            .sidebarLabelFormat()

        HStack(alignment: .top) {
            ImageWellView(
                image: controller.currentControlNets.first?.image,
                size: controller.currentModel?.inputSize
            ) { image in
                if let image {
                    await ImageController.shared.setControlNet(image: image)
                } else {
                    await ImageController.shared.unsetControlNet()
                }
            }
            .frame(width: 90, height: 90)
            .disabled(controller.controlNet.isEmpty)

            Spacer()

            VStack(alignment: .trailing) {
                Menu {
                    Button {
                        Task { await ImageController.shared.unsetControlNet() }
                    } label: {
                        Text(
                            "None",
                            comment: "Option to not use ControlNet"
                        )
                    }

                    Divider()

                    if !controller.controlNet.isEmpty {
                        ForEach(
                            controller.controlNet.sorted {
                                $0.compare($1, options: [.caseInsensitive, .diacriticInsensitive])
                                    == .orderedAscending
                            }, id: \.self
                        ) { name in
                            Button {
                                Task { await ImageController.shared.setControlNet(name: name) }
                            } label: {
                                Text(verbatim: name)
                            }
                        }
                    }
                } label: {
                    if let name = controller.currentControlNets.first?.name {
                        Text(name)
                    } else {
                        Text("None")
                    }
                }
                .disabled(controller.controlNet.isEmpty)

                HStack {
                    Button {
                        Task { await ImageController.shared.selectControlNetImage(at: 0) }
                    } label: {
                        Image(systemName: "photo")
                    }
                    .disabled(controller.controlNet.isEmpty)

                    Button {
                        Task { await ImageController.shared.unsetControlNetImage(at: 0) }
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .disabled(controller.controlNet.isEmpty)
                }
            }
        }
    }
}

#Preview {
    ControlNetView()
        .environmentObject(ImageController.shared)
}
