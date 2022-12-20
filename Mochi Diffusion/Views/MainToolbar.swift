//
//  MainToolbar.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 12/19/22.
//

import SwiftUI

struct MainToolbar: View {
    @EnvironmentObject var store: Store
    @State private var isInfoPopoverShown = false

    var body: some View {
        if let sdi = $store.selectedImage.wrappedValue, let img = sdi.image {
            let imageView = Image(img, scale: 1, label: Text("generated"))
            Button(action: { self.isInfoPopoverShown.toggle() }) {
                Label("Get Info", systemImage: "info.circle")
            }
            .popover(isPresented: self.$isInfoPopoverShown, arrowEdge: .bottom) {
                InspectorView().padding()
            }
            Button(action: sdi.save) {
                Label("Save", systemImage: "square.and.arrow.down")
            }
            ShareLink(item: imageView, preview: SharePreview(sdi.prompt, image: imageView))
        }
        else {
            Button(action: {}) {
                Label("Get Info", systemImage: "info.circle")
            }
            .disabled(true)
            Button(action: {}) {
                Label("Save Image", systemImage: "square.and.arrow.down")
            }
            .disabled(true)
            Button(action: {}) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            .disabled(true)
        }
    }
}

struct MainToolbar_Previews: PreviewProvider {
    static var previews: some View {
        MainToolbar()
    }
}
