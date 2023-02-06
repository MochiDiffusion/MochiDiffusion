//
//  Tokenizer.swift
//  Mochi Diffusion
//
//  Created by Carter Lombardi on 2/3/23.
//

import Foundation
import StableDiffusion

final class Tokenizer {

    private let bpeTokenizer: BPETokenizer

    init?(modelDir: URL) {
        // Get file URLs for Merges and Vocab
        let mergesURL = modelDir.appendingPathComponent("merges.txt", conformingTo: .url)
        let vocabURL = modelDir.appendingPathComponent("vocab.json", conformingTo: .url)

        // BPETokenizer
        do {
            try self.bpeTokenizer = BPETokenizer(mergesAt: mergesURL, vocabularyAt: vocabURL)
        } catch {
            return nil
        }
    }

    func countTokens(_ inString: String) -> Int {
        bpeTokenizer.tokenize(input: inString).0.count
    }
}
