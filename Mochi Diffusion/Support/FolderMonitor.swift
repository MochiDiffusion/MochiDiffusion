//
//  FolderMonitor.swift
//  Mochi Diffusion
//
//  Created by Graham Bing on 2023-11-28.
//

import Foundation

nonisolated final class FolderMonitor {
    private let folderDidChange: () -> Void
    private let queue = DispatchQueue(label: "MochiDiffusion.FolderMonitor", qos: .utility)

    private var folderMonitorSource: DispatchSourceFileSystemObject?
    private var debounceWorkItem: DispatchWorkItem?

    init(path: String, folderDidChange: @escaping () -> Void) {
        self.folderDidChange = folderDidChange

        let fileDescriptor = open(path, O_EVTONLY)
        guard fileDescriptor >= 0 else {
            return
        }

        folderMonitorSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: .write,
            queue: queue
        )
        folderMonitorSource?.setCancelHandler { [fileDescriptor] in
            close(fileDescriptor)
        }

        folderMonitorSource?.setEventHandler { [weak self] in
            guard
                let self,
                self.debounceWorkItem == nil
            else { return }

            let workItem = DispatchWorkItem { [weak self] in
                self?.folderDidChange()
                self?.debounceWorkItem = nil
            }
            self.debounceWorkItem = workItem
            self.queue.asyncAfter(deadline: .now() + 0.1, execute: workItem)
        }

        folderMonitorSource?.resume()
    }

    deinit {
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        folderMonitorSource?.cancel()
        folderMonitorSource = nil
    }
}
