//
//  ControlNetView.swift
//  Mochi Diffusion
//
//  Created by Stuart Moore on 4/27/23.
//

import CoreML
import SwiftUI

struct ControlNetView: View {
    @Environment(GenerationController.self) private var controller: GenerationController
    @Environment(ConfigStore.self) private var configStore: ConfigStore

    var body: some View {
        Text("ControlNet")
            .sidebarLabelFormat()

        HStack(alignment: .top) {
            ImageWellView(
                image: controller.currentControlNets.first?.image,
                size: controller.currentConstraints.size.resolved(
                    CGSize(width: configStore.width, height: configStore.height)
                ),
                selectImage: controller.selectImage
            ) { image in
                if let image {
                    await controller.setControlNet(image: image)
                } else {
                    await controller.unsetControlNet()
                }
            }
            .frame(width: 90, height: 90)
            .disabled(controller.controlNet.isEmpty)

            Spacer()

            VStack(alignment: .trailing) {
                Menu {
                    Button {
                        Task { await controller.unsetControlNet() }
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
                                Task { await controller.setControlNet(name: name) }
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
                        Task { await controller.selectControlNetImage(at: 0) }
                    } label: {
                        Image(systemName: "photo")
                    }
                    .disabled(controller.controlNet.isEmpty)

                    Button {
                        Task { await controller.unsetControlNetImage(at: 0) }
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .disabled(controller.controlNet.isEmpty)
                }
            }
        }
    }
}
