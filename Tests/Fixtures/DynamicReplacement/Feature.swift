public dynamic func helixFixtureValue(_ input: Int) -> Int {
    input + 1
}

public dynamic func recursiveGlobal(_ n: Int) -> Int {
    n < 2 ? 1 : n * recursiveGlobal(n - 1)
}

public dynamic func explicitPreviousChain(_ input: Int) -> Int {
    input + 1
}

public class RecursiveBox {
    public init() {}

    public dynamic func recursiveInstance(_ n: Int) -> Int {
        n < 2 ? 1 : n * recursiveInstance(n - 1)
    }

    public dynamic static func recursiveStatic(_ n: Int) -> Int {
        n < 2 ? 1 : n * recursiveStatic(n - 1)
    }

    public dynamic class func recursiveClass(_ n: Int) -> Int {
        n < 2 ? 1 : n * recursiveClass(n - 1)
    }

    public dynamic func recursiveGeneric<T: BinaryInteger>(_ n: T) -> T {
        n < 2 ? 1 : n * recursiveGeneric(n - 1)
    }
}
