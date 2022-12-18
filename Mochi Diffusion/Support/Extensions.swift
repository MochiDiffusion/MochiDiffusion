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
