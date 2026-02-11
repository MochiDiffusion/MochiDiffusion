//
//  FolderMonitor.swift
//  Mochi Diffusion
//
//  Created by Graham Bing on 2023-11-28.
//

import Foundation

actor FolderMonitorService {
    static let shared = FolderMonitorService()

    private struct Monitor {
        let monitor: FolderMonitor
        let continuation: AsyncStream<Void>.Continuation
    }

    private var monitors: [UUID: Monitor] = [:]

    func updates(for path: String) -> AsyncStream<Void> {
        AsyncStream { continuation in
            let token = UUID()
            Task {
                self.startMonitoring(path: path, token: token, continuation: continuation)
            }
            continuation.onTermination = { @Sendable _ in
                Task {
                    await self.stopMonitoring(token: token)
                }
            }
        }
    }

    private func startMonitoring(
        path: String,
        token: UUID,
        continuation: AsyncStream<Void>.Continuation
    ) {
        let monitor = FolderMonitor(path: path) { [weak self] in
            Task {
                await self?.emit(token: token)
            }
        }
        monitors[token] = Monitor(monitor: monitor, continuation: continuation)
    }

    private func emit(token: UUID) {
        monitors[token]?.continuation.yield(())
    }

    private func stopMonitoring(token: UUID) {
        guard let monitor = monitors.removeValue(forKey: token) else { return }
        monitor.continuation.finish()
    }
}

private final class FolderMonitor {
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
