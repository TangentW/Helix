import Foundation

extension Hub {
/// Loss-minimal editor for the small set of PBX objects owned by Helix.
/// Existing records remain byte-for-byte intact unless Helix must change them.
struct PBXProjectDocument {
    private(set) var objects: [String: Hub.OpenStep.Value]
    let projectObjectID: String

    private let originalText: String
    private let originalSyntax: Hub.OpenStep.Syntax

    init(data: Data) throws {
        guard let text = String(data: data, encoding: .utf8) else {
            throw Hub.Error.invalidProject("project.pbxproj is not UTF-8")
        }
        var parser = try Hub.OpenStep.Parser(data: data)
        let syntax = try parser.parseSyntax()
        try Hub.OpenStepValidation.validate(data, expected: syntax.value)
        guard case let .dictionary(root) = syntax.value,
              let parsedObjects = root["objects"]?.dictionary,
              let rootID = root["rootObject"]?.string,
              parsedObjects[rootID]?.dictionary?["isa"]?.string == "PBXProject"
        else {
            throw Hub.Error.invalidProject("PBXProject root object is missing")
        }
        originalText = text
        originalSyntax = syntax
        objects = parsedObjects
        projectObjectID = rootID
    }

    func object(_ identifier: String) throws -> [String: Hub.OpenStep.Value] {
        guard let value = objects[identifier]?.dictionary else {
            throw Hub.Error.invalidProject("PBX object \(identifier) is missing")
        }
        return value
    }

    mutating func updateObject(
        _ identifier: String,
        _ transform: (inout [String: Hub.OpenStep.Value]) throws -> Void
    ) throws {
        var dictionary = try object(identifier)
        try transform(&dictionary)
        let value = Hub.OpenStep.Value.dictionary(dictionary)
        objects[identifier] = value
    }

    mutating func addObject(
        _ identifier: String,
        isa: String,
        fields: [String: Hub.OpenStep.Value]
    ) throws {
        var dictionary = fields
        dictionary["isa"] = .string(isa)
        let value = Hub.OpenStep.Value.dictionary(dictionary)
        if let existing = objects[identifier] {
            guard existing.dictionary?["isa"]?.string == isa else {
                throw Hub.Error.invalidProject(
                    "deterministic PBX identifier \(identifier) collides with an existing object"
                )
            }
        }
        objects[identifier] = value
    }

    mutating func removeObject(_ identifier: String) {
        objects.removeValue(forKey: identifier)
    }

    func configurationID(targetID: String, named name: String) throws -> String {
        let target = try object(targetID)
        guard let listID = target["buildConfigurationList"]?.string,
              let list = objects[listID]?.dictionary,
              let configurationIDs = list["buildConfigurations"]?.array
        else {
            throw Hub.Error.invalidProject("target has no build configuration list")
        }
        let matches = configurationIDs.compactMap(\.string).filter { identifier in
            objects[identifier]?.dictionary?["name"]?.string == name
        }
        guard matches.count == 1, let identifier = matches.first else {
            throw Hub.Error.invalidProject(
                "target does not have exactly one \(name) build configuration"
            )
        }
        return identifier
    }

    func serialized() throws -> Data {
        guard var root = originalSyntax.value.dictionary else {
            throw Hub.Error.invalidProject("PBX root dictionary disappeared")
        }
        root["objects"] = .dictionary(objects)
        let expected = Hub.OpenStep.Value.dictionary(root)
        var editor = Hub.OpenStepEditor(text: originalText)
        editor.replace(originalSyntax, with: expected)
        let data = try editor.serialized()
        var parser = try Hub.OpenStep.Parser(data: data)
        guard try parser.parse() == expected else {
            throw Hub.Error.invalidProject("generated PBX text changed unintended values")
        }
        try Hub.OpenStepValidation.validate(data, expected: expected)
        return data
    }
}
}

extension Hub.OpenStep.Value {
    static func strings(_ values: [String]) -> Self {
        .array(values.map(Self.string))
    }
}
