//
//  Extensions.swift
//  Diffusion
//
//  Created by Fahim Farook on 12/17/2022.
//

import Foundation

extension String: Error {}

extension URL {
    func subDirectories() throws -> [URL] {
        guard hasDirectoryPath else { return [] }
        return try FileManager.default.contentsOfDirectory(at: self, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]).filter(\.hasDirectoryPath)
    }
}

extension Formatter {
    static let seedFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimum = 0
        formatter.maximum = NSNumber(value: UInt32.max) // 4_294_967_295
        formatter.maximumFractionDigits = 0
        formatter.usesGroupingSeparator = false
        formatter.hasThousandSeparators = false
        formatter.alwaysShowsDecimalSeparator = false
        formatter.zeroSymbol = ""
        return formatter
    }()
}
