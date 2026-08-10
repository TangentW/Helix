import Foundation

extension CLI {
struct Arguments {
    private(set) var values: [String: [String]] = [:]
    private(set) var flags: Set<String> = []
    private(set) var positionals: [String] = []

    init(
        _ arguments: [String],
        valueOptions: Set<String>,
        flagOptions: Set<String>
    ) throws {
        var index = 0
        var optionsEnabled = true
        while index < arguments.count {
            let argument = arguments[index]
            if optionsEnabled, argument == "--" {
                optionsEnabled = false
                index += 1
                continue
            }
            guard optionsEnabled, argument.hasPrefix("--") else {
                positionals.append(argument)
                index += 1
                continue
            }

            let optionText = String(argument.dropFirst(2))
            guard !optionText.isEmpty else {
                throw CLI.Error.usage("empty option")
            }
            let components = optionText.split(separator: "=", maxSplits: 1).map(String.init)
            let name = components[0]
            if flagOptions.contains(name) {
                guard components.count == 1 else {
                    throw CLI.Error.usage("--\(name) does not accept a value")
                }
                guard flags.insert(name).inserted else {
                    throw CLI.Error.usage("--\(name) was supplied more than once")
                }
                index += 1
                continue
            }
            guard valueOptions.contains(name) else {
                throw CLI.Error.usage("unknown option --\(name)")
            }

            let value: String
            if components.count == 2 {
                value = components[1]
            } else {
                index += 1
                guard index < arguments.count else {
                    throw CLI.Error.usage("--\(name) requires a value")
                }
                guard !arguments[index].hasPrefix("--") else {
                    throw CLI.Error.usage(
                        "--\(name) requires a value; use --\(name)=VALUE when VALUE begins with --"
                    )
                }
                value = arguments[index]
            }
            guard !value.isEmpty else {
                throw CLI.Error.usage("--\(name) requires a nonempty value")
            }
            values[name, default: []].append(value)
            index += 1
        }
    }

    func value(_ name: String) throws -> String? {
        guard let values = values[name] else { return nil }
        guard values.count == 1 else {
            throw CLI.Error.usage("--\(name) may be supplied only once")
        }
        return values[0]
    }

    func require(_ name: String) throws -> String {
        guard let value = try value(name) else {
            throw CLI.Error.usage("missing required option --\(name)")
        }
        return value
    }

    func all(_ name: String) -> [String] {
        values[name] ?? []
    }

    func hasFlag(_ name: String) -> Bool {
        flags.contains(name)
    }
}
}
