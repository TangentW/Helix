import Darwin
import Feature

guard CommandLine.arguments.count == 3 else {
    fatalError("expected two patch image paths")
}

typealias Registration = @convention(c) () -> UInt32

func printSnapshot() {
    let box = RecursiveBox()
    print([
        helixFixtureValue(1),
        explicitPreviousChain(1),
        recursiveGlobal(4),
        box.recursiveInstance(4),
        RecursiveBox.recursiveStatic(4),
        RecursiveBox.recursiveClass(4),
        box.recursiveGeneric(Int(4)),
    ].map(String.init).joined(separator: ","))
}

func load(_ path: String) -> UInt32 {
    guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
        fatalError(String(cString: dlerror()))
    }
    guard let symbol = dlsym(handle, "hlx_generation_registration_v1") else {
        fatalError("missing registration symbol")
    }
    return unsafeBitCast(symbol, to: Registration.self)()
}

printSnapshot()
let firstRootCount = load(CommandLine.arguments[1])
printSnapshot()
print(firstRootCount)
let secondRootCount = load(CommandLine.arguments[2])
printSnapshot()
print(secondRootCount)
