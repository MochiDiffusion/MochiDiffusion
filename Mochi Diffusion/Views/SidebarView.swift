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
                    Divider().frame(height: 20)
                }
                Group {
                    ModelView()
                    Divider().frame(height: 24)
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
                    Divider().frame(height: 20)
                }
                Group {
                    StartingImageView()
                    Divider().frame(height: 24)
                }
                Group {
                    ControlNetView()
                    Divider().frame(height: 24)
                }
            }
            .padding([.horizontal, .bottom])
        }
    }
}

struct SidebarView_Previews: PreviewProvider {
    static var previews: some View {
        SidebarView()
    }
}
