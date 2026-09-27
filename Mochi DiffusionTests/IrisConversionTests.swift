//
//  IrisConversionTests.swift
//  Mochi DiffusionTests
//

import CoreGraphics
import Foundation
import Testing

@testable import Mochi_Diffusion

/// Pins the conversions between Mochi's values and the Iris C library's: the
/// 4-bit store for cached prompt embeddings, and the pixel copies between
/// `CGImage` and `iris_image`. None of these need model weights.
struct IrisConversionTests {

    // MARK: - Prompt embedding store

    /// The largest error a value may have: half of one of its block's 15 steps.
    private func maximumError(forBlockOf values: ArraySlice<Float>) -> Float {
        let range = (values.max() ?? 0) - (values.min() ?? 0)
        return range / 30 + 1e-5
    }

    @Test(
        "A stored embedding comes back within half a quantization step",
        arguments: [1, 31, 32, 33, 64, 101]
    )
    func embeddingRoundTripsWithinTheErrorBound(count: Int) {
        // Spread across a range wide enough that quantization is visible.
        let values = (0..<count).map { index in
            Float(sin(Double(index) * 0.7) * 3 + Double(index % 5))
        }

        let restored = QuantizedPromptEmbedding(values: values).dequantized()

        #expect(restored.count == values.count)
        let blockSize = QuantizedPromptEmbedding.blockSize
        for blockStart in stride(from: 0, to: count, by: blockSize) {
            let block = blockStart..<min(blockStart + blockSize, count)
            let bound = maximumError(forBlockOf: values[block])
            for index in block {
                #expect(abs(restored[index] - values[index]) <= bound)
            }
        }
    }

    /// Two values share each byte, so an odd count leaves a half-used last byte.
    @Test("An odd number of values packs into whole bytes")
    func oddCountPacksIntoWholeBytes() {
        let embedding = QuantizedPromptEmbedding(values: [0, 1, 2])

        #expect(embedding.packed.count == 2)
        #expect(embedding.dequantized().count == 3)
    }

    @Test("A block of equal values comes back unchanged")
    func constantBlockIsExact() {
        let values = [Float](repeating: -0.25, count: 40)

        let restored = QuantizedPromptEmbedding(values: values).dequantized()

        for value in restored {
            #expect(abs(value - -0.25) < 1e-6)
        }
    }

    /// Each block has its own minimum and range, so a block of large values does
    /// not cost precision in a block of small ones.
    @Test("Each block keeps its own range")
    func blocksAreQuantizedIndependently() {
        let blockSize = QuantizedPromptEmbedding.blockSize
        let small = (0..<blockSize).map { Float($0) * 0.001 }
        let large = (0..<blockSize).map { Float($0) * 100 }

        let restored = QuantizedPromptEmbedding(values: small + large).dequantized()

        let bound = maximumError(forBlockOf: small[...])
        for index in 0..<blockSize {
            #expect(abs(restored[index] - small[index]) <= bound)
        }
    }

    @Test("An empty embedding stores and restores nothing")
    func emptyEmbedding() {
        let embedding = QuantizedPromptEmbedding(values: [])

        #expect(embedding.packed.isEmpty)
        #expect(embedding.dequantized().isEmpty)
    }

    // MARK: - Pixel conversion

    private static let width = 4
    private static let height = 3

    /// A distinct opaque colour per pixel, row by row, in the device RGB space the
    /// converters use, so no colour conversion blurs the comparison.
    private static func pixel(x: Int, y: Int) -> [UInt8] {
        [UInt8(x * 60), UInt8(y * 80), UInt8(200 - x * 10 - y * 20), 255]
    }

    private static func makeSourceImage() throws -> CGImage {
        var bytes: [UInt8] = []
        for y in 0..<height {
            for x in 0..<width {
                bytes += pixel(x: x, y: y)
            }
        }
        let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
        return try #require(
            CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            )
        )
    }

    /// Redraws `image` into RGBA bytes in device RGB.
    private static func rgbaBytes(of image: CGImage) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let drew = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard
                let context = CGContext(
                    data: buffer.baseAddress,
                    width: image.width,
                    height: image.height,
                    bitsPerComponent: 8,
                    bytesPerRow: image.width * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        try #require(drew)
        return bytes
    }

    @Test("Encoded image data converts to an Iris image and back without changing a pixel")
    func pixelsRoundTripThroughIris() throws {
        let source = try Self.makeSourceImage()
        let data = try #require(source.pngData())

        let irisImage = try #require(IrisEngineRuntime.makeFluxImage(from: data))
        defer { iris_image_free(irisImage) }
        #expect(irisImage.pointee.width == Int32(Self.width))
        #expect(irisImage.pointee.height == Int32(Self.height))
        #expect(irisImage.pointee.channels == 4)

        let restored = try #require(IrisEngineRuntime.makeCGImage(from: UnsafePointer(irisImage)))

        #expect(restored.width == Self.width)
        #expect(restored.height == Self.height)
        #expect(try Self.rgbaBytes(of: restored) == Self.rgbaBytes(of: source))
    }

    /// Iris writes RGB output with three channels, which Core Graphics reads as
    /// opaque.
    @Test("A three-channel Iris image converts to an opaque image")
    func threeChannelImageIsOpaque() throws {
        let irisImage = try #require(
            iris_image_create(Int32(Self.width), Int32(Self.height), 3))
        defer { iris_image_free(irisImage) }
        let data = try #require(irisImage.pointee.data)
        for y in 0..<Self.height {
            for x in 0..<Self.width {
                let offset = (y * Self.width + x) * 3
                for (channel, value) in Self.pixel(x: x, y: y).prefix(3).enumerated() {
                    data[offset + channel] = value
                }
            }
        }

        let image = try #require(IrisEngineRuntime.makeCGImage(from: UnsafePointer(irisImage)))

        var expected: [UInt8] = []
        for y in 0..<Self.height {
            for x in 0..<Self.width {
                expected += Self.pixel(x: x, y: y)
            }
        }
        #expect(try Self.rgbaBytes(of: image) == expected)
    }

    @Test("An Iris image with an unsupported channel count is refused", arguments: [1, 2, 5])
    func unsupportedChannelCountIsRefused(channels: Int) throws {
        let irisImage = try #require(iris_image_create(2, 2, Int32(channels)))
        defer { iris_image_free(irisImage) }

        #expect(IrisEngineRuntime.makeCGImage(from: UnsafePointer(irisImage)) == nil)
    }

    @Test("Data that is not an image does not convert")
    func undecodableDataIsRefused() {
        #expect(IrisEngineRuntime.makeFluxImage(from: Data([1, 2, 3])) == nil)
    }
}
