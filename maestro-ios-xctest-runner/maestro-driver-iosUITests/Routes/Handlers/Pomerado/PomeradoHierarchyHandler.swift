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

/// `POST /pomerado/hierarchy {appId, maxDepth?}` ->
/// `{root, depth, truncated, foregroundBundleId, springboardAlerts}`.
///
/// Strict: the tree is always the requested app (never the foreground app substituted for it),
/// no permission alert is touched, and any snapshot error is `5xx {code:"snapshot_unavailable"}`
/// instead of a partial fallback tree.
@MainActor
struct PomeradoHierarchyHandler: HTTPHandler {
    static let springboardBundleId = "com.apple.springboard"
    static let defaultMaxDepth = 60

    private struct Request: Decodable {
        let appId: String
        let maxDepth: Int?
    }

    func handleRequest(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard let body = try? JSONDecoder().decode(Request.self, from: await request.bodyData) else {
            return PomeradoResponse.invalidRequest("expected {appId:string, maxDepth?:number}")
        }
        guard !body.appId.isEmpty else {
            return PomeradoResponse.invalidRequest("appId must not be empty")
        }
        let maxDepth = body.maxDepth ?? Self.defaultMaxDepth
        guard maxDepth >= 1 else {
            return PomeradoResponse.invalidRequest("maxDepth must be >= 1")
        }

        do {
            let snapshot = try XCUIApplication(bundleIdentifier: body.appId).snapshot()
            let springboard = body.appId == Self.springboardBundleId
                ? snapshot
                : try XCUIApplication(bundleIdentifier: Self.springboardBundleId).snapshot()
            let foreground = try Self.foregroundBundleId()
            var walk = Walk(maxDepth: maxDepth)
            let root = walk.element(snapshot, level: 1)
            return PomeradoResponse.json([
                "root": root,
                "depth": walk.depth,
                "truncated": walk.truncated || walk.mayBeCut(byXCTestMaxDepth: Self.xctestSnapshotMaxDepth()),
                "foregroundBundleId": foreground,
                "springboardAlerts": Self.alerts(in: springboard),
            ])
        } catch {
            NSLog("[Pomerado] hierarchy snapshot for \(body.appId) failed: \(error)")
            return PomeradoResponse.error("snapshot_unavailable", status: .internalServerError, message: error.localizedDescription)
        }
    }

    /// Converts a snapshot into the Element contract, stopping at `maxDepth` levels (root is level 1).
    private struct Walk {
        let maxDepth: Int
        private(set) var depth = 0
        private(set) var truncated = false

        init(maxDepth: Int) {
            self.maxDepth = maxDepth
        }

        /// True when the walk reached XCTest's own snapshot depth limit, where XCTest may have
        /// silently dropped children, so the tree cannot be reported as complete.
        func mayBeCut(byXCTestMaxDepth xctestMaxDepth: Int?) -> Bool {
            guard let xctestMaxDepth else { return false }
            return depth >= xctestMaxDepth
        }

        mutating func element(_ snapshot: XCUIElementSnapshot, level: Int) -> [String: Any] {
            depth = max(depth, level)
            var children: [[String: Any]] = []
            if level < maxDepth {
                children = snapshot.children.map { element($0, level: level + 1) }
            } else if !snapshot.children.isEmpty {
                truncated = true
            }
            return [
                "elementType": Int(snapshot.elementType.rawValue),
                "identifier": snapshot.identifier,
                "label": snapshot.label,
                "value": PomeradoHierarchyHandler.stringValue(snapshot.value) ?? NSNull(),
                "title": snapshot.title,
                "placeholderValue": snapshot.placeholderValue ?? NSNull(),
                "enabled": snapshot.isEnabled,
                "selected": snapshot.isSelected,
                "hasFocus": snapshot.hasFocus,
                "frame": PomeradoHierarchyHandler.frame(snapshot.frame),
                "children": children,
            ]
        }
    }

    /// SpringBoard alerts, taken from a full (throwing) SpringBoard snapshot rather than the
    /// non-throwing `.alerts` query, which yields 0 elements when it fails.
    private static func alerts(in springboard: XCUIElementSnapshot) -> [[String: Any]] {
        descendants(of: springboard, where: { $0.elementType == .alert }, intoMatches: false).map { alert in
            [
                "frame": frame(alert.frame),
                "title": alert.label,
                "buttons": descendants(of: alert, where: { $0.elementType == .button }, intoMatches: true)
                    .map { ["label": $0.label, "frame": frame($0.frame)] },
            ]
        }
    }

    private static func descendants(
        of snapshot: XCUIElementSnapshot,
        where matches: (XCUIElementSnapshot) -> Bool,
        intoMatches: Bool
    ) -> [XCUIElementSnapshot] {
        snapshot.children.flatMap { child -> [XCUIElementSnapshot] in
            let isMatch = matches(child)
            let below = isMatch && !intoMatches ? [] : descendants(of: child, where: matches, intoMatches: intoMatches)
            return (isMatch ? [child] : []) + below
        }
    }

    private struct ForegroundUnknown: LocalizedError {
        let errorDescription: String?
    }

    /// The foreground app from the AX active-application list (`activeAppsInfo()`), without
    /// per-app `.state` queries (those record an XCTest issue and report a wrong state on failure).
    /// A non-SpringBoard entry wins; SpringBoard only when it is the sole entry. An empty list or
    /// an unresolved bundle id means "could not tell" and throws.
    private static func foregroundBundleId() throws -> String {
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

    /// XCTest's own snapshot `maxDepth` (private `defaultParameters`; INT_MAX unless something swizzled it).
    private static func xctestSnapshotMaxDepth() -> Int? {
        (AXClientProxy.sharedClient().defaultParameters()["maxDepth"] as? NSNumber)?.intValue
    }

    nonisolated fileprivate static func stringValue(_ value: Any?) -> String? {
        switch value {
        case let string as String: return string
        case let number as NSNumber: return number.stringValue
        default: return nil
        }
    }

    /// Non-finite components (CGRect.null / infinite) become 0: JSONSerialization cannot encode them.
    nonisolated fileprivate static func frame(_ rect: CGRect) -> [String: Double] {
        let finite = { (v: CGFloat) -> Double in v.isFinite ? Double(v) : 0 }
        return ["x": finite(rect.origin.x), "y": finite(rect.origin.y), "width": finite(rect.size.width), "height": finite(rect.size.height)]
    }
}
