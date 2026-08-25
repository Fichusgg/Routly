//
//  AppDelegate.swift
//  RoutineOrganizer
//
//  The app is portrait, full stop. A schedule is a vertical list and a day
//  timeline is a vertical column; there is no landscape layout worth having, and
//  a half-rotated one looks broken.
//
//  This is enforced in two places on purpose, because either alone has a hole:
//   • The Info.plist orientation keys are what the system reads at launch and
//     what the App Store validates against — but a scene can still be asked to
//     rotate by code that overrides them.
//   • `supportedInterfaceOrientationsFor:` is the runtime authority, consulted
//     on every rotation attempt, and it wins over anything a view controller
//     further down might advertise.
//
//  Neither has anything to do with the device's rotation lock, which is the
//  user's setting and stays theirs.
//

import SwiftUI

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        .portrait
    }
}
