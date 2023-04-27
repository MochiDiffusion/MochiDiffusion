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
            Picker("", selection: $controller.currentControlNet) {
                ForEach(controller.controlNet, id: \.self) { name in
                    Text(verbatim: name).tag(Optional(name))
                }
            }
            .labelsHidden()

            HStack(alignment: .top) {
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
                        .onTapGesture {
                            Task { await ImageController.shared.unsetControlNetImage(image) }
                        }
                }

                Image(systemName: "photo")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundColor(Color(nsColor: .separatorColor))
                    .padding(30)
                    .overlay(
                        RoundedRectangle(cornerRadius: 2)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                    )
                    .frame(height: 90)
                    .onTapGesture {
                        Task { await ImageController.shared.selectControlNetImage() }
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
