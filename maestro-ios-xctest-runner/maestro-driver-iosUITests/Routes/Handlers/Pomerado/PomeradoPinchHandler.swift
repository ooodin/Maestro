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

/// `POST /pomerado/pinch {appId, frame, scale, velocity}` -> `{}`.
/// Resolves exactly one element (of any type) whose frame matches (±0.5 pt), then
/// `pinch(withScale:velocity:)` behind the guard. Errors: 409 `not_unique`, 422 `invalid_request`,
/// 5xx `action_failed` when XCTest records an issue.
@MainActor
struct PomeradoPinchHandler: HTTPHandler {
    private struct Request: PomeradoAppRequest {
        let appId: String
        let frame: PomeradoFrame
        let scale: Double
        let velocity: Double
    }

    func handleRequest(_ request: HTTPRequest) async throws -> HTTPResponse {
        await PomeradoInput.run(request, as: Request.self, expecting: "{appId, frame:{x,y,width,height}, scale, velocity}") { body, events in
            guard body.frame.isValid else {
                throw PomeradoFailure.invalidRequest("frame must be finite with non-negative size")
            }
            guard body.scale.isFinite, body.scale > 0 else {
                throw PomeradoFailure.invalidRequest("scale must be a finite number > 0")
            }
            // XCTest requires a velocity whose sign matches the direction (negative to zoom out).
            guard body.velocity.isFinite, body.velocity != 0, (body.scale < 1) == (body.velocity < 0) else {
                throw PomeradoFailure.invalidRequest("velocity must be non-zero, negative exactly when scale < 1")
            }
            let (element, _) = try PomeradoInput.uniqueElement(in: body.appId, type: nil, frame: body.frame)
            try events.perform { element.pinch(withScale: CGFloat(body.scale), velocity: CGFloat(body.velocity)) }
            return [:]
        }
    }
}
