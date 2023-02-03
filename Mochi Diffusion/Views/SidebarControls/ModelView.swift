//
//  ModelView.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 12/26/22.
//

import CoreML
import SwiftUI

struct ModelView: View {
    @EnvironmentObject private var genStore: GeneratorStore
    #if arch(arm64)
    @State private var isShowingComputeUnitPopover = false
    #endif

    var body: some View {
        Text("Model:")
        HStack {
            Picker("", selection: $genStore.currentModel.onChange(modelChanged)) {
                ForEach(genStore.models, id: \.self) { model in
                    Text(verbatim: model).tag(model)
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
                        "\(genStore.currentModel) model",
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
                            genStore.mlComputeUnit = .cpuAndNeuralEngine
                            genStore.loadModels()
                            isShowingComputeUnitPopover = false
                        } label: {
                            Text("Use Neural Engine")
                        }

                        Button {
                            genStore.mlComputeUnit = .cpuAndGPU
                            genStore.loadModels()
                            isShowingComputeUnitPopover = false
                        } label: {
                            Text("Use GPU")
                        }
                    }
                }
                .padding()
            }
            #endif

            Button(action: genStore.loadModels) {
                Image(systemName: "arrow.clockwise")
                    .frame(minWidth: 18)
            }
        }
    }

    func modelChanged(to value: Model) {
        #if arch(arm64)
        isShowingComputeUnitPopover.toggle()
        #endif
    }
}

struct ModelView_Previews: PreviewProvider {
    static let genStore = GeneratorStore()

    static var previews: some View {
        ModelView()
            .environmentObject(genStore)
    }
}
