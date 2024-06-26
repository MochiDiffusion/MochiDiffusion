//
//  HelpCommands.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 12/17/22.
//
import SwiftUI

struct HelpCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .help) {
            Section {
                Link(
                    "Release Notes",
                    destination: URL(
                        string: "https://github.com/MochiDiffusion/MochiDiffusion/releases")!
                )
                Link(
                    "Website",
                    destination: URL(string: "https://github.com/MochiDiffusion/MochiDiffusion")!
                )
                Link(
                    "Improve Translation",
                    destination: URL(string: "https://crowdin.com/project/mochi-diffusion")!
                )
            }
            Section {
                Link(
                    "Download Models",
                    destination: URL(string: "https://huggingface.co/coreml-community")!
                )
            }
        }
    }
}
