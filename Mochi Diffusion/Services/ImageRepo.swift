//
//  ImageRepo.swift
//  Mochi Diffusion
//
//  Created by Jeffrey Thompson on 7/11/23.
//

import Foundation

enum ImageRepoError: Error {
    case couldNotCreateImage
}

protocol ImageRepo {
    var imagesURL: URL { get }

    func importImage(from url: URL) throws -> SDImage
    func loadImages() throws -> [SDImage]
    func save(image: SDImage) throws
    func delete(image: SDImage, moveToTrash: Bool) throws
}
