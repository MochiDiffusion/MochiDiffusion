//
//  TextToImage_playground.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 12/15/22.
//

import SwiftUI

struct TextToImage_playground: View {
    @State private var prompt = ""
    @State private var negativePrompt = ""
    @State private var steps = 28.0
    @State private var guidanceScale = 11.0
    @State private var seed: UInt32? = nil
    
    func submit() { }
    
    var body: some View {
        NavigationView {
            HStack(alignment: .top) {
                VStack(alignment: .leading) {
                    TextField("Prompt", text: $prompt, axis: .vertical)
                        .lineLimit(4, reservesSpace: true)
                        .textFieldStyle(.roundedBorder)
                        .frame(height: 100)
                        .onSubmit {
                            submit()
                        }
                    
                    TextEditor(text: $prompt)
                        .lineLimit(3, reservesSpace: true)
                    
                    TextField("Negative Prompt", text: $negativePrompt, axis: .vertical)
                        .lineLimit(4, reservesSpace: true)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            submit()
                        }
                    
                    HStack {
                        Spacer()
                        Button("Generate") {
                            submit()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    
                    Divider()

                    Text("Steps: \(steps, specifier: "%.0f")")
                    Slider(
                        value: $steps,
                        in: 1...200,
                        step: 1
                    )
                    
                    Group {
                        Text("Guidance Scale: \(guidanceScale, specifier: "%.1f")")
                        Slider(
                            value: $guidanceScale,
                            in: 1...20,
                            step: 0.5
                        )
                    }
                    
                    Group {
                        Text("Seed: ")
                        TextField("random", value: $seed, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit {
                                submit()
                            }
                    }
                }
                VStack(alignment: .center) {
                    Spacer()
                    Image(systemName: "photo")
                        .font(.system(size: 150.0))
                        .foregroundColor(.gray)
                        .scaledToFit()
                    Button("Save") {
                        
                    }
                    Spacer()
                }
            }
            .padding()
        }
    }
}

struct TextToImage_playground_Previews: PreviewProvider {
    static var previews: some View {
        TextToImage_playground()
    }
}
