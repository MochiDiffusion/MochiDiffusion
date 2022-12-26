//
//  ImageCountView.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 12/26/22.
//

import SwiftUI

struct ImageCountView: View {
    @EnvironmentObject var store: Store
    @State private var isImageCountPopoverShown = false
    private var imageCountValues = [
        1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 20, 30, 50, 100
    ]

    var body: some View {
        HStack {
            Text("Number of Images:")

            Spacer()

            Button(action: { self.isImageCountPopoverShown.toggle() }) {
                Image(systemName: "info.circle")
                    .foregroundColor(Color.secondary)
            }
            .buttonStyle(PlainButtonStyle())
            .popover(isPresented: self.$isImageCountPopoverShown, arrowEdge: .top) {
                Text("Number of images generated in total")
                    .padding()
            }
        }
        Picker("", selection: $store.imageCount) {
            ForEach(imageCountValues, id: \.self) { s in
                Text(String(s)).tag(s)
            }
        }
        .labelsHidden()
    }
}

struct ImageCountView_Previews: PreviewProvider {
    static var previews: some View {
        ImageCountView()
    }
}
