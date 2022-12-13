//
//  DiffusionApp.swift
//  Diffusion
//
//  Created by Pedro Cuenca on December 2022.
//  See LICENSE at https://github.com/huggingface/swift-coreml-diffusers/LICENSE
//

import SwiftUI

@main
struct DiffusionApp: App {
    var body: some Scene {
        WindowGroup {
            LoadingView()
        }
    }
}

extension String: Error {}
