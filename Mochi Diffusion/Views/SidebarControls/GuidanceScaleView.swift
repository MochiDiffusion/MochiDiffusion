//
//  GuidanceScaleView.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 12/26/22.
//

import SwiftUI

struct GuidanceScaleView: View {
    @Environment(ConfigStore.self) private var configStore: ConfigStore

    var body: some View {
        @Bindable var configStore = configStore

        Text("Guidance Scale")
            .sidebarLabelFormat()
        MochiSlider(
            value: $configStore.guidanceScale,
            bounds: 1...20,
            step: 0.5
        )
    }
}

#Preview {
    GuidanceScaleView()
        .environment(ConfigStore())
}
