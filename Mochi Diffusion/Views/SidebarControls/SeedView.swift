//
//  SeedView.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 12/26/22.
//

import SwiftUI

struct SeedView: View {
    @EnvironmentObject private var controller: ImageController
    @FocusState private var randomFieldIsFocused: Bool

    var body: some View {
        Text("Seed:")
        HStack {
            TextField("random", value: $controller.seed, formatter: Formatter.seedFormatter)
                .focused($randomFieldIsFocused)
                .textFieldStyle(.roundedBorder)
            Button {
                randomFieldIsFocused = false
                /// ugly hack
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    ImageController.shared.seed = 0
                }
            } label: {
                Image(systemName: "shuffle")
                    .frame(minWidth: 18)
            }
        }
    }
}

struct SeedView_Previews: PreviewProvider {
    static var previews: some View {
        SeedView()
            .environmentObject(ImageController.shared)
    }
}
