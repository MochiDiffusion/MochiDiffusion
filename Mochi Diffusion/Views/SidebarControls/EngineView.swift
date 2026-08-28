//
//  EngineView.swift
//  Mochi Diffusion
//

import SwiftUI

/// Picks the generation engine, which filters the model picker below it.
///
/// Only engines that can actually be generated with are offered, plus whichever is
/// selected. Listing every registered engine put unusable options on the surface a
/// user looks at for every generation, and most people use one or two — Settings ▸
/// Engines lists all of them, and that is where an engine is discovered and
/// configured.
///
/// When none is usable the picker holds a placeholder rather than going empty. It
/// is plainly not an engine, so it can come and go without looking like something
/// was taken away; a real engine disappearing is the thing that would be
/// inexplicable.
struct EngineView: View {
    @Environment(GenerationController.self) private var controller: GenerationController

    var body: some View {
        Text("Engine", comment: "Label for the generation engine picker")
            .sidebarLabelFormat()

        Picker("", selection: engineSelection) {
            if controller.pickerEngines.isEmpty {
                // Tagged `nil` so it is selected on its own: nothing is chosen in
                // this state, and `restoreSelection` deliberately leaves it that
                // way rather than picking an engine that cannot run.
                Text(verbatim: Self.placeholderLabel).tag(EngineID?.none)
            }
            ForEach(controller.pickerEngines) { engine in
                Text(verbatim: label(for: engine)).tag(Optional(engine.id))
            }
        }
        .labelsHidden()
        .disabled(controller.pickerEngines.isEmpty)

        // One caption line is held open whether or not there is a reason to show,
        // so an engine that reports one does not push the model picker below it
        // down. A hidden placeholder rather than an empty string, whose height
        // SwiftUI does not promise.
        ZStack(alignment: .topLeading) {
            Text(verbatim: "0")
                .font(.caption)
                .hidden()

            if let caption {
                Text(verbatim: caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// An em dash, matching the disabled option rows elsewhere in the sidebar.
    private static var placeholderLabel: String { "\u{2014}" }

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
    /// menu itself says why without needing the row to be selected first. Only the
    /// selected engine can be unusable and still listed, so in practice this
    /// annotates that one row.
    private func label(for engine: AnyGenerationEngine) -> String {
        guard let reason = unusableReason(for: engine.id) else {
            return engine.displayName
        }
        return "\(engine.displayName) — \(reason)"
    }

    /// What to say under the picker.
    ///
    /// The placeholder needs explaining — a control showing an em dash with no
    /// reason is the kind of thing that reads as a bug — so this states the two
    /// ways out of that state rather than leaving the user to guess.
    private var caption: String? {
        guard !controller.pickerEngines.isEmpty else {
            return String(
                localized:
                    "No engine is ready. Add models to your models folder, or an API key in Settings.",
                comment: "Shown under the engine picker when no engine can be used"
            )
        }
        return unusableReason(for: controller.selectedEngine)
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
