//
//  BatchSizeView.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 12/26/22.
//

import SwiftUI
import Sliders

struct BatchSizeView: View {
    @EnvironmentObject var store: Store
    @State private var isBatchSizePopoverShown = false

    var body: some View {
        HStack {
            Text("Images per Batch: \(store.batchSize)")

            Spacer()

            Button {
                self.isBatchSizePopoverShown.toggle()
            } label: {
                Image(systemName: "info.circle")
                    .foregroundColor(Color.secondary)
            }
            .buttonStyle(PlainButtonStyle())
            .popover(isPresented: self.$isBatchSizePopoverShown, arrowEdge: .top) {
                let imageCount = store.numberOfBatches * store.batchSize
                Text("""
                    Images in a batch are generated at the same time and require more memory.
                    ^[\(imageCount) images](inflect: true) will be generated in total.
                    """)
                    .padding()
            }
        }
        ValueSlider(value: $store.batchSize, in: 1 ... 16, step: 1)
            .valueSliderStyle(
                HorizontalValueSliderStyle(
                    track:
                        HorizontalTrack(view: Color.accentColor)
                        .frame(height: 12)
                        .background(Color.black.opacity(0.2))
                        .cornerRadius(6),
                    thumbSize: CGSize(width: 12, height: 12),
                    options: .interactiveTrack
                )
            )
            .frame(height: 12)
    }
}

struct BatchSizeView_Previews: PreviewProvider {
    static var previews: some View {
        BatchSizeView()
    }
}
