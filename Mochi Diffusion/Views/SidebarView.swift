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
                    Spacer().frame(height: 6)
                }
                Group {
                    ModelView()
                }
            }
            .padding([.horizontal, .bottom])
        }
    }
}

struct SidebarView_Previews: PreviewProvider {
    static let genStore = GeneratorStore()

    static var previews: some View {
        SidebarView()
            .environmentObject(genStore)
    }
}
