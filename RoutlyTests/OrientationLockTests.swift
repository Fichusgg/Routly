//
//  OrientationLockTests.swift
//  RoutineOrganizerTests
//
//  The app is portrait-only, and it's locked in two independent places because
//  either alone has a hole. Both are asserted here, against the *built* bundle
//  and the *real* delegate — a build-setting change that silently fails to
//  reach `Info.plist` is exactly the kind of thing that looks fixed in the
//  editor and isn't in the product.
//
//  The test host is the app itself, so `Bundle.main` here is the shipping
//  bundle.
//

import Testing
import Foundation
import UIKit
@testable import Routly

@MainActor
@Suite("Portrait lock")
struct OrientationLockTests {

    /// The runtime authority: consulted on every rotation attempt, and it
    /// overrides anything a view controller further down advertises.
    @Test("the delegate pins every window to portrait")
    func delegateReturnsPortrait() {
        let delegate = AppDelegate()
        let mask = delegate.application(UIApplication.shared, supportedInterfaceOrientationsFor: nil)
        #expect(mask == .portrait)
    }

    /// What the system reads at launch. Checked on the built bundle rather than
    /// the pbxproj, so a setting that didn't make it through the build fails.
    @Test("the shipped Info.plist allows portrait only", arguments: [
        "UISupportedInterfaceOrientations",
        "UISupportedInterfaceOrientations~iphone",
        "UISupportedInterfaceOrientations~ipad",
    ])
    func infoPlistIsPortraitOnly(_ key: String) {
        // Not every key is present on every platform slice; an absent key is
        // fine, a key listing landscape is not.
        guard let declared = Bundle.main.object(forInfoDictionaryKey: key) as? [String] else { return }
        #expect(declared == ["UIInterfaceOrientationPortrait"], "\(key) declared \(declared)")
    }

    /// Belt and braces: nothing anywhere should be advertising a landscape mask.
    @Test("no landscape orientation is advertised anywhere in the bundle")
    func noLandscapeAnywhere() {
        let keys = [
            "UISupportedInterfaceOrientations",
            "UISupportedInterfaceOrientations~iphone",
            "UISupportedInterfaceOrientations~ipad",
        ]
        let all = keys.compactMap { Bundle.main.object(forInfoDictionaryKey: $0) as? [String] }.flatMap { $0 }
        #expect(!all.contains { $0.contains("Landscape") }, "found landscape in \(all)")
    }
}
