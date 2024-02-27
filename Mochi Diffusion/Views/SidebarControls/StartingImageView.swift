//
//  StartingImageView.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 2/27/23.
//

import SwiftUI

struct StartingImageView: View {
    @EnvironmentObject private var controller: ImageController
    @State private var isInfoPopoverShown = false
    @State private var isMaskPopoverShown = false
    @State private var maskImage: NSImage? = nil

    var body: some View {
        Text(
            "Starting Image",
            comment: "Label for setting the starting image (commonly known as image2image)"
        )
        .sidebarLabelFormat()

        HStack(alignment: .top) {
            ImageWellView(image: controller.startingImage, size: CGSize(width: controller.width, height: controller.height)) { image in
                maskImage = nil
                controller.maskImage = nil
                if let image {
                    ImageController.shared.setStartingImage(image: image)
                } else {
                    await ImageController.shared.unsetStartingImage()
                }
            }
            .frame(width: 90, height: 90)
            .overlay(
                Image(nsImage: controller.maskImage.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) } ?? NSImage())
                .resizable()
                .aspectRatio(contentMode: .fit)
            )
            
            Spacer()

            VStack(alignment: .trailing) {
                HStack {
                    Button {
                        maskImage = nil
                        Task { await ImageController.shared.selectStartingImage() }
                    } label: {
                        Image(systemName: "photo")
                    }

                    Button {
                        self.isMaskPopoverShown.toggle()
                    } label: {
                        Image(systemName: "paintbrush")
                    }
                    .disabled(controller.startingImage == nil)
                    
                    Button {
                        maskImage = nil
                        controller.maskImage = nil
                        Task { await ImageController.shared.unsetStartingImage() }
                    } label: {
                        Image(systemName: "xmark")
                    }
                }
            }
        }

        HStack {
            Text(
                "Strength",
                comment: "Label for starting image strength slider control"
            )
            .sidebarLabelFormat()

            Spacer()

            Button {
                self.isInfoPopoverShown.toggle()
            } label: {
                Image(systemName: "info.circle")
                    .foregroundColor(Color.secondary)
            }
            .buttonStyle(PlainButtonStyle())
            .popover(isPresented: self.$isInfoPopoverShown, arrowEdge: .top) {
                Text(
                    """
                    Strength controls how closely the generated image resembles the starting image.
                    Use lower values to generate images that look similar to the starting image.
                    Use higher values to allow more creative freedom.

                    The size of the starting image must match the output image size of the current model.
                    """
                )
                .padding()
            }
        }
        MochiSlider(value: $controller.strength, bounds: 0.0...1.0, step: 0.05)
            .popover(isPresented: self.$isMaskPopoverShown, arrowEdge: .top) {
                let screenHeight = NSScreen.main?.frame.height ?? 0
                let screenWidth = NSScreen.main?.frame.width ?? 0
                let aspectRatio = CGSize(width: controller.width, height: controller.height).aspectRatio
                if aspectRatio <= 1{
                    MaskEditorView(startingImage: controller.startingImage?.scaledAndCroppedTo(size: CGSize(width: (screenHeight * aspectRatio * 0.6).rounded(), height: (screenHeight * 0.6).rounded())), maskImage: $maskImage)
                }else{
                    MaskEditorView(startingImage: controller.startingImage?.scaledAndCroppedTo(size: CGSize(width: (screenWidth * 0.5).rounded(), height: (screenWidth / aspectRatio * 0.5).rounded())), maskImage: $maskImage)
                }
            }
    }
}

struct PathWrapper: Identifiable {
    let id = UUID()
    let path: Path
}

struct MaskEditorView: View {
    @EnvironmentObject private var controller: ImageController
    let startingImage: CGImage?
    @Binding var maskImage: NSImage?
    @State private var startPoint: CGPoint?
    @State private var endPoint: CGPoint?
    @State private var paths: [PathWrapper] = []
    @State private var radius: CGFloat = 50
    
    var body: some View {
        VStack(alignment: .trailing){
            ZStack {
                if let startingImage = startingImage {
                    Image(nsImage: NSImage(cgImage: startingImage, size: NSSize(width: startingImage.width, height: startingImage.height)))
                        .aspectRatio(contentMode: .fit)
                }
                if let maskImage = maskImage {
                    Image(nsImage: maskImage)
                        .aspectRatio(contentMode: .fit)
                }
            }
            HStack{
                Spacer()
                Button {
                    paths.removeAll()
                    maskImage = nil
                    controller.maskImage = nil
                } label: {
                    Image(systemName: "arrow.clockwise.circle")
                        .font(.system(size: 30))
                }
                    .buttonBorderShape(.circle)
                    .padding(20)

                Slider(value: $radius, in: 30...150, step: 5)
                Spacer()
            }
            Spacer()
        }

        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if startPoint == nil {
                        startPoint = value.location
                    } else {
                        endPoint = value.location
                        updateMaskImage()
                    }
                }
                .onEnded { _ in
                    startPoint = nil
                    endPoint = nil
                    controller.maskImage = maskImage?.cgImage
                }
        )
    }
    
    func updateMaskImage() {
        guard let endPoint = endPoint else { return }

        let center = CGPoint(x: (endPoint.x) , y: (endPoint.y))
        let adjustedY = CGFloat(startingImage?.height ?? 0) - center.y

        let path = Path { path in
            path.addEllipse(in: CGRect(x: center.x - radius, y: adjustedY - radius, width: radius * 2, height: radius * 2))
        }
        paths.append(PathWrapper(path: path))
        drawPaths()
    }
    
    func drawPaths() {
        guard let startingImage = startingImage else { return }
        let imageSize = CGSize(width: startingImage.width, height: startingImage.height)
        let imageRect = CGRect(origin: .zero, size: imageSize)
        
        let width = Int(imageSize.width)
        let height = Int(imageSize.height)

        guard let maskContext = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }

        maskContext.clear(imageRect)

        maskContext.setFillColor(CGColor.black)
        maskContext.setBlendMode(.normal)

        for pathWrapper in paths {
            maskContext.addPath(pathWrapper.path.cgPath)
            maskContext.fillPath()
        }

        if let maskCGImage = maskContext.makeImage() {
            let maskImage = NSImage(cgImage: maskCGImage, size: imageSize)
            self.maskImage = maskImage
        }
    }
}


#Preview {
    StartingImageView()
        .environmentObject(ImageController.shared)
}
