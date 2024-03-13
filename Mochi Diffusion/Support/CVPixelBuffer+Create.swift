//  Copyright (c) 2017-2021 M.I. Hollemans
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to
//  deal in the Software without restriction, including without limitation the
//  rights to use, copy, modify, merge, publish, distribute, sublicense, and/or
//  sell copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
//  FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
//  IN THE SOFTWARE.

import Accelerate
import Foundation

private func metalCompatiblityAttributes() -> [String: Any] {
    let attributes: [String: Any] = [
        String(kCVPixelBufferMetalCompatibilityKey): true,
        String(kCVPixelBufferIOSurfacePropertiesKey): [
            String(kCVPixelBufferIOSurfaceCoreAnimationCompatibilityKey): true
        ],
    ]
    return attributes
}

/// Creates a pixel buffer of the specified width, height, and pixel format.
///
/// - Note: This pixel buffer is backed by an IOSurface and therefore can be
///   turned into a Metal texture.
public func createPixelBuffer(width: Int, height: Int, pixelFormat: OSType) -> CVPixelBuffer? {
    let attributes = metalCompatiblityAttributes() as CFDictionary
    var pixelBuffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(nil, width, height, pixelFormat, attributes, &pixelBuffer)
    if status != kCVReturnSuccess {
        print("Error: could not create pixel buffer", status)
        return nil
    }
    return pixelBuffer
}

/// Creates a RGB pixel buffer of the specified width and height.
public func createPixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
    createPixelBuffer(width: width, height: height, pixelFormat: kCVPixelFormatType_32BGRA)
}

extension CVPixelBuffer {
    /// Copies a CVPixelBuffer to a new CVPixelBuffer that is compatible with Metal.
    ///
    /// - Tip: If CVMetalTextureCacheCreateTextureFromImage is failing, then call
    /// this method first!
    public func copyToMetalCompatible() -> CVPixelBuffer? {
        deepCopy(withAttributes: metalCompatiblityAttributes())
    }

    /// Copies a CVPixelBuffer to a new CVPixelBuffer.
    ///
    /// This lets you specify new attributes, such as whether the new CVPixelBuffer
    /// must be IOSurface-backed.
    ///
    /// See: https://developer.apple.com/library/archive/qa/qa1781/_index.html
    public func deepCopy(withAttributes attributes: [String: Any] = [:]) -> CVPixelBuffer? {
        let srcPixelBuffer = self
        let srcFlags: CVPixelBufferLockFlags = .readOnly
        guard kCVReturnSuccess == CVPixelBufferLockBaseAddress(srcPixelBuffer, srcFlags) else {
            return nil
        }
        defer { CVPixelBufferUnlockBaseAddress(srcPixelBuffer, srcFlags) }

        var combinedAttributes: [String: Any] = [:]

        // Copy attachment attributes.
        if let attachments = CVBufferCopyAttachments(srcPixelBuffer, .shouldPropagate)
            as? [String: Any]
        {
            for (key, value) in attachments {
                combinedAttributes[key] = value
            }
        }

        // Add user attributes.
        combinedAttributes = combinedAttributes.merging(attributes) { $1 }

        var maybePixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            CVPixelBufferGetWidth(srcPixelBuffer),
            CVPixelBufferGetHeight(srcPixelBuffer),
            CVPixelBufferGetPixelFormatType(srcPixelBuffer),
            combinedAttributes as CFDictionary,
            &maybePixelBuffer
        )

        guard status == kCVReturnSuccess, let dstPixelBuffer = maybePixelBuffer else {
            return nil
        }

        let dstFlags = CVPixelBufferLockFlags(rawValue: 0)
        guard kCVReturnSuccess == CVPixelBufferLockBaseAddress(dstPixelBuffer, dstFlags) else {
            return nil
        }
        defer { CVPixelBufferUnlockBaseAddress(dstPixelBuffer, dstFlags) }

        for plane in 0...max(0, CVPixelBufferGetPlaneCount(srcPixelBuffer) - 1) {
            if let srcAddr = CVPixelBufferGetBaseAddressOfPlane(srcPixelBuffer, plane),
                let dstAddr = CVPixelBufferGetBaseAddressOfPlane(dstPixelBuffer, plane)
            {
                let srcBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(srcPixelBuffer, plane)
                let dstBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(dstPixelBuffer, plane)

                for height in 0..<CVPixelBufferGetHeightOfPlane(srcPixelBuffer, plane) {
                    let srcPtr = srcAddr.advanced(by: height * srcBytesPerRow)
                    let dstPtr = dstAddr.advanced(by: height * dstBytesPerRow)
                    dstPtr.copyMemory(from: srcPtr, byteCount: srcBytesPerRow)
                }
            }
        }
        return dstPixelBuffer
    }
}
