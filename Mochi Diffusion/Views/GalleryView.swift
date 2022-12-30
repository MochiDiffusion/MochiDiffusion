//
//  GalleryView.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 12/21/22.
//

import SwiftUI
import Combine

struct GalleryView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        VStack(alignment: .center, spacing: 0) {
            if case .loading = store.mainViewStatus {
//                ErrorBanner(errorMessage: "Loading...")
            } else if case let .error(msg) = store.mainViewStatus {
                ErrorBanner(errorMessage: msg)
            } else if case let .running(progress) = store.mainViewStatus {
                getProgressView(progress: progress)
            }

            PreviewView()
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if store.images.count > 0 {
                Divider()

                ScrollView(.horizontal) {
                    LazyHStack(alignment: .center, spacing: 14) {
                        ForEach(Array(store.images.enumerated()), id: \.offset) { i, img in
                            Image(img.image!, scale: 1, label: Text(String(img.seed)))
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
                                        Button("Save Image...") {
                                            img.save()
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
                    .padding()
                }
                .frame(height: 130)
            }
        }
        .toolbar {
            MainToolbar()
        }
    }

    private func getProgressView(progress: StableDiffusionProgress?) -> AnyView {
        guard let progress = progress, progress.stepCount > 0 else {
            // The first time it takes a little bit before generation starts
            return AnyView(
                ProgressView(label: { Text("Loading Model...") })
                    .progressViewStyle(.linear)
                    .padding([.top, .horizontal]))
        }
        let step = Int(progress.step) + 1
        let fraction = Double(step) / Double(progress.stepCount)
        let label = "Step \(step) of \(progress.stepCount)"
        return AnyView(
            HStack(alignment: .center, spacing: 14) {
                ProgressView(label, value: fraction, total: 1)

                Button(action: { store.stopGeneration() }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(Color.secondary)
                }
                .buttonStyle(PlainButtonStyle())
            }
            .padding([.top, .horizontal])
        )
    }
}

struct GalleryView_Previews: PreviewProvider {
    static var previews: some View {
        GalleryView()
    }
}
