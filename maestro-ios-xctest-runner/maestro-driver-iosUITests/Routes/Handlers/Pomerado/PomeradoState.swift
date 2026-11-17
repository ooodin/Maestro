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

/// Process-wide state shared by the Pomerado routes.
/// Thread-safe so `/pomerado/status` can answer without the main actor.
enum PomeradoState {
    /// Nonce passed by the host as `TEST_RUNNER_POMERADO_INSTANCE` (xcodebuild strips the prefix).
    static let instance: String = ProcessInfo.processInfo.environment["POMERADO_INSTANCE"] ?? ""

    private static let lock = NSLock()
    nonisolated(unsafe) private static var busyCount = 0

    static var busy: Bool {
        lock.lock()
        defer { lock.unlock() }
        return busyCount > 0
    }

    /// Holds `busy` for the full duration of `body`. Every Pomerado input route runs inside this.
    static func whileBusy<T>(_ body: () async throws -> T) async rethrows -> T {
        adjustBusy(+1)
        defer { adjustBusy(-1) }
        return try await body()
    }

    private static func adjustBusy(_ delta: Int) {
        lock.lock()
        busyCount += delta
        lock.unlock()
    }
}

/// JSON helpers for Pomerado routes. `JSONSerialization` is used so that nil fields encode as explicit `null`.
enum PomeradoResponse {
    static func json(_ object: [String: Any], status: HTTPStatusCode = .ok) -> HTTPResponse {
        // isValidJSONObject first: data(withJSONObject:) raises (not throws) on NaN/infinite numbers.
        guard JSONSerialization.isValidJSONObject(object),
              let body = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return HTTPResponse(statusCode: .internalServerError, headers: [.contentType: "application/json"], body: Data(#"{"code":"encoding_failed"}"#.utf8))
        }
        return HTTPResponse(statusCode: status, headers: [.contentType: "application/json"], body: body)
    }

    static func error(_ code: String, status: HTTPStatusCode, message: String? = nil) -> HTTPResponse {
        var object: [String: Any] = ["code": code]
        if let message { object["message"] = message }
        return json(object, status: status)
    }

    static func invalidRequest(_ message: String) -> HTTPResponse {
        error("invalid_request", status: .unprocessableContent, message: message)
    }

    /// An accessibility value as the contract's `string|null`: a String as is, an NSNumber as its
    /// `stringValue`, anything else `nil`.
    static func stringValue(_ value: Any?) -> String? {
        switch value {
        case let string as String: return string
        case let number as NSNumber: return number.stringValue
        default: return nil
        }
    }

    /// Non-finite components (CGRect.null / infinite) become 0: JSONSerialization cannot encode them.
    static func frame(_ rect: CGRect) -> [String: Double] {
        let finite = { (v: CGFloat) -> Double in v.isFinite ? Double(v) : 0 }
        return ["x": finite(rect.origin.x), "y": finite(rect.origin.y), "width": finite(rect.size.width), "height": finite(rect.size.height)]
    }
}
