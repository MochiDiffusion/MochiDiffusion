//
//  ModelView.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 12/26/22.
//

import CoreML
import SwiftUI

struct ModelView: View {
    @EnvironmentObject private var controller: ImageController
    #if arch(arm64)
    @State private var isShowingComputeUnitPopover = false
    #endif

    var body: some View {
        Text("Model:")
        HStack {
            Picker("", selection: $controller.currentModel.onChange(modelChanged)) {
                ForEach(controller.models) { model in
                    Text(verbatim: model.name).tag(Optional(model))
                }
            }
            .labelsHidden()
            #if arch(arm64)
            .popover(isPresented: $isShowingComputeUnitPopover, arrowEdge: .top) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Select Compute Unit option")
                        .fontWeight(.bold)

                    Spacer()

                    Text(
                        "\(controller.currentModel!.name) model",
                        comment: "Label displaying the currently selected model name"
                    )

                    Spacer()

                    Text("For `split_einsum` models, select Use Neural Engine.")
                        .helpTextFormat()
                    Text("For `original` models, select Use GPU.")
                        .helpTextFormat()

                    Spacer()

                    HStack {
                        Button {
                            Task {
                                ImageController.shared.mlComputeUnit = .cpuAndNeuralEngine
                                await ImageController.shared.loadModels()
                                isShowingComputeUnitPopover = false
                            }
                        } label: {
                            Text("Use Neural Engine")
                        }

                        Button {
                            Task {
                                ImageController.shared.mlComputeUnit = .cpuAndGPU
                                await ImageController.shared.loadModels()
                                isShowingComputeUnitPopover = false
                            }
                        } label: {
                            Text("Use GPU")
                        }
                    }
                }
                .padding()
            }
            #endif

            Button {
                Task { await ImageController.shared.loadModels() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .frame(minWidth: 18)
            }
        }
    }

    func modelChanged(to value: SDModel?) {
        #if arch(arm64)
        isShowingComputeUnitPopover.toggle()
        #endif
    }
}

struct ModelView_Previews: PreviewProvider {
    static var previews: some View {
        ModelView()
            .environmentObject(ImageController.shared)
    }
}
