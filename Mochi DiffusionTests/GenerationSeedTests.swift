//
//  GenerationSeedTests.swift
//  Mochi DiffusionTests
//

import Testing

@testable import Mochi_Diffusion

/// Pins that batch seeds advance without overflowing and that no generated image
/// is given seed 0, which the sidebar reserves for "random".
struct GenerationSeedTests {
    @Test("A batch seed advances by one", arguments: [UInt32(1), 41, UInt32.max - 1])
    func advancesByOne(seed: UInt32) {
        #expect(GenerationSeed.next(after: seed) == seed + 1)
    }

    @Test("A batch seed wraps from UInt32.max to 1")
    func wrapsPastMaximum() {
        #expect(GenerationSeed.next(after: .max) == 1)
    }

    @Test("A batch starting at UInt32.max never uses seed 0")
    func batchFromMaximumSkipsZero() {
        var seeds: [UInt32] = [.max]
        for _ in 0..<3 {
            seeds.append(GenerationSeed.next(after: seeds.last!))
        }
        #expect(seeds == [.max, 1, 2, 3])
    }

    @Test("A random seed is never 0")
    func randomSeedIsNeverZero() {
        for _ in 0..<10_000 {
            #expect(GenerationSeed.random() != 0)
        }
    }
}
