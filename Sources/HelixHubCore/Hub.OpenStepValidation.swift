import Foundation

extension Hub {
enum OpenStepValidation {
    /// The system parser is independent of Helix's token editor. Comparing the
    /// decoded values also catches legal output with accidentally changed escapes.
    static func validate(_ data: Data, expected: OpenStep.Value? = nil) throws {
        guard !data.isEmpty, data.count <= OpenStep.maximumDocumentBytes else {
            throw Hub.Error.invalidProject("project.pbxproj is empty or exceeds 32 MiB")
        }
        do {
            var format = PropertyListSerialization.PropertyListFormat.openStep
            let parsed = try PropertyListSerialization.propertyList(from: data, options: [], format: &format)
            guard format == .openStep else {
                throw Hub.Error.invalidProject("project.pbxproj must use OpenStep format")
            }
            var count = 0
            let actual = try value(parsed, depth: 0, count: &count)
            if let expected, actual != expected {
                throw Hub.Error.invalidProject("system OpenStep parser disagrees with the intended PBX values")
            }
        } catch {
            throw Hub.Error.invalidProject("system OpenStep validation failed: \(error)")
        }
    }

    private static func value(_ input: Any, depth: Int, count: inout Int) throws -> OpenStep.Value {
        count += 1
        guard depth <= OpenStep.maximumNestingDepth, count <= OpenStep.maximumValueCount else {
            throw Hub.Error.invalidProject("project.pbxproj exceeds nesting or value bounds")
        }
        if let string = input as? String { return .string(string) }
        if let array = input as? [Any] {
            return .array(try array.map { try value($0, depth: depth + 1, count: &count) })
        }
        if let dictionary = input as? [String: Any] {
            return .dictionary(try dictionary.mapValues { try value($0, depth: depth + 1, count: &count) })
        }
        throw Hub.Error.invalidProject("project.pbxproj contains an unsupported property-list value")
    }
}
}
