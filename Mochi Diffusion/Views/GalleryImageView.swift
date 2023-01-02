//
//  GalleryImageView.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 12/30/22.
//

import SwiftUI

struct GalleryImageView: View {
    var i: Int
    var sdi: SDImage

    var body: some View {
        Image(sdi.image!, scale: 1, label: Text(String(sdi.seed)))
            .resizable()
            .aspectRatio(contentMode: .fit)
            .padding(4)
    }
}
