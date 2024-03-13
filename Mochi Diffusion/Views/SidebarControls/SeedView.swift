//
//  SeedView.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 12/26/22.
//

import SwiftUI

struct SeedView: View {
    @EnvironmentObject private var controller: ImageController
    @Environment(FocusController.self) private var focusCon: FocusController
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var focusCon = focusCon

        Text("Seed")
            .sidebarLabelFormat()
        HStack {
            TextField("random", value: $controller.seed, formatter: Formatter.seed)
                .focused($focused)
                .syncFocus($focusCon.seedFieldIsFocused, with: _focused)
                .textFieldStyle(.roundedBorder)
            Button {
                FocusController.shared.removeAllFocus()
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

#Preview {
    SeedView()
        .environmentObject(ImageController.shared)
}
