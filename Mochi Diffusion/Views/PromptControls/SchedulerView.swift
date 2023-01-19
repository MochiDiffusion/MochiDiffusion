//
//  SchedulerView.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 12/26/22.
//

import StableDiffusion
import SwiftUI

struct SchedulerView: View {
    @EnvironmentObject private var genStore: GeneratorStore

    var body: some View {
        Text(
            "Scheduler:",
            comment: "Label for Scheduler picker"
        )
        Picker("", selection: $genStore.scheduler) {
            ForEach(StableDiffusionScheduler.allCases, id: \.self) { scheduler in
                Text(scheduler.rawValue).tag(scheduler)
            }
        }
        .labelsHidden()
    }
}

struct SchedulerView_Previews: PreviewProvider {
    static var previews: some View {
        SchedulerView()
    }
}
