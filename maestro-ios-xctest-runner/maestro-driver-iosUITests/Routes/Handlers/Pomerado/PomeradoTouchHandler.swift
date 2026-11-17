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

/// `POST /pomerado/touch {appId, x, y, duration?, expectAlert?:{title, button}}` -> `{}`.
/// A tap, or a press held for `duration` seconds, at hierarchy coordinates, behind the guard.
@MainActor
struct PomeradoTouchHandler: HTTPHandler {
    private struct Request: PomeradoAppRequest {
        let appId: String
        let x: Double
        let y: Double
        let duration: Double?
        let expectAlert: PomeradoGuard.ExpectAlert?
    }

    func handleRequest(_ request: HTTPRequest) async throws -> HTTPResponse {
        await PomeradoInput.run(request, as: Request.self, expecting: "{appId, x, y, duration?, expectAlert?:{title, button}}") { body, events in
            guard body.x.isFinite, body.y.isFinite else {
                throw PomeradoFailure.invalidRequest("x and y must be finite")
            }
            if let duration = body.duration, !(duration.isFinite && duration >= 0) {
                throw PomeradoFailure.invalidRequest("duration must be a finite number >= 0")
            }
            try await events.tap(at: CGPoint(x: body.x, y: body.y), duration: body.duration, expectAlert: body.expectAlert)
            return [:]
        }
    }
}
