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

/// `POST /pomerado/clearField {appId, frame}` -> `{value: string|null}`.
///
/// Resolves exactly one `textField|secureTextField|textView|searchField` with that frame (±0.5 pt)
/// that has keyboard focus, taps at the normalised offset (0.98, 0.5) to move the cursor to the end,
/// deletes `value.count` characters and reports the remaining value (`null` when the field shows
/// only its placeholder). Errors: 409 `not_unique`, 409 `not_focused`.
@MainActor
struct PomeradoClearFieldHandler: HTTPHandler {
    private static let textTypes: Set<XCUIElement.ElementType> = [.textField, .secureTextField, .textView, .searchField]

    private struct Request: PomeradoAppRequest {
        let appId: String
        let frame: PomeradoFrame
    }

    func handleRequest(_ request: HTTPRequest) async throws -> HTTPResponse {
        await PomeradoInput.run(request, as: Request.self, expecting: "{appId, frame:{x,y,width,height}}") { body, events in
            guard body.frame.isValid else {
                throw PomeradoFailure.invalidRequest("frame must be finite with non-negative size")
            }
            let field = try Self.focusedField(in: body.appId, frame: body.frame)
            let count = (PomeradoResponse.stringValue(field.value) ?? "").count
            let end = CGPoint(x: field.frame.minX + field.frame.width * 0.98, y: field.frame.minY + field.frame.height * 0.5)
            try await events.tap(at: end)
            // The tap must not have moved focus: re-resolve before deleting anything.
            _ = try Self.focusedField(in: body.appId, frame: body.frame)
            if count > 0 {
                try await events.type(String(repeating: XCUIKeyboardKey.delete.rawValue, count: count))
            }
            let after = try Self.field(in: body.appId, frame: body.frame)
            let value = PomeradoResponse.stringValue(after.value)
            let placeholderOnly = value != nil && value == after.placeholderValue
            return ["value": (placeholderOnly ? nil : value) ?? NSNull()]
        }
    }

    private static func field(in appId: String, frame: PomeradoFrame) throws -> XCUIElementSnapshot {
        let root: XCUIElementSnapshot
        do {
            root = try XCUIApplication(bundleIdentifier: appId).snapshot()
        } catch {
            throw PomeradoFailure.snapshotUnavailable(error)
        }
        let matches = PomeradoSystem.descendants(of: root, where: { textTypes.contains($0.elementType) && frame.matches($0.frame) })
        guard matches.count == 1, let match = matches.first else {
            throw PomeradoFailure.notUnique
        }
        return match
    }

    private static func focusedField(in appId: String, frame: PomeradoFrame) throws -> XCUIElementSnapshot {
        let match = try field(in: appId, frame: frame)
        guard PomeradoSystem.hasFocus(match) else {
            throw PomeradoFailure.notFocused
        }
        return match
    }
}
