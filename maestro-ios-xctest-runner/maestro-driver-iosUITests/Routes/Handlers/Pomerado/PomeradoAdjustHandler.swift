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

/// `POST /pomerado/adjustElement {appId, elementType:"pickerWheel"|"slider", frame, pickerValue?,
/// pickerOrder?:"next"|"previous", sliderPosition?}` -> `{value: string|null}`.
///
/// Resolves exactly one element of that type whose frame matches (±0.5 pt), then:
/// - `pickerValue`: `adjust(toPickerWheelValue:)`;
/// - `pickerOrder`: a tap 0.1 x height below (next) or above (previous) the wheel's centre, as
///   `selectPickerWheelValue` does with offset 0.1;
/// - `sliderPosition` (0...1): `adjust(toNormalizedSliderPosition:)`.
/// Errors: 409 `not_unique`, 422 `invalid_request`, 5xx `action_failed` when XCTest records an issue.
@MainActor
struct PomeradoAdjustHandler: HTTPHandler {
    private struct Request: PomeradoAppRequest {
        let appId: String
        let elementType: String
        let frame: PomeradoFrame
        let pickerValue: String?
        let pickerOrder: String?
        let sliderPosition: Double?
    }

    private enum Adjustment {
        case pickerValue(String)
        case pickerOrder(next: Bool)
        case slider(Double)
    }

    func handleRequest(_ request: HTTPRequest) async throws -> HTTPResponse {
        let shape = "{appId, elementType:\"pickerWheel\"|\"slider\", frame, pickerValue?, pickerOrder?:\"next\"|\"previous\", sliderPosition?}"
        return await PomeradoInput.run(request, as: Request.self, expecting: shape) { body, events in
            let (type, adjustment) = try Self.validate(body)
            let (element, snapshot) = try PomeradoInput.uniqueElement(in: body.appId, type: type, frame: body.frame)
            switch adjustment {
            case .pickerValue(let value):
                try events.perform { element.adjust(toPickerWheelValue: value) }
            case .slider(let position):
                try events.perform { element.adjust(toNormalizedSliderPosition: CGFloat(position)) }
            case .pickerOrder(let next):
                let frame = snapshot.frame
                let offset = (next ? 0.1 : -0.1) * frame.height
                let before = PomeradoResponse.stringValue(snapshot.value)
                try await events.tap(at: CGPoint(x: frame.midX, y: frame.midY + offset))
                // The wheel moves after the tap; wait (up to 2 s) for its value to change.
                let deadline = Date().addingTimeInterval(2)
                while Date() < deadline, PomeradoResponse.stringValue(try Self.value(of: element)) == before {
                    try await Task.sleep(nanoseconds: 200_000_000)
                }
            }
            return ["value": try await Self.settledValue(of: element) ?? NSNull()]
        }
    }

    /// The value once it has stopped changing (two equal reads 250 ms apart, at most 3 s). A wheel
    /// still decelerating ignores the next touch, so the route returns only once it has settled.
    private static func settledValue(of element: XCUIElement) async throws -> String? {
        let deadline = Date().addingTimeInterval(3)
        var last = PomeradoResponse.stringValue(try value(of: element))
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 250_000_000)
            let current = PomeradoResponse.stringValue(try value(of: element))
            if current == last { return current }
            last = current
        }
        return last
    }

    private static func value(of element: XCUIElement) throws -> Any? {
        do {
            return try element.snapshot().value
        } catch {
            throw PomeradoFailure.snapshotUnavailable(error)
        }
    }

    private static func validate(_ body: Request) throws -> (XCUIElement.ElementType, Adjustment) {
        guard body.frame.isValid else {
            throw PomeradoFailure.invalidRequest("frame must be finite with non-negative size")
        }
        switch body.elementType {
        case "pickerWheel":
            guard body.sliderPosition == nil else {
                throw PomeradoFailure.invalidRequest("sliderPosition is only valid for a slider")
            }
            switch (body.pickerValue, body.pickerOrder) {
            case (let value?, nil):
                return (.pickerWheel, .pickerValue(value))
            case (nil, "next"):
                return (.pickerWheel, .pickerOrder(next: true))
            case (nil, "previous"):
                return (.pickerWheel, .pickerOrder(next: false))
            default:
                throw PomeradoFailure.invalidRequest("a pickerWheel needs exactly one of pickerValue or pickerOrder (\"next\"|\"previous\")")
            }
        case "slider":
            guard body.pickerValue == nil, body.pickerOrder == nil else {
                throw PomeradoFailure.invalidRequest("pickerValue and pickerOrder are only valid for a pickerWheel")
            }
            guard let position = body.sliderPosition, position.isFinite, (0...1).contains(position) else {
                throw PomeradoFailure.invalidRequest("a slider needs sliderPosition in 0...1")
            }
            return (.slider, .slider(position))
        default:
            throw PomeradoFailure.invalidRequest("elementType must be \"pickerWheel\" or \"slider\"")
        }
    }
}
