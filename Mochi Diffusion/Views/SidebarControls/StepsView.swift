//
//  StepsView.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 12/26/22.
//

import SwiftUI

struct StepsView: View {
    @Environment(ConfigStore.self) private var configStore: ConfigStore

    var body: some View {
        @Bindable var configStore = configStore

        Text("Steps")
            .sidebarLabelFormat()
        MochiSlider(
            value: $configStore.steps,
            bounds: 1...50,
            step: 1,
            strictUpperBound: false
        )
    }
}

#Preview {
    StepsView()
        .environment(ConfigStore())
}
