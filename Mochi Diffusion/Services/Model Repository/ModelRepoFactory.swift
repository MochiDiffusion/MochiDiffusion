//
//  ModelRepoFactory.swift
//  Mochi Diffusion
//
//  Created by Jeffrey Thompson on 7/12/23.
//

struct ModelRepoFactory {

    let localModelDir: String?
    let localControlNetDir: String?

    init(localModelDir: String? = nil, localControlNetDir: String? = nil) {
        self.localModelDir = localModelDir
        self.localControlNetDir = localControlNetDir
    }

    func createModelRepo() -> some ModelRepo {
        LocalDiskModelRepo(
            modelDirPath: localModelDir,
            controlNetDirPath: localControlNetDir,
            persistenceManager: LocalDiskPersistenceManager()
        )
    }
}
