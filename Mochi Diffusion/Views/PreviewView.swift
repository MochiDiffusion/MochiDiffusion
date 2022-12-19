//
//  PreviewView.swift
//  Diffusion
//
//  Created by Fahim Farook on 12/15/2022.
//

import SwiftUI
import UniformTypeIdentifiers

struct PreviewView: View {
    var image: Binding<SDImage?>
    
    var body: some View {
        if let sdi = image.wrappedValue, let img = sdi.image {
            let imageView = Image(img, scale: 1, label: Text("generated"))
            let caption = sdi.prompt.count > 120 ? "\(String(sdi.prompt.prefix(120)))..." : sdi.prompt
            return AnyView(
                VStack {
                    imageView.resizable()
                    
                    Text(caption).textSelection(.enabled)
                }
            )
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
