//
//  ModelRepo.swift
//  Mochi Diffusion
//
//  Created by Jeffrey Thompson on 7/11/23.
//

import Foundation

protocol ModelRepo {
    var modelURL: URL { get }
    var controlNetURL: URL { get }

    func loadModels() throws -> [SDModel]
}
