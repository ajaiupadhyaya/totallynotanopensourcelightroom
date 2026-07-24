import Foundation

/// Parses Adobe `.cube` LUT files into data suitable for `CIColorCube`.
enum LUTImporter {
    struct ParsedLUT {
        var name: String
        var dimension: Int
        var cubeData: Data
    }

    static func parse(url: URL) throws -> ParsedLUT {
        let text = try String(contentsOf: url, encoding: .utf8)
        return try parse(text: text, name: url.deletingPathExtension().lastPathComponent)
    }

    static func parse(text: String, name: String) throws -> ParsedLUT {
        var dimension = 0
        var values = [Float]()

        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            if trimmed.hasPrefix("TITLE") { continue }
            if trimmed.hasPrefix("LUT_3D_SIZE") {
                let parts = trimmed.split(whereSeparator: \.isWhitespace)
                guard parts.count >= 2, let size = Int(parts[1]) else {
                    throw ImportError.invalidHeader
                }
                dimension = size
                continue
            }
            if trimmed.hasPrefix("DOMAIN_") { continue }

            let parts = trimmed.split(whereSeparator: \.isWhitespace).compactMap(Double.init)
            guard parts.count >= 3 else { continue }
            values.append(Float(parts[0]))
            values.append(Float(parts[1]))
            values.append(Float(parts[2]))
            values.append(1)
        }

        guard dimension > 1 else { throw ImportError.invalidHeader }
        let expected = dimension * dimension * dimension * 4
        guard values.count == expected else { throw ImportError.sizeMismatch }

        return ParsedLUT(
            name: name,
            dimension: dimension,
            cubeData: values.withUnsafeBufferPointer { Data(buffer: $0) }
        )
    }

    enum ImportError: Error {
        case invalidHeader
        case sizeMismatch
    }
}
