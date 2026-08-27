//
//  EngineView.swift
//  Mochi Diffusion
//

import SwiftUI

/// Picks the generation engine, which filters the model picker below it.
///
/// Every registered engine is listed, including ones that are unconfigured or have
/// no models, with the reason shown alongside. An engine that only appeared once it
/// was already configured would be one nobody discovers — which matters as soon as
/// a hosted engine needs an API key before it has any models to offer.
struct EngineView: View {
    @Environment(GenerationController.self) private var controller: GenerationController

    var body: some View {
        Text("Engine", comment: "Label for the generation engine picker")
            .sidebarLabelFormat()

        Picker("", selection: engineSelection) {
            ForEach(controller.engines) { engine in
                Text(verbatim: label(for: engine)).tag(Optional(engine.id))
            }
        }
        .labelsHidden()

        if let reason = unusableReason(for: controller.selectedEngine) {
            Text(verbatim: reason)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Routed through `selectEngine` rather than binding the stored property, so
    /// switching engines also restores that engine's remembered model.
    private var engineSelection: Binding<EngineID?> {
        Binding(
            get: { controller.selectedEngine },
            set: { newValue in
                guard let newValue else { return }
                controller.selectEngine(newValue)
            }
        )
    }

    /// The engine's name, with its reason appended when it cannot be used, so the
    /// menu itself says why without needing the row to be selected first.
    private func label(for engine: AnyGenerationEngine) -> String {
        guard let reason = unusableReason(for: engine.id) else {
            return engine.displayName
        }
        return "\(engine.displayName) — \(reason)"
    }

    /// Why `engine` cannot be used, or `nil` when it can.
    ///
    /// Availability comes first: an engine whose folder is missing or whose key is
    /// absent should say so, rather than reporting the empty model list that
    /// follows from it.
    private func unusableReason(for engine: EngineID?) -> String? {
        guard let engine else { return nil }
        switch controller.engineAvailability[engine] {
        case .needsConfiguration(let reason), .unreachable(let reason):
            return reason
        case .ready, nil:
            guard !controller.hasModels(engine) else { return nil }
            return String(
                localized: "No models found",
                comment: "Shown for an engine that is configured but has no models"
            )
        }
    }
}

#Preview {
    EngineView()
        .environment(GenerationController(configStore: ConfigStore()))
}
