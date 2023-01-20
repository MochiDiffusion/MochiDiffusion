//
//  ErrorBanner.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 12/17/2022.
//

import SwiftUI

struct ErrorBanner: View {
    var errorMessage: String

    var body: some View {
        Text(errorMessage)
            .font(.headline)
            .padding(4)
            .frame(maxWidth: .infinity)
            .background(Color.accentColor)
    }
}

struct ErrorBanner_Previews: PreviewProvider {
    static var previews: some View {
        ErrorBanner(errorMessage: "This is an error!")
    }
}
