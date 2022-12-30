//
//  GalleryImageView.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 12/30/22.
//

import SwiftUI

struct GalleryImageView: View {
    @EnvironmentObject var store: Store
    var i: Int
    var sdi: SDImage
    
    var body: some View {
        Image(sdi.image!, scale: 1, label: Text(String(sdi.seed)))
            .resizable()
            .aspectRatio(contentMode: .fit)
            .padding(4)
            .overlay(
                RoundedRectangle(cornerRadius: 2)
                    .stroke(i == store.selectedImageIndex ? Color.accentColor : Color.clear, lineWidth: 3)
            )
            .onTapGesture {
                store.selectImage(index: i)
            }
            .contextMenu {
                Section {
                    Button("Copy to Prompt") {
                        store.copyToPrompt()
                    }
                    Button("Convert to High Resolution") {
                        store.upscaleImage(sdImage: sdi)
                    }
                    Button("Save Image...") {
                        sdi.save()
                    }
                }
                Section {
                    Button("Remove") {
                        store.removeImage(index: i)
                    }
                }
            }
    }
}
