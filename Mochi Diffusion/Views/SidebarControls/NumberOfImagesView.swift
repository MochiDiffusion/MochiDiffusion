//
//  NumberOfImagesView.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 12/26/22.
//

import SwiftUI

struct NumberOfImagesView: View {
    @EnvironmentObject private var controller: ImageController
    private let imageCountValues = [
        1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 20, 30, 50, 100
    ]

    var body: some View {
        Text("Number of Images:")
        Picker("", selection: $controller.numberOfImages) {
            ForEach(imageCountValues, id: \.self) { number in
                Text(verbatim: String(number)).tag(number)
            }
        }
        .labelsHidden()
    }
}

struct NumberOfImagesView_Previews: PreviewProvider {
    static var previews: some View {
        NumberOfImagesView()
            .environmentObject(ImageController.shared)
    }
}
