//
//  LoraView.swift
//  Mochi Diffusion
//

import AppKit
import SwiftUI

struct LoraView: View {
    @Environment(GenerationController.self) private var controller: GenerationController
    @Environment(ConfigStore.self) private var configStore: ConfigStore
    @State private var isNotesPopoverShown = false

    private var loraNoteBinding: Binding<String> {
        Binding(
            get: { controller.currentLoraNote },
            set: { controller.setCurrentLoraNote($0) }
        )
    }

    private var notesIconName: String {
        controller.currentLoraHasNote ? "note.text" : "note.text.badge.plus"
    }

    var body: some View {
        @Bindable var controller = controller

        Text("LoRA")
            .sidebarLabelFormat()

        HStack {
            Picker("", selection: $controller.currentLora) {
                Text(
                    "None",
                    comment: "Option to not apply a LoRA"
                )
                .tag(Optional<String>.none)

                ForEach(controller.loras, id: \.self) { lora in
                    Text(verbatim: lora).tag(Optional(lora))
                }
            }
            .labelsHidden()

            Button {
                NSWorkspace.shared.open(
                    ModelRepository.loraDirectoryURL(fromPath: configStore.loraDir)
                )
            } label: {
                Image(systemName: "folder")
            }
            .help("Show LoRAs in Finder")

            Button {
                isNotesPopoverShown.toggle()
            } label: {
                Image(systemName: notesIconName)
            }
            .help("LoRA notes")
            .disabled(controller.currentLora == nil)
            .popover(isPresented: $isNotesPopoverShown, arrowEdge: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(verbatim: controller.currentLora ?? "")
                        .font(.headline)

                    TextEditor(text: loraNoteBinding)
                        .font(.body)
                        .frame(width: 280, height: 140)

                    HStack {
                        Spacer()
                        Button("Done") {
                            isNotesPopoverShown = false
                        }
                    }
                }
                .padding()
            }
        }
    }
}
