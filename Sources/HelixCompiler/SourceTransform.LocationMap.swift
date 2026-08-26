import Foundation

extension SourceTransform {
/// Maps typed-frontend UTF-8 offsets back to Swift's one-based logical line
/// and byte-column coordinates. One immutable map can be shared by every edit
/// in a file, keeping a transformation linearithmic even with many roots.
package struct LocationMap: Sendable {
    private let utf8Count: Int
    private let lineStarts: [Int]

    package init(_ source: Data) {
        utf8Count = source.count
        var starts = [0]
        var index = source.startIndex
        var offset = 0
        while index < source.endIndex {
            let byte = source[index]
            if byte == UInt8(ascii: "\n") {
                starts.append(offset + 1)
            } else if byte == UInt8(ascii: "\r"),
                      index + 1 == source.endIndex
                        || source[index + 1] != UInt8(ascii: "\n") {
                starts.append(offset + 1)
            }
            index += 1
            offset += 1
        }
        lineStarts = starts
    }

    package func location(
        atUTF8Offset offset: Int
    ) -> (line: Int, column: Int)? {
        guard offset >= 0, offset <= utf8Count else { return nil }
        var lower = 0
        var upper = lineStarts.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if lineStarts[middle] <= offset {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        let lineIndex = max(0, lower - 1)
        return (
            line: lineIndex + 1,
            column: offset - lineStarts[lineIndex] + 1
        )
    }

    package func utf8Offset(line: Int, column: Int) -> Int? {
        guard line > 0,
              line <= lineStarts.count,
              column > 0
        else { return nil }
        let offset = lineStarts[line - 1] + column - 1
        guard offset <= utf8Count,
              line == lineStarts.count || offset < lineStarts[line]
        else { return nil }
        return offset
    }
}
}
