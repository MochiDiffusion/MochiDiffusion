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
import CoreImage
import Foundation

/// First crops the pixel buffer, then resizes it.
///
/// This function requires the caller to pass in both the source and destination
/// pixel buffers. The dimensions of destination pixel buffer should be at least
/// `scaleWidth` x `scaleHeight` pixels.
public func resizePixelBuffer(
    from srcPixelBuffer: CVPixelBuffer,
    to dstPixelBuffer: CVPixelBuffer,
    cropX: Int,
    cropY: Int,
    cropWidth: Int,
    cropHeight: Int,
    scaleWidth: Int,
    scaleHeight: Int
) {
    assert(CVPixelBufferGetWidth(dstPixelBuffer) >= scaleWidth)
    assert(CVPixelBufferGetHeight(dstPixelBuffer) >= scaleHeight)

    let srcFlags = CVPixelBufferLockFlags.readOnly
    let dstFlags = CVPixelBufferLockFlags(rawValue: 0)

    guard kCVReturnSuccess == CVPixelBufferLockBaseAddress(srcPixelBuffer, srcFlags) else {
        print("Error: could not lock source pixel buffer")
        return
    }
    defer { CVPixelBufferUnlockBaseAddress(srcPixelBuffer, srcFlags) }

    guard kCVReturnSuccess == CVPixelBufferLockBaseAddress(dstPixelBuffer, dstFlags) else {
        print("Error: could not lock destination pixel buffer")
        return
    }
    defer { CVPixelBufferUnlockBaseAddress(dstPixelBuffer, dstFlags) }

    guard let srcData = CVPixelBufferGetBaseAddress(srcPixelBuffer),
        let dstData = CVPixelBufferGetBaseAddress(dstPixelBuffer)
    else {
        print("Error: could not get pixel buffer base address")
        return
    }

    let srcBytesPerRow = CVPixelBufferGetBytesPerRow(srcPixelBuffer)
    let offset = cropY * srcBytesPerRow + cropX * 4
    var srcBuffer = vImage_Buffer(
        data: srcData.advanced(by: offset),
        height: vImagePixelCount(cropHeight),
        width: vImagePixelCount(cropWidth),
        rowBytes: srcBytesPerRow
    )

    let dstBytesPerRow = CVPixelBufferGetBytesPerRow(dstPixelBuffer)
    var dstBuffer = vImage_Buffer(
        data: dstData,
        height: vImagePixelCount(scaleHeight),
        width: vImagePixelCount(scaleWidth),
        rowBytes: dstBytesPerRow
    )

    let error = vImageScale_ARGB8888(&srcBuffer, &dstBuffer, nil, vImage_Flags(0))
    if error != kvImageNoError {
        print("Error:", error)
    }
}

/// First crops the pixel buffer, then resizes it.
///
/// This allocates a new destination pixel buffer that is Metal-compatible.
public func resizePixelBuffer(
    _ srcPixelBuffer: CVPixelBuffer,
    cropX: Int,
    cropY: Int,
    cropWidth: Int,
    cropHeight: Int,
    scaleWidth: Int,
    scaleHeight: Int
) -> CVPixelBuffer? {
    let pixelFormat = CVPixelBufferGetPixelFormatType(srcPixelBuffer)
    let dstPixelBuffer = createPixelBuffer(
        width: scaleWidth,
        height: scaleHeight,
        pixelFormat: pixelFormat
    )

    if let dstPixelBuffer = dstPixelBuffer {
        CVBufferPropagateAttachments(srcPixelBuffer, dstPixelBuffer)

        resizePixelBuffer(
            from: srcPixelBuffer,
            to: dstPixelBuffer,
            cropX: cropX,
            cropY: cropY,
            cropWidth: cropWidth,
            cropHeight: cropHeight,
            scaleWidth: scaleWidth,
            scaleHeight: scaleHeight
        )
    }

    return dstPixelBuffer
}

/// Resizes a CVPixelBuffer to a new width and height.
///
/// This allocates a new destination pixel buffer that is Metal-compatible.
public func resizePixelBuffer(
    _ pixelBuffer: CVPixelBuffer,
    width: Int,
    height: Int
) -> CVPixelBuffer? {
    resizePixelBuffer(
        pixelBuffer,
        cropX: 0,
        cropY: 0,
        cropWidth: CVPixelBufferGetWidth(pixelBuffer),
        cropHeight: CVPixelBufferGetHeight(pixelBuffer),
        scaleWidth: width,
        scaleHeight: height
    )
}
