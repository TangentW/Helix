extension CanonicalSIL {
/// Recognizes the bounded compiler ABI used when Swift boxes an arbitrary
/// value for an Objective-C `AnyObject` parameter. The opened-archetype token
/// is compiler-local metadata; HLBC keeps the enclosing `Any` value instead.
public enum AnyObjectBridge {}
}

extension CanonicalSIL.AnyObjectBridge {
    public static let silMangledName = "$ss27_bridgeAnythingToObjectiveCyyXlxlF"

    public static func isReferenceInstruction(_ raw: String) -> Bool {
        let line = raw.trimmingCharacters(in: .whitespaces)
        let marker = " = function_ref @"
        guard let markerRange = line.range(of: marker),
              line.first == "%"
        else { return false }
        let registerIndex = line[
            line.index(after: line.startIndex)..<markerRange.lowerBound
        ]
        guard !registerIndex.isEmpty,
              registerIndex.allSatisfy(\.isNumber)
        else { return false }
        let reference = line[markerRange.upperBound...]
        guard reference.hasPrefix(silMangledName) else { return false }
        return reference.dropFirst(silMangledName.count).hasPrefix(" : $")
    }

    public static func isOpenedAnyArchetype(_ raw: String) -> Bool {
        var value = raw.trimmingCharacters(in: .whitespaces)
        while value.first == "$" || value.first == "*" {
            value.removeFirst()
        }
        let prefix = "@opened(\""
        guard value.hasPrefix(prefix),
              let delimiter = value.range(
                of: "\", ",
                range: prefix.endIndex..<value.endIndex
              )
        else { return false }

        let identity = value[prefix.endIndex..<delimiter.lowerBound]
        guard !identity.isEmpty,
              identity.utf8.count <= 128,
              identity.utf8.allSatisfy({ byte in
                  byte == 0x2D || byte == 0x5F
                      || (0x30...0x39).contains(byte)
                      || (0x41...0x5A).contains(byte)
                      || (0x61...0x7A).contains(byte)
              })
        else { return false }

        let tail = value[delimiter.upperBound...]
        return tail == "Any) Self" || tail == "Swift.Any) Self"
    }

    static func isObjectiveCProtocolExistential(_ raw: String) -> Bool {
        let spelling = raw.trimmingCharacters(in: .whitespaces)
        guard spelling.utf8.count <= 1_024,
              spelling.hasPrefix("any ")
        else { return false }
        let protocols = spelling.dropFirst("any ".count).split(
            separator: "&",
            omittingEmptySubsequences: false
        ).map { $0.trimmingCharacters(in: .whitespaces) }
        guard !protocols.isEmpty, protocols.count <= 16 else { return false }
        let forbidden = Set([
            "Any", "AnyObject", "Error", "Sendable",
            "Swift.Any", "Swift.AnyObject", "Swift.Error", "Swift.Sendable",
        ])
        return protocols.allSatisfy { name in
            !forbidden.contains(name)
                && !name.isEmpty
                && name.split(separator: ".", omittingEmptySubsequences: false)
                    .allSatisfy { component in
                        !component.isEmpty
                            && component.allSatisfy {
                                $0 == "_" || $0.isLetter || $0.isNumber
                            }
                    }
        }
    }
}
