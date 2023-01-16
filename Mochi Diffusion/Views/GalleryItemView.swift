//
//  GalleryItemView.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 1/4/23.
//

import SwiftUI

struct GalleryItemView: View {
    let sdi: SDImage
    let index: Int

    var body: some View {
        Image(sdi.image!, scale: 1, label: Text(verbatim: String(sdi.seed)))
            .resizable()
            .aspectRatio(contentMode: .fit)
            .padding(4)
    }
}
