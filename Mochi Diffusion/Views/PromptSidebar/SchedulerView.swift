//
//  SchedulerView.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 12/26/22.
//

import SwiftUI
import StableDiffusion

struct SchedulerView: View {
    @EnvironmentObject var store: Store
    
    var body: some View {
        Text("Scheduler:",
             tableName: "Prompt",
             comment: "Label for Scheduler picker")
        Picker("", selection: $store.scheduler) {
            ForEach(StableDiffusionScheduler.allCases, id: \.self) { s in
                Text(s.rawValue).tag(s)
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
