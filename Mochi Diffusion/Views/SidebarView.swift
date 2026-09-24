//
//  SidebarView.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 1/20/23.
//

import AppKit
import SwiftUI

struct SidebarView: View {
    @Environment(GenerationController.self) private var controller: GenerationController

    /// With the "Always show" scrollbar setting, the scroller occupies a real gutter, but only
    /// while the content overflows. Reserving the gutter at all times keeps the content width
    /// constant. Overlay scrollers take no space, so `scrollerGutter` is zero and nothing changes.
    @State private var scrollerStyle = NSScroller.preferredScrollerStyle

    private var scrollerGutter: CGFloat {
        scrollerStyle == .legacy
            ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
            : 0
    }

    var body: some View {
        GeometryReader { proxy in
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
                    Group {
                        SizeView()
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
                    if controller.currentConstraints.controlNet.isSupported {
                        Group {
                            ControlNetView()
                        }
                    }
                }
                .padding([.horizontal, .bottom])
                .frame(width: max(0, proxy.size.width - scrollerGutter), alignment: .leading)
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSScroller.preferredScrollerStyleDidChangeNotification
            )
        ) { _ in
            scrollerStyle = NSScroller.preferredScrollerStyle
        }
    }
}
