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

import XCTest
@testable import MaestroDriverLib

/// The same vectors as Pomerado's `tests/core/xctest-port.test.ts` (PICKER_MATCH_VECTORS).
final class PickerValueMatchTests: XCTestCase {
    private let vectors: [(String?, String, PickerValueMatch?)] = [
        ("14 o’clock", "14", .token), ("14 o’clock", "1", nil), ("January", "Jan", nil), ("14", "14", .exact), ("14 o’clock", "14 o’clock", .exact),
        ("14:00", "14", .token), ("14\u{00a0}o’clock", "14", .token), ("Jan.", "Jan", .token), ("14o", "14", nil), ("140", "14", nil), ("10", "1", nil),
        ("February 14", "14", nil), (" 14", "14", nil), ("14", "14 o’clock", nil), ("Élan", "É", nil), ("1\u{0663}", "1", nil), ("14", "", nil), (nil, "14", nil),
    ]

    func testVectors() {
        for (observed, requested, expected) in vectors {
            XCTAssertEqual(PickerValueMatch.match(observed, requested), expected, "\(String(describing: observed)) against \(requested)")
        }
    }

    func testExactMatchWinsOverTokenMatch() {
        XCTAssertEqual(PickerValueMatch.best(["14 o’clock", "14"], "14"), "14")
        XCTAssertEqual(PickerValueMatch.best(["14", "14 o’clock"], "14"), "14")
        XCTAssertEqual(PickerValueMatch.best(["140", "14 o’clock", "14:00"], "14"), "14 o’clock")
        XCTAssertNil(PickerValueMatch.best(["January"], "Jan"))
    }
}
