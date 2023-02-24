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
    @EnvironmentObject private var store: ImageStore

    var body: some View {
        VStack(spacing: 0) {
            if let sdi = store.selected(), let img = sdi.image {
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
                            callback: ImageController.shared.copyPromptToPrompt
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

extension CGImage {
    var averageColor: Color? {
        let inputImage = CIImage(cgImage: self)
        let extentVector = CIVector(
            x: inputImage.extent.origin.x,
            y: inputImage.extent.origin.y,
            z: inputImage.extent.size.width,
            w: inputImage.extent.size.height
        )

        guard let filter = CIFilter(
            name: "CIAreaAverage",
            parameters: [kCIInputImageKey: inputImage, kCIInputExtentKey: extentVector]
        ) else { return nil }
        guard let outputImage = filter.outputImage else { return nil }

        /// Bitmap consisting of (r, g, b, a) value
        var bitmap = [UInt8](repeating: 0, count: 4)
        let context = CIContext(options: [.workingColorSpace: kCFNull!])
        context.render(
            outputImage,
            toBitmap: &bitmap,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: nil
        )

        return Color(
            red: CGFloat(bitmap[0]) / 255,
            green: CGFloat(bitmap[1]) / 255,
            blue: CGFloat(bitmap[2]) / 255,
            opacity: CGFloat(bitmap[3]) / 255
        )
    }
}

struct InspectorView_Previews: PreviewProvider {
    static var previews: some View {
        InspectorView()
            .environmentObject(ImageStore.shared)
    }
}
