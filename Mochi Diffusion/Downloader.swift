//
//  Downloader.swift
//  Diffusion
//
//  Created by Pedro Cuenca on December 2022.
//  See LICENSE at https://github.com/huggingface/swift-coreml-diffusers/LICENSE
//

import Combine
import Foundation
import Path

class Downloader: NSObject, ObservableObject {
    enum DownloadState {
        case notStarted
        case downloading(Double)
        case completed(URL)
        case failed(Error)
    }

    private(set) var destination: URL
    private(set) lazy var downloadState: CurrentValueSubject<DownloadState, Never> = CurrentValueSubject(.notStarted)
    private var stateSubscriber: Cancellable?

    init(from url: URL, to destination: URL) {
        self.destination = destination
        super.init()

        // .background allows downloads to proceed in the background
        let config = URLSessionConfiguration.background(withIdentifier: "com.joshua-park.mochi-diffusion.download")
        let urlSession = URLSession(configuration: config, delegate: self, delegateQueue: OperationQueue())
        downloadState.value = .downloading(0)
        urlSession.getAllTasks { tasks in
            // If there's an existing pending background task, let it proceed, otherwise start a new one.
            // TODO: check URL when we support downloading more models.
            if tasks.first == nil {
                urlSession.downloadTask(with: url).resume()
            }
        }
    }

    @discardableResult
    func waitUntilDone() throws -> URL {
        // It's either this, or stream the bytes ourselves (add to a buffer, save to disk, etc; boring and finicky)
        let semaphore = DispatchSemaphore(value: 0)
        stateSubscriber = downloadState.sink { state in
            switch state {
            case .completed:
                semaphore.signal()
            case .failed:
                semaphore.signal()
            default:
                break
            }
        }
        semaphore.wait()

        switch downloadState.value {
        case .completed(let url):
            return url
        case .failed(let error):
            throw error
        default:
            throw("Should never happen, lol")
        }
    }
}

extension Downloader: URLSessionDelegate, URLSessionDownloadDelegate {
    func urlSession(
        _: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData _: Int64,
        totalBytesWritten _: Int64,
        totalBytesExpectedToWrite _: Int64
    ) {
        downloadState.value = .downloading(downloadTask.progress.fractionCompleted)
    }

    func urlSession(
        _: URLSession,
        downloadTask _: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let path = Path(url: location) else {
            downloadState.value = .failed("Invalid download location received: \(location)")
            return
        }
        guard let toPath = Path(url: destination) else {
            downloadState.value = .failed("Invalid destination: \(destination)")
            return
        }
        do {
            try path.move(to: toPath, overwrite: true)
            downloadState.value = .completed(destination)
        } catch {
            downloadState.value = .failed(error)
        }
    }

    func urlSession(
        _: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error = error {
            downloadState.value = .failed(error)
        }
    }
}
