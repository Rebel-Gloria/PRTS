import CoreImage
import Foundation
import Testing
import UIKit

@testable import PRTS

struct PhotoImageResolutionTests {
    @Test(arguments: [1280, 1920], [false, true])
    func encoderUsesRequestedLongestSide(longestSide: Int, portrait: Bool) throws {
        let image = CIImage(color: .white).cropped(
            to: CGRect(x: 0, y: 0, width: portrait ? 1920 : 2560, height: portrait ? 2560 : 1920)
        )
        let data = try PhotoImageEncoder.jpeg(image: image, longestSide: CGFloat(longestSide))
        let encoded = try #require(UIImage(data: data)?.cgImage)
        #expect(encoded.width == (portrait ? longestSide * 3 / 4 : longestSide))
        #expect(encoded.height == (portrait ? longestSide : longestSide * 3 / 4))
    }

    @Test func highResolutionDefaultsOffAndOnlyChangesQuestionsAndTextReading() {
        let name = "PhotoImageResolutionTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(PhotoImagePurpose.highResolutionKey == "photoDescription.highResolution")
        #expect(!defaults.bool(forKey: PhotoImagePurpose.highResolutionKey))
        for enabled in [false, true, false] {
            defaults.set(enabled, forKey: PhotoImagePurpose.highResolutionKey)
            let highResolution = defaults.bool(forKey: PhotoImagePurpose.highResolutionKey)
            #expect(
                PhotoImagePurpose.description.longestSide(highResolution: highResolution) == 1280
            )
            #expect(
                PhotoImagePurpose.liveCaption.longestSide(highResolution: highResolution) == 720
            )
            #expect(
                PhotoImagePurpose.question.longestSide(highResolution: highResolution)
                    == (enabled ? 1920 : 1280)
            )
            #expect(
                PhotoImagePurpose.textReading.longestSide(highResolution: highResolution)
                    == (enabled ? 1920 : 1280)
            )
        }
    }
}
