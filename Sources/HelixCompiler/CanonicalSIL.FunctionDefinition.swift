import Foundation
import HelixCore

extension CanonicalSIL {
/// Parsed syntax without any claim that its debug references have resolved.
struct FunctionDefinition: Sendable {
    var mangledName: String
    var loweredType: String
    var bodyLines: [String]
    var isolation: FunctionIsolation
    var isExternalDefinition: Bool

    func function(scopeLocations: [UInt32: Core.SourceLocation]) throws -> Function {
        var locations: [DebugLineLocation] = []
        let body = try bodyLines.enumerated().map { offset, line in
            let parsed = try DebugMetadata.parse(line, scopes: scopeLocations)
            if let location = parsed.location { locations.append(.init(line: offset + 1, location: location)) }
            return parsed.instruction
        }.joined(separator: "\n")
        return .init(mangledName: mangledName, loweredType: loweredType, body: body, isolation: isolation,
            declarationLocation: nil, debugLineLocations: locations, isExternalDefinition: isExternalDefinition)
    }
}
}
