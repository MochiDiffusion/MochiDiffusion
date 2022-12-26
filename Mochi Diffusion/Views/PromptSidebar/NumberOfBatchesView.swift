//
//  NumberOfBatchesView.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 12/26/22.
//

import SwiftUI

struct NumberOfBatchesView: View {
    @EnvironmentObject var store: Store
    @State private var isImageCountPopoverShown = false
    private var imageCountValues = [
        1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 20, 30, 50, 100
    ]

    var body: some View {
        Text("Number of Batches:")
        Picker("", selection: $store.numberOfBatches) {
            ForEach(imageCountValues, id: \.self) { s in
                Text(String(s)).tag(s)
            }
        }
        .labelsHidden()
    }
}

struct NumberOfBatchesView_Previews: PreviewProvider {
    static var previews: some View {
        NumberOfBatchesView()
    }
}
