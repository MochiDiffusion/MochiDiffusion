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
            if let image = controller.currentControlNets.first?.image {
                Image(image, scale: 1, label: Text(verbatim: ""))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(3)
                    .overlay(
                        RoundedRectangle(cornerRadius: 2)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                    )
                    .frame(height: 90)
                    .accessibilityAddTraits(.isButton)
            } else {
                Button {
                    Task { await ImageController.shared.selectControlNetImage(at: 0) }
                } label: {
                    Image(systemName: "photo")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .foregroundColor(Color(nsColor: .separatorColor))
                        .padding(30)
                        .overlay(
                            RoundedRectangle(cornerRadius: 2)
                                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                        )
                        .background(.background.opacity(0.01))
                        .frame(height: 90)
                        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                            _ = providers.first?.loadDataRepresentation(for: .fileURL) { data, _ in
                                guard let data, let urlString = String(data: data, encoding: .utf8), let url = URL(string: urlString) else {
                                    return
                                }

                                guard let cgImageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else {
                                    return
                                }

                                let imageIndex = CGImageSourceGetPrimaryImageIndex(cgImageSource)

                                guard let cgImage = CGImageSourceCreateImageAtIndex(cgImageSource, imageIndex, nil) else {
                                    return
                                }

                                Task { await controller.setControlNet(SDControlNet(image: cgImage)) }
                            }

                            return true
                        }
                }
                .buttonStyle(.plain)
                .disabled(controller.controlNet.isEmpty)
            }

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
                        ForEach(controller.controlNet, id: \.self) { name in
                            Button {
                                Task { await controller.setControlNet(SDControlNet(name: name)) }
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

struct ControlNetView_Previews: PreviewProvider {
    static var previews: some View {
        ControlNetView()
            .environmentObject(ImageController.shared)
    }
}
