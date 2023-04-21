//
//  MessageBanner.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 12/17/2022.
//

import SwiftUI

struct MessageBanner: View {
    var message: String

    var body: some View {
        Text(message)
            .font(.headline)
            .padding(4)
            .frame(maxWidth: .infinity)
            .background(Color.accentColor)
    }
}

struct MessageBanner_Previews: PreviewProvider {
    static var previews: some View {
        MessageBanner(message: "Hello world!")
    }
}
