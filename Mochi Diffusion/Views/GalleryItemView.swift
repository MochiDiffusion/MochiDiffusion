//
//  GalleryItemView.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 1/4/23.
//

import SwiftUI

struct GalleryItemView: View {
    let sdi: SDImage

    var body: some View {
        if let image = sdi.image {
            Image(image, scale: 1, label: Text(verbatim: String(sdi.seed)))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .padding(4)
        } else {
            Color.clear
        }
    }
}
