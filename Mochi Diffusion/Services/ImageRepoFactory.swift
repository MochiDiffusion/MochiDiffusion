//
//  ImageRepoFactory.swift
//  Mochi Diffusion
//
//  Created by Jeffrey Thompson on 7/12/23.
//

struct ImageRepoFactory {

    let localImageDir: String?

    func createImageRepo() -> some ImageRepo {
        LocalDiskImageRepo(imageDirPath: localImageDir, persistenceManager: LocalDiskPersistenceManager())
    }
}
