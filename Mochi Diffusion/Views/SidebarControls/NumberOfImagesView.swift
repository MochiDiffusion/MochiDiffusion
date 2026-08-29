//
//  NumberOfImagesView.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 12/26/22.
//

import SwiftUI

struct NumberOfImagesView: View {
    @Environment(GenerationController.self) private var controller: GenerationController

    var body: some View {
        @Bindable var controller = controller

        let numberOfImages = controller.currentConstraints.numberOfImages

        Text("Number of Images")
            .sidebarLabelFormat()
        if let bounds = numberOfImages.bounds {
            MochiSlider(
                value: $controller.numberOfImages,
                bounds: Double(bounds.lowerBound)...Double(bounds.upperBound),
                step: 1,
                strictUpperBound: !numberOfImages.allowsValuesAboveBounds
            )
        } else if let pinned = numberOfImages.resolved(Int(controller.numberOfImages)) {
            PinnedValueField(text: String(pinned))
        } else {
            UnsupportedValueField()
        }
    }
}
