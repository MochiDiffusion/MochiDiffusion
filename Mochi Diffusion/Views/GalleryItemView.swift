//
//  GalleryItemView.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 1/4/23.
//

import SwiftUI

struct GalleryItemView: View {
    let size: Double
    let sdi: SDImage
    let i: Int
    
    var body: some View {
        Image(sdi.image!, scale: 1, label: Text(String(sdi.seed)))
            .resizable()
            .aspectRatio(contentMode: .fit)
            .padding(4)
            .frame(width: size, height: size)
    }
}
