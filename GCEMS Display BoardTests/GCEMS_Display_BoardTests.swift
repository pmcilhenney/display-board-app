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
        UserDefaults.standard.set(["homepageURL": "https://managed.example.com"], forKey: AppConfig.managedKey)
        defer {
            UserDefaults.standard.removeObject(forKey: AppConfig.managedKey)
        }

        #expect(AppConfig.homepageURL(localURL: "https://local.example.com") == "https://managed.example.com")
    }

    @Test func managedPKCS12DataCanContainWhitespace() async throws {
        UserDefaults.standard.set(["clientCertPKCS12Base64": " aGVs\n bG8= "], forKey: AppConfig.managedKey)
        defer {
            UserDefaults.standard.removeObject(forKey: AppConfig.managedKey)
        }

        #expect(AppConfig.clientCertPKCS12Data == Data("hello".utf8))
    }

    @Test func localHomepageURLCanBeSavedAndCleared() async throws {
        AppConfig.clearLocalHomepageURL()
        defer {
            AppConfig.clearLocalHomepageURL()
        }

        AppConfig.saveLocalHomepageURL("https://local.example.com")
        #expect(AppConfig.homepageURL() == "https://local.example.com")

        AppConfig.clearLocalHomepageURL()
        #expect(AppConfig.homepageURL() == nil)
    }

}
