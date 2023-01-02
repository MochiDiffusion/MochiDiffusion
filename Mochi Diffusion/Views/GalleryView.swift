//
//  GalleryView.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 12/21/22.
//

import SwiftUI

struct GalleryView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        VStack(alignment: .center, spacing: 0) {
            if case .loading = store.mainViewStatus {
//                ErrorBanner(errorMessage: "Loading...")
            } else if case let .error(msg) = store.mainViewStatus {
                ErrorBanner(errorMessage: msg)
            }

            PreviewView()
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if store.images.count > 0 {
                Divider()

                ScrollView(.horizontal) {
                    HStack(alignment: .center, spacing: 14) {
                        ForEach(Array(store.images.enumerated()), id: \.offset) { i, sdi in
                            GalleryImageView(i: i, sdi: sdi)
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
                    .padding()
                }
                .frame(height: 130)
            }
        }
        .toolbar {
            MainToolbar()
        }
    }
}

struct GalleryView_Previews: PreviewProvider {
    static var previews: some View {
        GalleryView()
    }
}
