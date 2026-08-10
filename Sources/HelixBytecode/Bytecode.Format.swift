import Foundation
import HelixCore

public enum Bytecode {}

extension Bytecode {
public enum Format {
    public static let magic: [UInt8] = [0x48, 0x4c, 0x42, 0x43, 0x00, 0x0d, 0x0a, 0x1a]
    public static let majorVersion: UInt16 = 1
    public static let minorVersion: UInt16 = 9
}
}
