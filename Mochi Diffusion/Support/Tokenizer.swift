//
//  Tokenizer.swift
//  Mochi Diffusion
//
//  Created by Carter Lombardi on 2/3/23.
//

import Foundation
import GuernikaKit

final class Tokenizer {
    private let bpeTokenizer: BPETokenizer

    init?(modelDir: URL) {
        let mergesURL = modelDir.appendingPathComponent("TextEncoder.mlmodelc/merges.txt", conformingTo: .url)
        let vocabURL = modelDir.appendingPathComponent("TextEncoder.mlmodelc/vocab.json", conformingTo: .url)

        do {
            try self.bpeTokenizer = BPETokenizer(mergesUrl: mergesURL, vocabularyUrl: vocabURL, addedVocabUrl: nil)
        } catch {
            return nil
        }
    }

    func countTokens(_ inString: String) -> Int {
        bpeTokenizer.tokenize(inString).0.count
    }
}
