//
//  InspectorView.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 12/19/22.
//

import CoreML
import StableDiffusion
import SwiftUI

struct InfoGridRow: View {
    var type: LocalizedStringKey
    var text: String
    var showCopyToPromptOption: Bool
    var callback: (@MainActor () -> Void)?

    var body: some View {
        GridRow {
            Text("")
            Text(type)
                .helpTextFormat()
        }
        GridRow {
            if showCopyToPromptOption {
                Button {
                    guard let callbackFn = callback else { return }
                    callbackFn()
                } label: {
                    Image(systemName: "arrow.left.circle.fill")
                        .foregroundColor(Color.secondary)
                }
                .buttonStyle(PlainButtonStyle())
                .help("Copy Option to Sidebar")
            } else {
                Text("")
            }

            Text(text)
                .selectableTextFormat()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        Spacer().frame(height: 12)
    }
}

struct InspectorView: View {
    @EnvironmentObject private var controller: ImageController

    var body: some View {
        VStack(spacing: 0) {
            if let sdi = controller.selectedImage, let img = sdi.image {
                Image(img, scale: 1, label: Text(verbatim: String(sdi.prompt)))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(4)
                    .shadow(color: sdi.image?.averageColor ?? .black, radius: 16)
                    .padding()

                ScrollView(.vertical) {
                    Grid(alignment: .leading, horizontalSpacing: 4) {
                        InfoGridRow(
                            type: LocalizedStringKey(Metadata.date.rawValue),
                            text: sdi.generatedDate.formatted(date: .long, time: .standard),
                            showCopyToPromptOption: false
                        )
                        InfoGridRow(
                            type: LocalizedStringKey(Metadata.model.rawValue),
                            text: sdi.model,
                            showCopyToPromptOption: false
                        )
                        InfoGridRow(
                            type: LocalizedStringKey(Metadata.size.rawValue),
                            text: "\(sdi.width) x \(sdi.height)\(!sdi.upscaler.isEmpty ? " (Upscaled using \(sdi.upscaler))" : "")",
                            showCopyToPromptOption: false
                        )
                        InfoGridRow(
                            type: LocalizedStringKey(Metadata.includeInImage.rawValue),
                            text: sdi.prompt,
                            showCopyToPromptOption: true,
                            callback: ImageController.shared.copyToPrompt
                        )
                        InfoGridRow(
                            type: LocalizedStringKey(Metadata.excludeFromImage.rawValue),
                            text: sdi.negativePrompt,
                            showCopyToPromptOption: true,
                            callback: ImageController.shared.copyNegativePromptToPrompt
                        )
                        InfoGridRow(
                            type: LocalizedStringKey(Metadata.seed.rawValue),
                            text: String(sdi.seed),
                            showCopyToPromptOption: true,
                            callback: ImageController.shared.copySeedToPrompt
                        )
                        InfoGridRow(
                            type: LocalizedStringKey(Metadata.steps.rawValue),
                            text: String(sdi.steps),
                            showCopyToPromptOption: true,
                            callback: ImageController.shared.copyStepsToPrompt
                        )
                        InfoGridRow(
                            type: LocalizedStringKey(Metadata.guidanceScale.rawValue),
                            text: String(sdi.guidanceScale),
                            showCopyToPromptOption: true,
                            callback: ImageController.shared.copyGuidanceScaleToPrompt
                        )
                        InfoGridRow(
                            type: LocalizedStringKey(Metadata.scheduler.rawValue),
                            text: sdi.scheduler.rawValue,
                            showCopyToPromptOption: true,
                            callback: ImageController.shared.copySchedulerToPrompt
                        )
                        InfoGridRow(
                            type: LocalizedStringKey(Metadata.mlComputeUnit.rawValue),
                            text: MLComputeUnits.toString(sdi.mlComputeUnit),
                            showCopyToPromptOption: false
                        )
                    }
                }
                .padding([.horizontal])

                Divider()

                HStack {
                    Button {
                        ImageController.shared.copyToPrompt()
                    } label: {
                        Text(
                            "Copy Options to Sidebar",
                            comment: "Button to copy the currently selected image's generation options to the prompt input sidebar"
                        )
                    }
                    Button {
                        let info = getHumanReadableInfo(sdi)
                        let pasteboard = NSPasteboard.general
                        pasteboard.declareTypes([.string], owner: nil)
                        pasteboard.setString(info, forType: .string)
                    } label: {
                        Text(
                            "Copy",
                            comment: "Button to copy the currently selected image's generation options to the clipboard"
                        )
                    }
                }
                .padding()
            } else {
                Text(
                    "No Info",
                    comment: "Placeholder text for image inspector"
                )
                .font(.title2)
                .foregroundColor(.secondary)
            }
        }
    }
}

struct InspectorView_Previews: PreviewProvider {
    static var previews: some View {
        InspectorView()
            .environmentObject(ImageController.shared)
    }
}
