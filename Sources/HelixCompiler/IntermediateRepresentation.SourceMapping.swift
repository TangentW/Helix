import HelixCore

extension IntermediateRepresentation {
enum SourceMapping {
    static func retainingLogicalPaths(
        _ function: IntermediateRepresentation.Function,
        logicalPaths: [String]
    ) -> IntermediateRepresentation.Function {
        var result = function
        let candidates = Array(Set(logicalPaths)).sorted()
        var resolvedFiles: [String: String] = [:]
        var rejectedFiles = Set<String>()

        func logicalPath(for file: String) -> String? {
            if let cached = resolvedFiles[file] { return cached }
            guard !rejectedFiles.contains(file) else { return nil }
            let matches = candidates.filter { logicalPath in
                file == logicalPath || file.hasSuffix("/\(logicalPath)")
            }
            guard matches.count == 1, let match = matches.first else {
                rejectedFiles.insert(file)
                return nil
            }
            resolvedFiles[file] = match
            return match
        }

        func normalize(_ location: Core.SourceLocation) -> Core.SourceLocation? {
            guard let path = logicalPath(for: location.file) else { return nil }
            return .init(file: path, line: location.line, column: location.column)
        }

        result.sourceMap = function.sourceMap.compactMap { entry in
            guard let location = normalize(entry.location) else {
                return nil
            }
            var normalized = entry
            normalized.location = location
            return normalized
        }
        result.sourceLocation = function.sourceLocation.flatMap(normalize)
            ?? result.sourceMap.first?.location
        return result
    }
}
}
