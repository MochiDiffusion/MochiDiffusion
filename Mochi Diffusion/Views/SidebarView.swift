//
//  SidebarView.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 1/20/23.
//

import SwiftUI

struct SidebarView: View {
    @Environment(GenerationController.self) private var controller: GenerationController

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 6) {
                Group {
                    PromptView()
                    Divider().frame(height: 16)
                }
                Group {
                    EngineView()
                    Spacer().frame(height: 6)
                }
                Group {
                    ModelView()
                    Spacer().frame(height: 6)
                }
                // Whole sections are gated here rather than inside each view, so a
                // hidden section takes its divider and spacing with it. Individual
                // rows are never gated: they show a disabled field instead, so the
                // controls below them do not move when the model changes.
                // Two independent sections, not two spellings of one. A model may
                // denoise from an image, attend to references, do both, or neither.
                if controller.currentConstraints.startingImage.isSupported {
                    Group {
                        StartingImageView()
                        Divider().frame(height: 16)
                    }
                }
                if controller.currentConstraints.inputImages.isSupported {
                    Group {
                        InputImagesView()
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
                    QualityView()
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
                if controller.currentConstraints.controlNet.isSupported {
                    Group {
                        ControlNetView()
                    }
                }
            }
            .padding([.horizontal, .bottom])
        }
    }
}

#Preview {
    SidebarView()
        .environment(GenerationController(configStore: ConfigStore()))
        .environment(ConfigStore())
        .environment(FocusController())
        .environment(GenerationState.shared)
}
