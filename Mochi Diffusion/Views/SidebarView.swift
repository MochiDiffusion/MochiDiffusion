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
                    ModelView()
                    Spacer().frame(height: 6)
                }
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
                if controller.currentConstraints.numberOfImages.isSupported {
                    Group {
                        NumberOfImagesView()
                        Spacer().frame(height: 6)
                    }
                }
                if controller.currentConstraints.steps.isSupported {
                    Group {
                        StepsView()
                        Spacer().frame(height: 6)
                    }
                }
                if controller.currentConstraints.guidanceScale.isSupported {
                    Group {
                        GuidanceScaleView()
                        Spacer().frame(height: 6)
                    }
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
