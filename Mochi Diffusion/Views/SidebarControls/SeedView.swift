//
//  SeedView.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 12/26/22.
//

import SwiftUI

struct SeedView: View {
    @Environment(GenerationController.self) private var controller: GenerationController
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var controller = controller

        Text("Seed")
            .sidebarLabelFormat()
        HStack {
            TextField("random", value: $controller.seed, formatter: Formatter.seed)
                .focused($focused)
                .textFieldStyle(.roundedBorder)
            Button {
                focused = false
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    controller.seed = 0
                }
            } label: {
                Image(systemName: "shuffle")
                    .frame(minWidth: 18)
            }
        }
    }
}

extension Formatter {
    static let seed: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimum = 0
        formatter.maximum = NSNumber(value: UInt32.max)
        formatter.maximumFractionDigits = 0
        formatter.usesGroupingSeparator = false
        formatter.hasThousandSeparators = false
        formatter.alwaysShowsDecimalSeparator = false
        formatter.zeroSymbol = ""
        return formatter
    }()
}
