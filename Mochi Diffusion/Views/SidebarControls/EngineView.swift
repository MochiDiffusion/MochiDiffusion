//
//  EngineView.swift
//  Mochi Diffusion
//

import SwiftUI

/// Picks the generation engine, which filters the model picker below it.
///
/// Offers only engines that can be generated with, plus whichever is selected.
/// Settings ▸ Engines lists every engine, and is where one is configured.
///
/// A placeholder holds the picker when none is usable, rather than going empty.
struct EngineView: View {
    @Environment(GenerationController.self) private var controller: GenerationController

    var body: some View {
        Text("Engine", comment: "Label for the generation engine picker")
            .sidebarLabelFormat()

        Picker("", selection: engineSelection) {
            if controller.pickerEngines.isEmpty {
                // Tagged `nil`, which is what `restoreSelection` leaves the
                // selection as when no engine can run.
                Text(verbatim: Self.placeholderLabel).tag(EngineID?.none)
            }
            ForEach(controller.pickerEngines) { engine in
                Text(verbatim: label(for: engine)).tag(Optional(engine.id))
            }
        }
        .labelsHidden()
        .disabled(controller.pickerEngines.isEmpty)

        // One caption line held open either way, so a reason appearing does not
        // push the model picker down. A hidden placeholder rather than an empty
        // string, whose height SwiftUI does not promise.
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
                    "No engine is ready. Configure an engine in Settings, or add models to your models folder.",
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
