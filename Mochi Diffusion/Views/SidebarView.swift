//
//  SidebarView.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 1/20/23.
//

import SwiftUI

struct SidebarView: View {
    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 6) {
                Group {
                    PromptView()
                    Divider().frame(height: 16)
                }
                Group {
                    StartingImageView()
                    Divider().frame(height: 16)
                }
                Group {
                    ModelView()
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

#Preview {
    SidebarView()
}
