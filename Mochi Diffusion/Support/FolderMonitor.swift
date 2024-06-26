//
//  FolderMonitor.swift
//  Mochi Diffusion
//
//  Created by Graham Bing on 2023-11-28.
//

import Foundation

class FolderMonitor {
    private var folderMonitorSource: DispatchSourceFileSystemObject?
    private var debounceTimer: Timer?

    private let path: String
    private let folderDidChange: (() -> Void)

    init(path: String, folderDidChange: @escaping (() -> Void)) {
        self.path = path
        self.folderDidChange = folderDidChange

        startMonitoring()
    }

    private func startMonitoring() {
        guard folderMonitorSource == nil else {
            return
        }

        let fileDescriptor = open(path, O_EVTONLY)
        guard fileDescriptor >= 0 else {
            return
        }

        folderMonitorSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor, eventMask: .write, queue: DispatchQueue.main)

        folderMonitorSource?.setEventHandler { [weak self] in
            // imperceptible delay to group simultaneous file operations together
            guard self?.debounceTimer == nil else { return }
            self?.debounceTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: false) { _ in
                self?.folderDidChange()
                self?.debounceTimer?.invalidate()
                self?.debounceTimer = nil
            }
        }

        folderMonitorSource?.resume()
    }
}
