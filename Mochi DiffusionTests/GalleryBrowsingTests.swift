//
//  GalleryBrowsingTests.swift
//  Mochi DiffusionTests
//

import Foundation
import Testing

@testable import Mochi_Diffusion

/// Pins the gallery's search filters and its previous and next navigation.
@MainActor
struct GalleryBrowsingTests {

    private func makeImage(prompt: String = "", date: TimeInterval = 0) -> SDImage {
        var image = SDImage()
        image.prompt = prompt
        image.generatedDate = Date(timeIntervalSinceReferenceDate: date)
        return image
    }

    // MARK: - Filters

    @Test("Each filter element reads its own field", arguments: FilterElement.allCases)
    func elementReadsItsField(element: FilterElement) {
        var image = SDImage()
        image.prompt = "a cat"
        image.negativePrompt = "blurry"
        image.model = "sd-model"
        image.quality = "high"
        image.seed = 42
        image.steps = 28
        image.guidanceScale = 7.5

        let expected: String =
            switch element {
            case .prompt: "a cat"
            case .negativePrompt: "blurry"
            case .model: "sd-model"
            case .quality: "high"
            case .seed: "42"
            case .steps: "28"
            case .guidanceScale: "7.5"
            }
        #expect(element.getFilterValueFrom(image) == expected)
    }

    /// Typing a plain word finds it whatever its case, accents or character width.
    @Test(
        "Contains ignores case, accents and character width",
        arguments: ["café", "CAFE", "Ｃａｆｅ"]
    )
    func containsIsForgiving(text: String) {
        let filter = Filter(text: text, element: .prompt, type: .contains)

        #expect(filter.validate(makeImage(prompt: "A Café on the corner")))
        #expect(!filter.validate(makeImage(prompt: "a dog")))
    }

    @Test("Equals matches the whole value exactly")
    func equalsIsExact() {
        let filter = Filter(text: "a cat", element: .prompt, type: .equals)

        #expect(filter.validate(makeImage(prompt: "a cat")))
        #expect(!filter.validate(makeImage(prompt: "A cat")))
        #expect(!filter.validate(makeImage(prompt: "a cat on a mat")))
    }

    @Test("Is not inverts the match", arguments: [FilterType.contains, .equals])
    func isNotInverts(type: FilterType) {
        let filter = Filter(text: "a cat", element: .prompt, type: type, condition: .isNotEqual)

        #expect(!filter.validate(makeImage(prompt: "a cat")))
        #expect(filter.validate(makeImage(prompt: "a dog")))
    }

    @Test("A gallery shows only the images that pass every filter")
    func filtersCombineWithAnd() {
        let gallery = ImageGallery()
        gallery.add(makeImage(prompt: "a black cat"))
        gallery.add(makeImage(prompt: "a white cat"))
        gallery.add(makeImage(prompt: "a black dog"))

        gallery.filters = [
            Filter(text: "cat", element: .prompt, type: .contains),
            Filter(text: "black", element: .prompt, type: .contains),
        ]

        #expect(gallery.images.map(\.prompt) == ["a black cat"])
        #expect(gallery.allImages.count == 3)
    }

    // MARK: - Previous and next

    /// Three images, with their IDs in the order the gallery shows them. The order
    /// depends on the viewer's sort setting, so tests read it rather than assume it.
    private func makeGalleryOfThree() -> (ImageGallery, [SDImage.ID]) {
        let gallery = ImageGallery()
        for index in 0..<3 {
            gallery.add(makeImage(prompt: "\(index)", date: TimeInterval(index)))
        }
        return (gallery, gallery.images.map(\.id))
    }

    @Test("Next and previous step through the shown order")
    func stepsThroughShownOrder() {
        let (gallery, ids) = makeGalleryOfThree()

        #expect(gallery.imageAfter(ids[0]) == ids[1])
        #expect(gallery.imageAfter(ids[1]) == ids[2])
        #expect(gallery.imageBefore(ids[2]) == ids[1])
        #expect(gallery.imageBefore(ids[1]) == ids[0])
    }

    @Test("Stepping past either end wraps around, unless wrapping is off")
    func endsWrapOnlyWhenAsked() {
        let (gallery, ids) = makeGalleryOfThree()

        #expect(gallery.imageAfter(ids[2]) == ids[0])
        #expect(gallery.imageBefore(ids[0]) == ids[2])
        #expect(gallery.imageAfter(ids[2], wrap: false) == nil)
        #expect(gallery.imageBefore(ids[0], wrap: false) == nil)
    }

    /// With nothing selected, next starts at the first image and previous at the
    /// last.
    @Test("With no selection, stepping starts from an end")
    func noSelectionStartsFromAnEnd() {
        let (gallery, ids) = makeGalleryOfThree()

        #expect(gallery.imageAfter(nil) == ids[0])
        #expect(gallery.imageBefore(nil) == ids[2])
        #expect(gallery.imageAfter(UUID()) == ids[0])
        #expect(gallery.imageAfter(nil, wrap: false) == nil)
    }

    @Test("Stepping skips images that the filters hide")
    func steppingFollowsTheFilters() {
        let gallery = ImageGallery()
        gallery.add(makeImage(prompt: "a cat", date: 0))
        gallery.add(makeImage(prompt: "a dog", date: 1))
        gallery.add(makeImage(prompt: "a cat again", date: 2))
        gallery.filters = [Filter(text: "cat", element: .prompt, type: .contains)]
        let ids = gallery.images.map(\.id)

        #expect(ids.count == 2)
        #expect(gallery.imageAfter(ids[0]) == ids[1])
    }

    @Test("An empty gallery has nothing to step to")
    func emptyGallery() {
        let gallery = ImageGallery()

        #expect(gallery.imageAfter(nil) == nil)
        #expect(gallery.imageBefore(nil) == nil)
    }
}
