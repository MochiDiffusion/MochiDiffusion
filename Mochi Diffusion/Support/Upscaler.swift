//
//  Upscaler.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 12/30/22.
//

import CoreImage
import Vision

class Upscaler {
    private var request: VNCoreMLRequest

    init() {
        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndGPU // Note: CPU & NE conflicts with Image Generation

        // Create a Vision instance using the image classifier's model instance
        guard let model = try? VNCoreMLModel(for: RealESRGAN(configuration: config).model) else {
            fatalError("App failed to create a `VNCoreMLModel` instance.")
        }

        // Create an image classification request with an image classifier model
        request = VNCoreMLRequest(model: model) { request, _ in
            if let observations = request.results as? [VNClassificationObservation] {
                print(observations)
            }
        }

        self.request.imageCropAndScaleOption = .scaleFill // output image's ratio will be fixed later
        self.request.usesCPUOnly = false
    }

    func upscale(cgImage: CGImage) -> CGImage? {
        let handler = VNImageRequestHandler(cgImage: cgImage)
        let requests: [VNRequest] = [request]

        try? handler.perform(requests)
        guard let observation = self.request.results?.first as? VNPixelBufferObservation else { return nil }
        let upscaledWidth = cgImage.width * 4
        let upscaledHeight = cgImage.height * 4
        guard let pixelBuffer = resizePixelBuffer(
            observation.pixelBuffer,
            width: upscaledWidth,
            height: upscaledHeight
        ) else { return nil }
        return self.convertPixelBufferToCGImage(pixelBuffer: pixelBuffer)
    }

    private func convertPixelBufferToCGImage(pixelBuffer: CVPixelBuffer) -> CGImage? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext(options: nil)
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        return context.createCGImage(ciImage, from: CGRect(x: 0, y: 0, width: width, height: height))
    }
}
