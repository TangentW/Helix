import Foundation
import HelixBuildTools
import HelixCore

extension CLI {
struct XcodeObjectMaterialization: Sendable {
    var url: URL
    var data: Data
    var cacheSource: BuildCache.Source
}
}

extension CLI.Application {
/// Resolves a validated Mach-O object through the shared content-addressed
/// cache and always materializes it at the request's transient output path.
func materializeXcodeObject(
    outputURL: URL,
    namespace: BuildCache.Namespace,
    cacheKey: Core.Digest?,
    cache: BuildCache.Store?,
    context: XcodeIntegration.BuildContext,
    label: String,
    produce: () throws -> Data
) throws -> CLI.XcodeObjectMaterialization {
    let value: BuildCache.Value
    if let cache, let cacheKey {
        value = try cache.value(
            namespace: namespace,
            key: cacheKey,
            maximumBytes: 512 * 1_024 * 1_024,
            validate: { bytes in
                try validateXcodeObject(bytes, context: context, label: label)
            },
            produce: produce
        )
    } else {
        let data = try produce()
        try validateXcodeObject(data, context: context, label: label)
        value = .init(data: data, source: .bypassed)
    }
    try files.write(value.data, to: outputURL)
    try validateXcodeObject(outputURL, context: context, label: label)
    return .init(url: outputURL, data: value.data, cacheSource: value.source)
}
}
