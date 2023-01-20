//
//  SeedView.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 12/26/22.
//

import SwiftUI

struct SeedView: View {
    @EnvironmentObject private var genStore: GeneratorStore
    @FocusState private var randomFieldIsFocused: Bool

    var body: some View {
        GroupBox {
            HStack {
                Label("Seed", systemImage: "leaf")
                TextField("Random", value: $genStore.seed, formatter: Formatter.seedFormatter)
                    .focused($randomFieldIsFocused)
                    .multilineTextAlignment(.trailing)
                    .textFieldStyle(.plain)
                Button {
                    randomFieldIsFocused = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { // TODO: Find reliable way to clear textfield
                        self.genStore.seed = 0
                    }
                } label: {
                    Image(systemName: "shuffle")
                        .frame(minWidth: 18)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct SeedView_Previews: PreviewProvider {
    static let genStore = GeneratorStore()

    static var previews: some View {
        SeedView()
            .environmentObject(genStore)
    }
}
