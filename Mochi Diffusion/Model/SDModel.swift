//
//  SDModel.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 2/12/23.
//

import Foundation

struct SDModel: Identifiable, Hashable {
    var id = UUID()
    var url: URL
    var name: String

    func hash(into hasher: inout Hasher) {
        hasher.combine(name)
    }
}
