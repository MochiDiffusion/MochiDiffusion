//
//  ErrorBanner.swift
//  Diffusion
//
//  Created by Fahim Farook on 12/17/2022.
//

import SwiftUI

struct ErrorBanner: View {
    var errorMessage: String
    
    var body: some View {
        Text(errorMessage)
            .font(.headline)
            .frame(maxWidth: .infinity)
            .background(Color.accentColor)
    }
}

struct ErrorBanner_Previews: PreviewProvider {
    static var previews: some View {
        ErrorBanner(errorMessage: "This is an error!")
    }
}
