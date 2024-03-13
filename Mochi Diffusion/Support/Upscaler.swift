//
//  Upscaler.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 12/30/22.
//

import CoreImage
import Vision

final class Upscaler {

    static let shared = Upscaler()

    private let request: VNCoreMLRequest

    init() {
        let config = MLModelConfiguration()
        /// Note: CPU & NE conflicts with Image Generation
        config.computeUnits = .cpuAndGPU

        /// Create a Vision instance using the image classifier's model instance
        guard let model = try? VNCoreMLModel(for: RealESRGAN(configuration: config).model) else {
            fatalError("Failed to create a `VNCoreMLModel` instance.")
        }

        /// Create an image classification request with an image classifier model
        request = VNCoreMLRequest(model: model) { request, _ in
            if let observations = request.results as? [VNClassificationObservation] {
                print(observations)
            }
        }

        self.request.imageCropAndScaleOption = .scaleFill
        /// output image's ratio will be fixed later
    }

    func upscale(cgImage: CGImage) async -> CGImage? {
        let handler = VNImageRequestHandler(cgImage: cgImage)
        let requests: [VNRequest] = [request]

        try? handler.perform(requests)
        guard let observation = self.request.results?.first as? VNPixelBufferObservation else {
            return nil
        }
        let upscaledWidth = cgImage.width * 4
        let upscaledHeight = cgImage.height * 4
        guard
            let pixelBuffer = resizePixelBuffer(
                observation.pixelBuffer,
                width: upscaledWidth,
                height: upscaledHeight
            )
        else { return nil }
        return self.convertPixelBufferToCGImage(pixelBuffer: pixelBuffer)
    }

    func upscale(sdi: SDImage) async -> SDImage? {
        if !sdi.upscaler.isEmpty { return nil }
        guard let cgImage = sdi.image else { return nil }
        guard let upscaledImage = await upscale(cgImage: cgImage) else { return nil }
        var upscaledSDI = sdi
        upscaledSDI.image = upscaledImage
        upscaledSDI.aspectRatio = CGFloat(Double(sdi.width) / Double(sdi.height))
        upscaledSDI.upscaler = "RealESRGAN"
        return upscaledSDI
    }

    private func convertPixelBufferToCGImage(pixelBuffer: CVPixelBuffer) -> CGImage? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext(options: nil)
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        return context.createCGImage(
            ciImage, from: CGRect(x: 0, y: 0, width: width, height: height))
    }
}
