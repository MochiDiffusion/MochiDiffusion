//
//  StyleView.swift
//  Mochi Diffusion
//
//  Created by czkoko on 2024/3/5.
//

import SwiftUI

struct StyleView: View {
    var body: some View {
        Text("Style")
            .sidebarLabelFormat()
        ScrollView(.horizontal) {
            LazyHStack(spacing: 10) {
                StyleButton(style: "None", positive: "{prompt}", negative: "", image: "")
                StyleButton(style: "Photographic", positive: "cinematic photo, {prompt}, 35mm photograph, film, bokeh, professional, 4k, highly detailed", negative: "drawing, painting, crayon, sketch, graphite, impressionist, noisy, blurry, soft, deformed, ugly", image: "Photographic")
                StyleButton(style: "Cinematic", positive: "cinematic film, {prompt}, shallow depth of field, vignette, highly detailed, film grain", negative: "anime, cartoon, graphic, text, painting, crayon, graphite, abstract, glitch, deformed, mutated, ugly, disfigured", image: "Cinematic")
                StyleButton(style: "Anime", positive: "anime artwork, {prompt}, anime style, key visual, vibrant, studio anime,  highly detailed", negative: "photo, deformed, black and white, realism, disfigured, low contrast", image: "Anime")
                StyleButton(style: "Digital Art", positive: "concept art, {prompt}, digital artwork, illustrative, painterly, matte painting, highly detailed", negative: "photo, photorealistic, realism, ugly", image: "DigitalArt")
                StyleButton(style: "Comic Book", positive: "comic, {prompt}, graphic illustration, comic art, graphic novel art, vibrant, highly detailed", negative: "photograph, deformed, glitch, noisy, realistic, stock photo", image: "ComicBook")
                StyleButton(style: "Fantasy Art", positive: "ethereal fantasy concept art of {prompt}, magnificent, celestial, ethereal, painterly, epic, majestic, magical, fantasy art, cover art", negative: "photographic, realistic, realism, 35mm film, dslr, cropped, frame, text, deformed, glitch, noise, noisy, off-center, deformed, cross-eyed, closed eyes, bad anatomy, ugly, disfigured, sloppy, duplicate, mutated, black and white", image: "FantasyArt")
                StyleButton(style: "Analog Film", positive: "analog film photo, {prompt}, faded film, desaturated, 35mm photo, grainy, vignette, vintage, Kodachrome, Lomography, stained, highly detailed, found footage", negative: "painting, drawing, illustration, glitch, deformed, mutated, cross-eyed, ugly, disfigured", image: "AnalogFilm")
                StyleButton(style: "Neon Punk", positive: "neonpunk style, {prompt}, cyberpunk, vaporwave, neon, vibes, vibrant, stunningly beautiful, crisp, detailed, sleek, ultramodern, magenta highlights, dark purple shadows, high contrast, cinematic, ultra detailed, intricate, professional", negative: "painting, drawing, illustration, glitch, deformed, mutated, cross-eyed, ugly, disfigured", image: "NeonPunk")
                StyleButton(style: "Isometric", positive: "isometric style, {prompt}, vibrant, beautiful, crisp, detailed, ultra detailed, intricate", negative: "deformed, mutated, ugly, disfigured, blur, blurry, noise, noisy, realistic, photographic", image: "Isometric")
                StyleButton(style: "Low Poly", positive: "low-poly style, {prompt}, low-poly game art, polygon mesh, jagged, blocky, wireframe edges, centered composition", negative: "noisy, sloppy, messy, grainy, highly detailed, ultra textured, photo", image: "LowPoly")
                StyleButton(style: "Origami", positive: "origami style, {prompt}, paper art, pleated paper, folded, origami art, pleats, cut and fold, centered composition", negative: "noisy, sloppy, messy, grainy, highly detailed, ultra textured, photo", image: "Origami")
                StyleButton(style: "Line Art", positive: "line art drawing, {prompt}, professional, sleek, modern, minimalist, graphic, line art, vector graphics", negative: "anime, photorealistic, 35mm film, deformed, glitch, blurry, noisy, off-center, deformed, cross-eyed, closed eyes, bad anatomy, ugly, disfigured, mutated, realism, realistic, impressionism, expressionism, oil, acrylic", image: "LineArt")
                StyleButton(style: "3D Model", positive: "professional 3d model, {prompt}, octane render, highly detailed, volumetric, dramatic lighting", negative: "ugly, deformed, noisy, low poly, blurry, painting", image: "3DModel")
                StyleButton(style: "Pixel Art", positive: "pixel-art, {prompt}, low-res, blocky, pixel art style, 8-bit graphics", negative: "sloppy, messy, blurry, noisy, highly detailed, ultra textured, photo, realistic", image: "PixelArt")
            }
        }
    }
}

struct StyleButton: View {
    @EnvironmentObject private var controller: ImageController
    
    let style: String
    let positive: String
    let negative: String
    let image: String
    
    var body: some View {
        VStack{
            Button(action: {
                controller.stylePrompt = positive
                controller.styleNegativePrompt = negative
                controller.selectedStyle = style
            }) {
                if image.isEmpty {
                    Image(systemName: "clear.fill")
                        .resizable()
                        .frame(width: 65, height: 65)
                        .border(.selection, width: 2)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                } else {
                    Image(image)
                        .resizable()
                        .frame(width: 65, height: 65)
                        .border(.selection, width: 2)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
            .buttonStyle(PlainButtonStyle())

            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(
                        controller.selectedStyle == style ? Color(nsColor: .orange) : Color(nsColor: .clear),
                        lineWidth: 2
                    )
            )
            
            Text(style)
                .font(.caption)
                .multilineTextAlignment(.center)
        }
        .padding(2)
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        StyleView()
    }
}
