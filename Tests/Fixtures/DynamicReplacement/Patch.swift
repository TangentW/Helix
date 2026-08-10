import Feature

@_dynamicReplacement(for: helixFixtureValue(_:))
public func replacementHelixFixtureValue(_ input: Int) -> Int {
    input + 7
}

@_dynamicReplacement(for: recursiveGlobal(_:))
public func replacementRecursiveGlobal(_ n: Int) -> Int {
    n < 2 ? 2 : n * replacementRecursiveGlobal(n - 1)
}

@_dynamicReplacement(for: explicitPreviousChain(_:))
public func replacementExplicitPreviousChain(_ input: Int) -> Int {
    input + 10
}

extension RecursiveBox {
    @_dynamicReplacement(for: recursiveInstance(_:))
    public func replacementRecursiveInstance(_ n: Int) -> Int {
        n < 2 ? 2 : n * replacementRecursiveInstance(n - 1)
    }

    @_dynamicReplacement(for: recursiveStatic(_:))
    public static func replacementRecursiveStatic(_ n: Int) -> Int {
        n < 2 ? 2 : n * replacementRecursiveStatic(n - 1)
    }

    @_dynamicReplacement(for: recursiveClass(_:))
    public class func replacementRecursiveClass(_ n: Int) -> Int {
        n < 2 ? 2 : n * replacementRecursiveClass(n - 1)
    }

    @_dynamicReplacement(for: recursiveGeneric(_:))
    public func replacementRecursiveGeneric<T: BinaryInteger>(_ n: T) -> T {
        n < 2 ? 2 : n * replacementRecursiveGeneric(n - 1)
    }
}

@_cdecl("hlx_generation_registration_v1")
public func generationRegistration() -> UInt32 {
    7
}
