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
        Text("Seed:")
        HStack {
            TextField("random", value: $genStore.seed, formatter: Formatter.seedFormatter)
                .focused($randomFieldIsFocused)
                .textFieldStyle(.roundedBorder)
            Button {
                randomFieldIsFocused = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { // FIXME: Find reliable way to clear textfield
                    self.genStore.seed = 0
                }
            } label: {
                Image(systemName: "shuffle")
                    .frame(minWidth: 18)
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
