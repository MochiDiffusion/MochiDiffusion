//
//  GalleryToolbarView.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 12/19/22.
//

import SwiftUI

struct GalleryToolbarView: View {
    @EnvironmentObject var store: Store
    @State private var isStatusPopoverShown = false

    var body: some View {
        if case let .running(progress) = store.mainViewStatus {
            if let progress = progress, progress.stepCount > 0 {
                let step = Int(progress.step) + 1
                let stepValue = Double(step) / Double(progress.stepCount)
                let batchValue = Double(store.batchProgress.index+1) / Double(store.batchProgress.total)
                
                Button(action: { self.isStatusPopoverShown.toggle() }) {
                    CircularProgressView(progress: stepValue)
                        .frame(width: 16, height: 16)
                }
                .popover(isPresented: self.$isStatusPopoverShown, arrowEdge: .bottom) {
                    let stepLabel = String(localized: "Step \(step) of \(progress.stepCount)",
                                           comment: "Step progress text showing current step progress and total steps selected")
                    let batchLabel = String(localized: "Batch \(store.batchProgress.index+1) of \(store.batchProgress.total)",
                                            comment: "Batch progress text showing current batch progress and total batches selected")
                    VStack(alignment: .center, spacing: 12) {
                        ProgressView(stepLabel, value: stepValue, total: 1)
                        
                        ProgressView(batchLabel, value: batchValue, total: 1)
                        
                        Button(action: store.stopGeneration) {
                            Text("Stop Generation")
                        }
                    }
                    .padding()
                    .frame(width: 300)
                }
            }
            else {
                Button(action: { self.isStatusPopoverShown.toggle() }) {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .scaleEffect(0.5)
                }
                .popover(isPresented: self.$isStatusPopoverShown, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Loading Model...")
                        Text("This wont take long",
                             comment: "Text explaining that loading the model wont take long")
                            .foregroundColor(.secondary)
                    }
                    .padding()
                }
            }
        }
        
        if let sdi = store.getSelectedImage(), let img = sdi.image {
            let imageView = Image(img, scale: 1, label: Text(verbatim: sdi.prompt))
            
            Button(action: store.removeCurrentImage) {
                Label {
                    Text("Remove",
                         comment: "Toolbar button to remove the selected image")
                } icon: {
                    Image(systemName: "trash")
                }
                .help("Remove")
            }
            Button(action: store.upscaleCurrentImage) {
                Label {
                    Text("Convert to High Resolution")
                } icon: {
                    Image(systemName: "wand.and.stars")
                }
                .help("Convert to High Resolution")
            }
            
            Spacer()

            Button(action: sdi.save) {
                Label {
                    Text("Save As...",
                         comment: "Toolbar button to show the save image dialog")
                } icon: {
                    Image(systemName: "square.and.arrow.down")
                }
                .help("Save As...")
            }
            ShareLink(item: imageView, preview: SharePreview(sdi.prompt, image: imageView))
                .help("Share...")
        }
        else {
            Button(action: {}) {
                Label {
                    Text("Remove",
                         comment: "Toolbar button to remove the selected image")
                } icon: {
                    Image(systemName: "trash")
                }
            }
            .disabled(true)
            Button(action: {}) {
                Label {
                    Text("Convert to High Resolution")
                } icon: {
                    Image(systemName: "wand.and.stars")
                }
            }
            .disabled(true)

            Spacer()
            
            Button(action: {}) {
                Label {
                    Text("Save As...",
                         comment: "Toolbar button to show the save image dialog")
                } icon: {
                    Image(systemName: "square.and.arrow.down")
                }
            }
            .disabled(true)
            Button(action: {}) {
                Label {
                    Text("Share...",
                         comment: "Toolbar button to show the system share sheet")
                } icon: {
                    Image(systemName: "square.and.arrow.up")
                }
            }
            .disabled(true)
        }
    }
}

struct GalleryToolbarView_Previews: PreviewProvider {
    static var previews: some View {
        GalleryToolbarView()
    }
}
