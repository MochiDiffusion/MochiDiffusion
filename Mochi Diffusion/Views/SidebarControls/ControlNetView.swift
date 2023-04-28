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

        if controller.controlNet.isEmpty {
            Text("N/A")
        } else {
            Menu {
                ForEach(controller.controlNet, id: \.self) { name in
                    Button {
                        if let index = controller.currentControlNets.firstIndex(of: name) {
                            controller.currentControlNets.remove(at: index)
                        } else {
                            controller.currentControlNets.append(name)
                        }
                    } label: {
                        if controller.currentControlNets.contains(name) {
                            Image(systemName: "checkmark")
                        }
                        Text(verbatim: name)
                    }
                }

                Divider()

                Button {
                    controller.currentControlNets = []
                } label: {
                    Text(verbatim: "Clear All")
                }
            } label: {
                if controller.currentControlNets.isEmpty {
                    Text("None")
                } else {
                    Text(controller.currentControlNets.formatted(.list(type: .and)))
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(controller.controlNetImages, id: \.self) { image in
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
                                Task { await ImageController.shared.unsetControlNetImage(image) }
                            }
                    }

                    Button {
                        Task { await ImageController.shared.selectControlNetImage() }
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
                    }
                    .buttonStyle(.plain)
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
