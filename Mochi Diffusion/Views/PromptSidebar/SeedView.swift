//
//  SeedView.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 12/26/22.
//

import SwiftUI

struct SeedView: View {
    @EnvironmentObject var store: Store
    
    var body: some View {
        Text("Seed (0 for random):",
             tableName: "Prompt",
             comment: "Label for Seed text field")
        TextField("random", value: $store.seed, formatter: Formatter.seedFormatter)
            .textFieldStyle(.roundedBorder)
    }
}

struct SeedView_Previews: PreviewProvider {
    static var previews: some View {
        SeedView()
    }
}
