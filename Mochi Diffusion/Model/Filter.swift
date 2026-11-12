//
//  Filter.swift
//  Mochi Diffusion
//
//  Created by Hossein on 10/12/24.
//

import Foundation

struct Filter: Identifiable, Equatable {
    let id = UUID()
    var text: String
    var element: FilterElement = .prompt
    var type: FilterType = .contains
    var condition: FilterCondition = .isEqual
}

enum FilterElement: String, CaseIterable {
    case prompt = "Prompt"
    case seed = "Seed"
    case negativePrompt = "Negative Prompt"
    case model = "Model"
    case steps = "Steps"
    case guidanceScale = "Guidance Scale"
    case lora = "LoRA"
}

enum FilterType: String, CaseIterable {
    case equals = "Equals"
    case contains = "Contains"
}

enum FilterCondition: String, CaseIterable {
    case isEqual = "= is"
    case isNotEqual = "≠ is not"
}

extension Filter {
    func validate(_ sdImage: SDImage) -> Bool {
        // An image passes when any of its values for the element matches, so a
        // LoRA filter finds every image that used that LoRA among others, and
        // "is not" keeps only the images where none of them match.
        let result = element.filterValues(from: sdImage).contains { value in
            switch type {
            case .contains:
                value.range(
                    of: text, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive])
                    != nil
            case .equals:
                value == text
            }
        }

        return condition == .isEqual ? result : !result
    }

    func humanReadable() -> String {
        return "\(element.rawValue)\(condition == .isEqual ? "" : " not ") \(type.rawValue) \(text)"
    }
}

extension Array where Element == Filter {
    func humanReadable() -> String {
        self.map({ $0.humanReadable() }).joined(separator: " and ")
    }
}

extension FilterElement {
    /// The image's values for this element. Most elements have one; an image
    /// has one per LoRA it used, matched by name without the weight.
    func filterValues(from sdImage: SDImage) -> [String] {
        switch self {
        case .prompt: [sdImage.prompt]
        case .seed: [String(sdImage.seed)]
        case .negativePrompt: [sdImage.negativePrompt]
        case .model: [sdImage.model]
        case .steps: [String(sdImage.steps)]
        case .guidanceScale: [String(sdImage.guidanceScale)]
        case .lora: sdImage.loras.map(\.name)
        }
    }
}
