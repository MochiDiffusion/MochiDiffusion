//
//  SidebarView.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 1/20/23.
//

import SwiftUI

struct SidebarView: View {
    @Environment(GenerationController.self) private var controller: GenerationController

    private var generationCapabilities: GenerationCapabilities {
        controller.currentModel?.config.generationCapabilities ?? []
    }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 6) {
                Group {
                    PromptView()
                    Divider().frame(height: 16)
                }
                Group {
                    ModelView()
                    Spacer().frame(height: 6)
                    LoraView()
                    Spacer().frame(height: 6)
                }
                Group {
                    if generationCapabilities.contains(.inputImages) {
                        InputImagesView()
                        Divider().frame(height: 16)
                    } else if generationCapabilities.contains(.startingImage) {
                        StartingImageView()
                        Divider().frame(height: 16)
                    }
                }
                Group {
                    SizeView()
                    Spacer().frame(height: 6)
                }
                Group {
                    NumberOfImagesView()
                    Spacer().frame(height: 6)
                }
                Group {
                    StepsView()
                    Spacer().frame(height: 6)
                }
                Group {
                    GuidanceScaleView()
                    Spacer().frame(height: 6)
                }
                Group {
                    SeedView()
                    Divider().frame(height: 16)
                }
                Group {
                    ControlNetView()
                }
            }
            .padding([.horizontal, .bottom])
        }
    }
}
