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

        Menu {
            Button {
                controller.currentControlNets = []
            } label: {
                Text("None")
            }

            Divider()

            if controller.controlNet.isEmpty {
                Text("No ControlNet models found")
            } else {
                ForEach(controller.controlNet, id: \.self) { name in
                    Button {
                        if controller.currentControlNets.isEmpty {
                            controller.currentControlNets = [(name, nil)]
                        } else {
                            controller.currentControlNets[0].0 = name
                        }
                    } label: {
                        Text(verbatim: name)
                    }
                }
            }
        } label: {
            if let name = controller.currentControlNets.first?.0 {
                Text(name)
            } else {
                Text("None")
            }
        }

        if let image = controller.currentControlNets.first?.1 {
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
                .onTapGesture {
                    Task { await ImageController.shared.unsetControlNetImage(at: 0) }
                }
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

                            DispatchQueue.main.async {
                                if controller.currentControlNets.isEmpty {
                                    controller.currentControlNets = [(nil, cgImage)]
                                } else {
                                    controller.currentControlNets[0].1 = cgImage
                                }
                            }
                        }

                        return true
                    }
            }
            .buttonStyle(.plain)
        }
    }
}

struct ControlNetView_Previews: PreviewProvider {
    static var previews: some View {
        ControlNetView()
            .environmentObject(ImageController.shared)
    }
}
