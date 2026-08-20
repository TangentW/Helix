extension CanonicalSIL {
/// The Swift frontend uses generic standard-library cast helpers even when
/// source-level type differences disappear from Helix's stored type model,
/// such as tuple element labels. Lowering may erase these calls only after
/// validating both that the original types differ only by those labels and
/// that the complete source and destination VM types are equal.
enum ManagedCollectionCastIntrinsic: Equatable {
    case arrayForce
    case dictionaryUp

    init?(mangledName: String) {
        switch mangledName {
        case "$ss15_arrayForceCastySayq_GSayxGr0_lF":
            self = .arrayForce
        case "$ss17_dictionaryUpCastySDyq0_q1_GSDyxq_GSHRzSHR0_r2_lF":
            self = .dictionaryUp
        default:
            return nil
        }
    }

    func isTupleLabelErasure(_ substitutions: [String]) -> Bool {
        let pairs: [(String, String)]
        switch self {
        case .arrayForce:
            guard substitutions.count == 2 else { return false }
            pairs = [(substitutions[0], substitutions[1])]
        case .dictionaryUp:
            guard substitutions.count == 4 else { return false }
            pairs = [
                (substitutions[0], substitutions[2]),
                (substitutions[1], substitutions[3]),
            ]
        }
        return pairs.allSatisfy {
            Self.erasingTupleLabels(in: $0.0)
                == Self.erasingTupleLabels(in: $0.1)
        }
    }

    /// Preserve every nominal spelling and erase only labels in tuple-element
    /// positions. VM type equality alone is insufficient because distinct
    /// Swift types such as `CGFloat` and `Double` intentionally share a stored
    /// representation.
    private static func erasingTupleLabels(in raw: String) -> String {
        let characters = Array(raw.filter { !$0.isWhitespace })
        var result = ""
        var index = 0
        while index < characters.count {
            let character = characters[index]
            result.append(character)
            index += 1
            guard character == "(" || character == ",",
                  index < characters.count
            else { continue }

            let labelStart = index
            if characters[index] == "`" {
                index += 1
                while index < characters.count,
                      characters[index] != "`" {
                    index += 1
                }
                guard index < characters.count else {
                    index = labelStart
                    continue
                }
                index += 1
            } else {
                guard Self.isIdentifierHead(characters[index]) else {
                    continue
                }
                index += 1
                while index < characters.count,
                      Self.isIdentifierContinuation(characters[index]) {
                    index += 1
                }
            }
            guard index < characters.count,
                  characters[index] == ":"
            else {
                result.append(contentsOf: characters[labelStart..<index])
                continue
            }
            index += 1
        }
        return result
    }

    private static func isIdentifierHead(_ character: Character) -> Bool {
        character == "_" || character.isLetter
    }

    private static func isIdentifierContinuation(
        _ character: Character
    ) -> Bool {
        isIdentifierHead(character) || character.isNumber
    }
}
}
