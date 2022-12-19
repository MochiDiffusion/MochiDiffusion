//
//  PreviewView.swift
//  Diffusion
//
//  Created by Fahim Farook on 12/15/2022.
//

import SwiftUI
import UniformTypeIdentifiers

struct PreviewView: View {
    @State private var isInfoPopoverShown = false
    var image: Binding<SDImage?>
    
    var body: some View {
        if let sdi = image.wrappedValue, let img = sdi.image {
            let imageView = Image(img, scale: 1, label: Text("generated"))
            return AnyView(
                VStack {
                    imageView.resizable()
                    HStack {
                        Button(action: { self.isInfoPopoverShown.toggle() }) {
                            Image(systemName: "info.circle")
                            Text("Show Info")
                        }
                        .popover(isPresented: self.$isInfoPopoverShown, arrowEdge: .bottom) {
                            InspectorView(image: image)
                                .padding()
                        }
                        
                        Spacer()
                        
                        ShareLink(item: imageView, preview: SharePreview(sdi.prompt, image: imageView))
                        Button("Save Image", action: {
                            sdi.save()
                        })
                    }
                })
        }
        return AnyView(Image(systemName: "paintbrush.pointed")
            .resizable()
            .foregroundColor(.white.opacity(0.2))
            .frame(maxWidth: 100, maxHeight: 100))
    }
}

struct PreviewView_Previews: PreviewProvider {
    static var previews: some View {
        var sd = SDImage()
        sd.prompt = "Test Prompt"
        return PreviewView(image: .constant(sd))
    }
}
