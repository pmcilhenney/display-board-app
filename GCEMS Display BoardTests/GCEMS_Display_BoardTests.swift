//
//  GCEMS_Display_BoardTests.swift
//  GCEMS Display BoardTests
//
//  Created by Patrick McIlhenney on 7/5/25.
//

import Testing
import Foundation
@testable import GCEMS_Display_Board

struct GCEMS_Display_BoardTests {

    @Test func urlNormalizationAddsHTTPSWhenSchemeIsMissing() async throws {
        #expect(AppConfig.normalizedURLString("display.example.com/status") == "https://display.example.com/status")
    }

    @Test func blankURLNormalizesToNil() async throws {
        #expect(AppConfig.normalizedURLString("   ") == nil)
    }

    @Test func managedURLTakesPrecedenceOverLocalURL() async throws {
        UserDefaults.standard.set(["homepageURL": "https://managed.example.com"], forKey: "com.apple.configuration.managed")
        defer {
            UserDefaults.standard.removeObject(forKey: "com.apple.configuration.managed")
        }

        #expect(AppConfig.homepageURL(localURL: "https://local.example.com") == "https://managed.example.com")
    }

}
