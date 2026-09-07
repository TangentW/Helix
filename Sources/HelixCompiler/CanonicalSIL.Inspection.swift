import Foundation

extension CanonicalSIL {
/// Independently validated SIL facts. A failed component never supplies a
/// substitute value, and `file` exists only after every required check passes.
public struct Inspection: Sendable {
    public enum Component: String, CaseIterable, Sendable {
        case functionDefinitions = "function_definitions"
        case debugScopes = "debug_scopes"
        case sourceModules = "source_modules"
        case conformances
        case nominalDeclarations = "nominal_declarations"
        case functionLocations = "function_locations"
        case typeEnvironment = "type_environment"
        case file
    }

    public struct Check: Sendable {
        public enum Status: String, Sendable { case passed, failed, blocked }
        public let component: Component
        public let status: Status
        public let detail: String
        public let durationMicroseconds: UInt64
    }

    public let checks: [Check]
    public let functions: [Function]?
    public let file: File?

    public init(text: String) throws {
        self = try Self.parse(text, collectFailures: true)
    }

    public func requireFile() throws -> File {
        guard let file else {
            throw LoweringError.malformedSIL(checks.filter { $0.status != .passed }
                .map { "[\($0.status.rawValue)] \($0.component.rawValue): \($0.detail)" }.joined(separator: "\n"))
        }
        return file
    }

    private init(checks: [Check], functions: [Function]?, file: File?) {
        self.checks = checks
        self.functions = functions
        self.file = file
    }

    static func parse(_ text: String, collectFailures: Bool) throws -> Self {
        var checks: [Check] = []
        var passed = Set<Component>()
        func run<T>(_ component: Component, dependencies: [Component] = [], _ work: () throws -> T) throws -> T? {
            let blocked = dependencies.filter { !passed.contains($0) }
            guard blocked.isEmpty else {
                checks.append(.init(component: component, status: .blocked,
                    detail: "Requires successful checks: " + blocked.map(\.rawValue).joined(separator: ", "), durationMicroseconds: 0))
                return nil
            }
            let started = DispatchTime.now().uptimeNanoseconds
            do {
                try Task.checkCancellation()
                let value = try work()
                passed.insert(component)
                checks.append(.init(component: component, status: .passed, detail: "",
                    durationMicroseconds: (DispatchTime.now().uptimeNanoseconds - started) / 1_000))
                return value
            } catch {
                if error is CancellationError || !collectFailures { throw error }
                checks.append(.init(component: component, status: .failed, detail: String(describing: error),
                    durationMicroseconds: (DispatchTime.now().uptimeNanoseconds - started) / 1_000))
                return nil
            }
        }
        var definitions = try run(.functionDefinitions) { try File.extractFunctionDefinitions(text) }
        let scopes = try run(.debugScopes) { try DebugMetadata.scopes(in: text) }
        let functions = try run(.functionLocations, dependencies: [.functionDefinitions, .debugScopes]) {
            try File.locateFunctions(definitions!, scopes: scopes!)
        }
        // Release raw body lines before parsing large conformance/type tables.
        definitions = nil
        let modules = try run(.sourceModules) { try DebugMetadata.sourceModules(in: text) }
        let conformances = try run(.conformances) { try ProtocolConformance.Environment(text: text) }
        let declarations = try run(.nominalDeclarations) { try TypeEnvironment.DeclarationSummary(text: text) }
        let types = try run(.typeEnvironment, dependencies: [.nominalDeclarations, .conformances, .functionLocations]) {
            try declarations!.environment(functions: functions!, conformances: conformances!)
        }
        let file = try run(.file, dependencies: [.sourceModules, .functionLocations, .conformances, .typeEnvironment]) {
            try File(parsedFunctions: functions!, parsedConformances: conformances!,
                rawTypeEnvironment: types!, sourceModules: modules!)
        }
        return .init(checks: checks, functions: functions, file: file)
    }
}
}
