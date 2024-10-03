//
//  SDStyle.swift
//  Mochi Diffusion
//
//  Created by Akash k on 03/10/24.
//

import Foundation

struct SDStyles {
    var styleName: String
    var SDStyleData: [SDStyleData] = []

    init?(url: URL) {
        
        let fileName = url.getFileName(dropExtension: true)
        let cleanedVersion = fileName.components(separatedBy: "_").last
        styleName = cleanedVersion ?? fileName

        guard let jsonData = try? Data(contentsOf: url) else {
            return nil
        }

        guard
            let jsonArray = (try? JSONSerialization.jsonObject(with: jsonData)) as? [[String: Any]]
        else {
            print("Error: Could not parse JSON data")
            return nil
        }
        SDStyleData = jsonArray.compactMap{ Mochi_Diffusion.SDStyleData($0) }
    }
}

struct SDStyleData {
    let name: String
    let prompt: String?
    let negative_prompt: String?

    init?(_ dict: [String: Any]) {
        guard
            let name = dict["name"] as? String else {
            return nil
        }
        self.name = name
        prompt = dict["prompt"] as? String
        negative_prompt = dict["negative_prompt"] as? String
    }
}

