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

/// Device-wide state shared by `/pomerado/hierarchy` and the input guard: the foreground app and
/// SpringBoard alerts. Every lookup throws instead of returning a partial answer.
@MainActor
enum PomeradoSystem {
    static let springboardBundleId = "com.apple.springboard"

    struct Alert {
        let frame: CGRect
        let title: String
        let buttons: [(label: String, frame: CGRect)]
    }

    private struct ForegroundUnknown: LocalizedError {
        let errorDescription: String?
    }

    static func springboardSnapshot() throws -> XCUIElementSnapshot {
        try XCUIApplication(bundleIdentifier: springboardBundleId).snapshot()
    }

    /// The foreground app from the AX active-application list (`activeAppsInfo()`), without
    /// per-app `.state` queries (those record an XCTest issue and report a wrong state on failure).
    /// A non-SpringBoard entry wins; SpringBoard only when it is the sole entry. An empty list or
    /// an unresolved bundle id means "could not tell" and throws.
    static func foregroundBundleId() throws -> String {
        let ids = XCUIApplication.activeAppsInfo().map { $0["bundleId"] as? String }
        guard !ids.isEmpty else {
            throw ForegroundUnknown(errorDescription: "activeAppsInfo returned no applications")
        }
        let resolved = ids.compactMap { $0 }.filter { $0 != "unknowBundleId" }
        guard resolved.count == ids.count else {
            throw ForegroundUnknown(errorDescription: "activeAppsInfo could not resolve every bundle id")
        }
        return resolved.first { $0 != springboardBundleId } ?? resolved[0]
    }

    /// SpringBoard alerts, taken from a full (throwing) SpringBoard snapshot rather than the
    /// non-throwing `.alerts` query, which yields 0 elements when it fails.
    static func alerts(in springboard: XCUIElementSnapshot) -> [Alert] {
        descendants(of: springboard, where: { $0.elementType == .alert }, intoMatches: false).map { alert in
            Alert(
                frame: alert.frame,
                title: alert.label,
                buttons: descendants(of: alert, where: { $0.elementType == .button }, intoMatches: true)
                    .map { (label: $0.label, frame: $0.frame) }
            )
        }
    }

    /// Focus as the contract's `hasFocus`: UI focus or keyboard focus. `XCUIElementSnapshot.hasFocus`
    /// alone is focus-engine focus and stays false for a focused iOS text field; XCTest's private
    /// snapshot property `hasKeyboardFocus` reports the keyboard focus.
    static func hasFocus(_ snapshot: XCUIElementSnapshot) -> Bool {
        if snapshot.hasFocus { return true }
        guard let object = snapshot as? NSObject, object.responds(to: NSSelectorFromString("hasKeyboardFocus")) else {
            return false
        }
        return (object.value(forKey: "hasKeyboardFocus") as? Bool) ?? false
    }

    /// Descendants (not the node itself) in document order. With `intoMatches: false` the walk
    /// does not descend into a match.
    static func descendants(
        of snapshot: XCUIElementSnapshot,
        where matches: (XCUIElementSnapshot) -> Bool,
        intoMatches: Bool = true
    ) -> [XCUIElementSnapshot] {
        snapshot.children.flatMap { child -> [XCUIElementSnapshot] in
            let isMatch = matches(child)
            let below = isMatch && !intoMatches ? [] : descendants(of: child, where: matches, intoMatches: intoMatches)
            return (isMatch ? [child] : []) + below
        }
    }
}

/// The in-runner input guard. It runs immediately before every synthesized event (and before every
/// XCUIElement action), so nothing reaches the screen when the app under test is not in front or a
/// SpringBoard alert would take the touch.
@MainActor
enum PomeradoGuard {
    struct ExpectAlert: Decodable {
        let title: String
        let button: String
    }

    /// 409 `{code:"guard_failed", reason}`; `reason` is `"foreground"` or `"alert"`.
    struct Failure: Error {
        let reason: String
    }

    /// Passes only when
    /// - there is no SpringBoard alert and `expectAlert` is nil, and `appId` is the foreground app; or
    /// - `expectAlert` names the single present alert by exact title, that alert has exactly one button
    ///   with exactly that label, and the button's frame contains `point`. A SpringBoard alert makes
    ///   SpringBoard the foreground app, so `appId` or SpringBoard must be foreground in this case.
    /// Alerts are checked first, so an alert over the app under test reports `alert`, not `foreground`.
    /// Lookup failures throw `snapshot_unavailable` (5xx).
    static func check(appId: String, expectAlert: ExpectAlert? = nil, at point: CGPoint? = nil) throws {
        let alerts: [PomeradoSystem.Alert]
        let foreground: String
        do {
            alerts = PomeradoSystem.alerts(in: try PomeradoSystem.springboardSnapshot())
            foreground = try PomeradoSystem.foregroundBundleId()
        } catch {
            NSLog("[Pomerado] guard lookup failed: \(error)")
            throw PomeradoFailure.snapshotUnavailable(error)
        }

        guard alerts.isEmpty, expectAlert == nil else {
            guard let expectAlert, let point, alerts.count == 1, alerts[0].title == expectAlert.title else {
                throw Failure(reason: "alert")
            }
            let named = alerts[0].buttons.filter { $0.label == expectAlert.button }
            guard named.count == 1, named[0].frame.contains(point) else {
                throw Failure(reason: "alert")
            }
            guard foreground == appId || foreground == PomeradoSystem.springboardBundleId else {
                throw Failure(reason: "foreground")
            }
            return
        }
        guard foreground == appId else {
            throw Failure(reason: "foreground")
        }
    }
}

/// A Pomerado route error with its HTTP status and short code.
struct PomeradoFailure: Error {
    let code: String
    let status: HTTPStatusCode
    let message: String?

    init(_ code: String, status: HTTPStatusCode, message: String? = nil) {
        self.code = code
        self.status = status
        self.message = message
    }

    static func invalidRequest(_ message: String) -> Self {
        Self("invalid_request", status: .unprocessableContent, message: message)
    }

    static func snapshotUnavailable(_ error: Error) -> Self {
        Self("snapshot_unavailable", status: .internalServerError, message: error.localizedDescription)
    }

    static let notUnique = Self("not_unique", status: .conflict)
    static let notFocused = Self("not_focused", status: .conflict)
}

/// Counts XCTest issues recorded by non-throwing XCUIElement APIs (adjust, pinch, activate, queries),
/// so a failed call becomes a 5xx instead of a silent 200.
///
/// Caveat (observed with Xcode 27.1 / iOS 18.5): XCTest interrupts this async test on any recorded
/// issue, even with `continueAfterFailure` and inside `XCTExpectFailure`, so the runner exits
/// (xcodebuild then relaunches it with a new pid). The routes therefore validate what they can
/// before calling XCTest (installed app, pinch velocity sign); this counter covers the rest where
/// the process survives.
final class PomeradoIssues: NSObject, XCTestObservation {
    @MainActor static let shared: PomeradoIssues = {
        let observer = PomeradoIssues()
        XCTestObservationCenter.shared.addTestObserver(observer)
        return observer
    }()

    private let lock = NSLock()
    private var count = 0

    var recorded: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func testCase(_ testCase: XCTestCase, didRecord issue: XCTIssue) {
        NSLog("[Pomerado] XCTest issue recorded: \(issue.compactDescription)")
        lock.lock()
        count += 1
        lock.unlock()
    }

    /// Runs `body` and throws `failure` if XCTest recorded an issue meanwhile.
    @MainActor
    static func failing<T>(with failure: PomeradoFailure, _ body: () throws -> T) throws -> T {
        let before = shared.recorded
        let result = try body()
        if shared.recorded != before { throw failure }
        return result
    }
}

// MARK: - Shared input plumbing

/// A request body of a guarded Pomerado route.
protocol PomeradoAppRequest: Decodable {
    var appId: String { get }
}

/// `{x, y}` (CGPoint's own Decodable expects an array).
struct PomeradoPoint: Decodable {
    let x: Double
    let y: Double

    var cgPoint: CGPoint { CGPoint(x: x, y: y) }
    var isFinite: Bool { x.isFinite && y.isFinite }
}

/// `{x, y, width, height}` as reported by `/pomerado/hierarchy`.
struct PomeradoFrame: Decodable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    var isValid: Bool { [x, y, width, height].allSatisfy(\.isFinite) && width >= 0 && height >= 0 }

    /// Equal within ±0.5 pt on every component.
    func matches(_ other: CGRect) -> Bool {
        abs(other.origin.x - x) <= 0.5 && abs(other.origin.y - y) <= 0.5
            && abs(other.size.width - width) <= 0.5 && abs(other.size.height - height) <= 0.5
    }
}

/// Sends a route's events, each one behind the guard, and counts them so an error after the first
/// event is reported with `partial: true`.
@MainActor
final class PomeradoEvents {
    let appId: String
    private(set) var sent = 0

    init(appId: String) {
        self.appId = appId
    }

    /// Guard, then `_XCT_synthesizeEvent`. The record is built first so nothing runs between the
    /// guard and the event.
    func synthesize(expectAlert: PomeradoGuard.ExpectAlert? = nil, at point: CGPoint? = nil, _ build: () -> EventRecord) async throws {
        let record = build()
        try PomeradoGuard.check(appId: appId, expectAlert: expectAlert, at: point)
        sent += 1
        do {
            try await RunnerDaemonProxy().synthesize(eventRecord: record)
        } catch {
            NSLog("[Pomerado] synthesize failed: \(error)")
            throw PomeradoFailure("input_failed", status: .internalServerError, message: error.localizedDescription)
        }
    }

    /// Guard, then an XCUIElement action that synthesizes its own events. An XCTest issue recorded
    /// by the action becomes 5xx `action_failed`.
    func perform(_ action: () -> Void) throws {
        try PomeradoGuard.check(appId: appId)
        sent += 1
        try PomeradoIssues.failing(with: PomeradoFailure("action_failed", status: .internalServerError), action)
    }

    /// A tap (or a press of `duration` seconds) at a point in hierarchy coordinates.
    func tap(at point: CGPoint, duration: TimeInterval? = nil, expectAlert: PomeradoGuard.ExpectAlert? = nil) async throws {
        let device = Self.devicePoint(point)
        try await synthesize(expectAlert: expectAlert, at: point) {
            EventRecord(orientation: ScreenSizeHelper.currentInterfaceOrientation())
                .addPointerTouchEvent(at: device, touchUpAfter: duration)
        }
    }

    func swipe(from start: CGPoint, to end: CGPoint, duration: TimeInterval) async throws {
        let (deviceStart, deviceEnd) = (Self.devicePoint(start), Self.devicePoint(end))
        try await synthesize {
            EventRecord(orientation: ScreenSizeHelper.currentInterfaceOrientation())
                .addSwipeEvent(start: deviceStart, end: deviceEnd, duration: duration)
        }
    }

    /// Types `text` with upstream `TextInputHelper` pacing: the first character at speed 1, a 0.5 s
    /// pause, then the rest at 30 characters per second. The guard runs before each of the two events.
    /// (`TextInputHelper.inputText` itself cannot be used: it sends both events with no hook between them.)
    func type(_ text: String) async throws {
        await TextInputHelper.waitUntilKeyboardIsPresented()
        let first = String(text.prefix(1))
        try await synthesize { Self.textRecord(first, typingSpeed: 1) }
        try await Task.sleep(nanoseconds: 500_000_000)
        if text.count > 1 {
            let rest = String(text.dropFirst())
            try await synthesize { Self.textRecord(rest, typingSpeed: 30) }
        }
    }

    private static func textRecord(_ text: String, typingSpeed: Int) -> EventRecord {
        var path = PointerEventPath.pathForTextInput()
        path.type(text: text, typingSpeed: typingSpeed)
        return EventRecord(orientation: ScreenSizeHelper.currentInterfaceOrientation()).add(path)
    }

    /// Hierarchy (interface) coordinates to the device coordinates events use, as upstream touch does.
    private static func devicePoint(_ point: CGPoint) -> CGPoint {
        let (width, height) = ScreenSizeHelper.physicalScreenSize()
        return ScreenSizeHelper.orientationAwarePoint(width: width, height: height, point: point)
    }
}

@MainActor
enum PomeradoInput {
    /// Runs a guarded route: holds `busy` for the whole request (decoding included), decodes the body,
    /// and maps errors to `{code, reason?, message?, partial?}`.
    static func run<Body: PomeradoAppRequest>(
        _ request: HTTPRequest,
        as type: Body.Type,
        expecting shape: String,
        _ body: (Body, PomeradoEvents) async throws -> [String: Any]
    ) async -> HTTPResponse {
        await PomeradoState.whileBusy {
            var events: PomeradoEvents?
            do {
                guard let decoded = try? JSONDecoder().decode(Body.self, from: await request.bodyData) else {
                    throw PomeradoFailure.invalidRequest("expected \(shape)")
                }
                guard !decoded.appId.isEmpty else {
                    throw PomeradoFailure.invalidRequest("appId must not be empty")
                }
                let log = PomeradoEvents(appId: decoded.appId)
                events = log
                return PomeradoResponse.json(try await body(decoded, log))
            } catch {
                return response(for: error, partial: (events?.sent ?? 0) > 0)
            }
        }
    }

    private static func response(for error: Error, partial: Bool) -> HTTPResponse {
        var object: [String: Any]
        let status: HTTPStatusCode
        switch error {
        case let failure as PomeradoGuard.Failure:
            object = ["code": "guard_failed", "reason": failure.reason]
            status = .conflict
        case let failure as PomeradoFailure:
            object = ["code": failure.code]
            if let message = failure.message { object["message"] = message }
            status = failure.status
        default:
            NSLog("[Pomerado] input route failed: \(error)")
            object = ["code": "input_failed", "message": error.localizedDescription]
            status = .internalServerError
        }
        if partial { object["partial"] = true }
        return PomeradoResponse.json(object, status: status)
    }

    /// Exactly one element of `type` (any type when nil) in `appId` whose frame matches `frame`
    /// (±0.5 pt), resolved on a throwing snapshot. It is then bound as an XCUIElement through
    /// `descendants(matching:)` narrowed by the match's identifier and label, keeping the candidates
    /// whose own (throwing) snapshot has that type and frame; exactly one must remain.
    /// Anything else is 409 `not_unique`. (Neither a frame `NSPredicate`, whose evaluation lost the AX
    /// connection to the app, nor the match's index, whose query order differs from the snapshot's
    /// for `.other`, is used.)
    static func uniqueElement(
        in appId: String,
        type: XCUIElement.ElementType?,
        frame: PomeradoFrame
    ) throws -> (element: XCUIElement, snapshot: XCUIElementSnapshot) {
        let app = XCUIApplication(bundleIdentifier: appId)
        let root = try snapshot(of: app)
        let matches = PomeradoSystem.descendants(of: root, where: {
            (type == nil || $0.elementType == type) && frame.matches($0.frame)
        })
        guard matches.count == 1, let match = matches.first else {
            throw PomeradoFailure.notUnique
        }
        let candidates = try PomeradoIssues.failing(with: PomeradoFailure("snapshot_unavailable", status: .internalServerError)) {
            app.descendants(matching: match.elementType)
                .matching(NSPredicate(format: "identifier == %@ AND label == %@", match.identifier, match.label))
                .allElementsBoundByIndex
        }
        var bound: [(XCUIElement, XCUIElementSnapshot)] = []
        for candidate in candidates {
            let candidateSnapshot = try snapshot(of: candidate)
            if candidateSnapshot.elementType == match.elementType, frame.matches(candidateSnapshot.frame) {
                bound.append((candidate, candidateSnapshot))
            }
        }
        guard bound.count == 1, let (element, elementSnapshot) = bound.first else {
            throw PomeradoFailure.notUnique
        }
        return (element, elementSnapshot)
    }

    private static func snapshot(of element: XCUIElement) throws -> XCUIElementSnapshot {
        do {
            return try element.snapshot()
        } catch {
            throw PomeradoFailure.snapshotUnavailable(error)
        }
    }
}
