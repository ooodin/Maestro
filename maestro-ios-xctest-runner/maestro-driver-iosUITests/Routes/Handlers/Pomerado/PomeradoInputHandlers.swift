// Added by Pomerado to its fork of Maestro (https://github.com/mobile-dev-inc/maestro).
// Copyright 2026 Pomerado contributors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import FlyingFox
import Foundation
import XCTest

/// `POST /pomerado/inputText {appId, text}` -> `{}`. Types into the focused field with upstream
/// `TextInputHelper` pacing; the guard runs before each event and `busy` is held throughout.
@MainActor
struct PomeradoInputTextHandler: HTTPHandler {
    private struct Request: PomeradoAppRequest {
        let appId: String
        let text: String
    }

    func handleRequest(_ request: HTTPRequest) async throws -> HTTPResponse {
        await PomeradoInput.run(request, as: Request.self, expecting: "{appId, text}") { body, events in
            guard !body.text.isEmpty else {
                throw PomeradoFailure.invalidRequest("text must not be empty")
            }
            try await events.type(body.text)
            return [:]
        }
    }
}

/// `POST /pomerado/swipe {appId, start:{x,y}, end:{x,y}, duration}` -> `{}`.
@MainActor
struct PomeradoSwipeHandler: HTTPHandler {
    private struct Request: PomeradoAppRequest {
        let appId: String
        let start: PomeradoPoint
        let end: PomeradoPoint
        let duration: Double
    }

    func handleRequest(_ request: HTTPRequest) async throws -> HTTPResponse {
        await PomeradoInput.run(request, as: Request.self, expecting: "{appId, start:{x,y}, end:{x,y}, duration}") { body, events in
            guard body.start.isFinite, body.end.isFinite else {
                throw PomeradoFailure.invalidRequest("start and end must be finite")
            }
            guard body.duration.isFinite, body.duration >= 0 else {
                throw PomeradoFailure.invalidRequest("duration must be a finite number >= 0")
            }
            try await events.swipe(from: body.start.cgPoint, to: body.end.cgPoint, duration: body.duration)
            return [:]
        }
    }
}

/// `POST /pomerado/screenshot {appId}` -> `{png: base64}`. No event is sent, so only the
/// foreground half of the guard applies: a screenshot of an alert over the app is allowed.
@MainActor
struct PomeradoScreenshotHandler: HTTPHandler {
    private struct Request: PomeradoAppRequest {
        let appId: String
    }

    func handleRequest(_ request: HTTPRequest) async throws -> HTTPResponse {
        await PomeradoInput.run(request, as: Request.self, expecting: "{appId}") { body, _ in
            try PomeradoGuard.checkForeground(appId: body.appId)
            let png = XCUIScreen.main.screenshot().pngRepresentation
            guard !png.isEmpty else {
                throw PomeradoFailure("screenshot_unavailable", status: .internalServerError)
            }
            return ["png": png.base64EncodedString()]
        }
    }
}

/// `POST /pomerado/launchApp {bundleId}` -> `{}`: `XCUIApplication(bundleId).activate()`.
/// Not guarded (it is what changes the foreground app). A bundle id that is not installed is 409
/// `not_installed` without calling XCTest: a failed `activate()` interrupts the test, which stops the
/// runner. Any other XCTest issue recorded by `activate()` is 5xx `launch_failed`.
@MainActor
struct PomeradoLaunchAppHandler: HTTPHandler {
    private struct Request: PomeradoAppRequest {
        let bundleId: String
        var appId: String { bundleId }
    }

    func handleRequest(_ request: HTTPRequest) async throws -> HTTPResponse {
        await PomeradoInput.run(request, as: Request.self, expecting: "{bundleId}") { body, _ in
            guard Self.isInstalled(body.bundleId) else {
                throw PomeradoFailure("not_installed", status: .conflict)
            }
            try PomeradoIssues.failing(with: PomeradoFailure("launch_failed", status: .internalServerError)) {
                XCUIApplication(bundleIdentifier: body.bundleId).activate()
            }
            return [:]
        }
    }

    /// `LSApplicationWorkspace.defaultWorkspace.applicationIsInstalled:` (private). Unknown (API absent)
    /// counts as installed, which leaves the decision to `activate()`.
    private static func isInstalled(_ bundleId: String) -> Bool {
        guard let workspaceClass = NSClassFromString("LSApplicationWorkspace") as? NSObject.Type,
              let workspace = workspaceClass.perform(NSSelectorFromString("defaultWorkspace"))?.takeUnretainedValue() as? NSObject
        else { return true }
        let selector = NSSelectorFromString("applicationIsInstalled:")
        guard workspace.responds(to: selector) else { return true }
        typealias Method = @convention(c) (NSObject, Selector, NSString) -> Bool
        let method = unsafeBitCast(workspace.method(for: selector), to: Method.self)
        return method(workspace, selector, bundleId as NSString)
    }
}
