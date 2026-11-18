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

import Foundation

/// Picker wheel value match, shared with Pomerado's host port (`pickerValueMatch` in
/// `src/core/native-actions.ts`, same test vectors). A wheel value matches the requested one
/// exactly, or by a leading token: it starts with the requested value and the next character is
/// not a letter, mark or number. So "14" matches "14 o’clock", "1" does not, and "Jan" does not
/// match "January". Comparison is by Unicode scalar, without normalization.
public enum PickerValueMatch: Equatable {
    case exact
    case token

    public static func match(_ observed: String?, _ requested: String) -> PickerValueMatch? {
        guard let observed, !requested.isEmpty else { return nil }
        let value = Array(observed.unicodeScalars), wanted = Array(requested.unicodeScalars)
        if value == wanted { return .exact }
        guard value.count > wanted.count, value.starts(with: wanted) else { return nil }
        return CharacterSet.alphanumerics.contains(value[wanted.count]) ? nil : .token
    }

    /// The candidate the rule selects: an exact match wins over any token-boundary match.
    public static func best(_ candidates: [String], _ requested: String) -> String? {
        candidates.first { match($0, requested) == .exact } ?? candidates.first { match($0, requested) == .token }
    }
}
