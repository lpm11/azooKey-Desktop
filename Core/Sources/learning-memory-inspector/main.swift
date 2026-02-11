import Foundation

private struct Entry: Codable {
    let ruby: String
    let word: String
    let value: Float32
    let lcid: Int
    let rcid: Int
    let mid: Int
    let shardFile: String
}

private struct Summary: Codable {
    let memoryDirectory: String
    let files: [String]
    let totalCount: Int
    let filteredCount: Int
}

private struct JSONPayload: Codable {
    let summary: Summary
    let entries: [Entry]
}

private enum SortKey: String {
    case value
    case ruby
    case word
}

private struct Options {
    var memoryDir: String = [
        NSHomeDirectory(),
        "Library",
        "Containers",
        "dev.lpm11.inputmethod.azooKeyMac",
        "Data",
        "Library",
        "Application Support",
        "azooKey",
        "memory"
    ].joined(separator: "/")
    var rubyRegexPattern: String?
    var wordRegexPattern: String?
    var sortKey: SortKey = .value
    var limit: Int = 100
    var json: Bool = false
    var includeTempFiles: Bool = false
}

private enum CLIError: Error, CustomStringConvertible {
    case invalidOption(String)
    case missingValue(String)
    case invalidValue(String)
    case directoryNotFound(String)
    case failedToReadFile(String)

    var description: String {
        switch self {
        case let .invalidOption(option):
            "Unknown option: \(option)"
        case let .missingValue(option):
            "Missing value for option: \(option)"
        case let .invalidValue(reason):
            "Invalid value: \(reason)"
        case let .directoryNotFound(path):
            "Directory not found: \(path)"
        case let .failedToReadFile(path):
            "Failed to read file: \(path)"
        }
    }
}

private func usageText() -> String {
    """
    learning-memory-inspector

    Read azooKey learning memory files (memory*.loudstxt3) and print learned entries.

    Usage:
      swift run --package-path Core learning-memory-inspector [options]

    Options:
      -d, --memory-dir <path>   Memory directory path
          --ruby <regex>        Filter entries by ruby
          --word <regex>        Filter entries by word
          --sort <value|ruby|word>
                                Sort key (default: value)
          --limit <n>           Maximum entries to print (default: 100)
          --json                Print entries as JSON
          --include-temp        Include temporary .2 files
      -h, --help                Show this help
    """
}

private func nextArgument(arguments: [String], index: inout Int, option: String) throws -> String {
    index += 1
    guard index < arguments.count else {
        throw CLIError.missingValue(option)
    }
    return arguments[index]
}

private func applyOptionWithValue(arg: String, value: String, options: inout Options) throws {
    switch arg {
    case "-d", "--memory-dir":
        options.memoryDir = value
    case "--ruby":
        options.rubyRegexPattern = value
    case "--word":
        options.wordRegexPattern = value
    case "--sort":
        guard let sortKey = SortKey(rawValue: value) else {
            throw CLIError.invalidValue("sort must be one of: value, ruby, word")
        }
        options.sortKey = sortKey
    case "--limit":
        guard let intValue = Int(value), intValue >= 0 else {
            throw CLIError.invalidValue("limit must be >= 0")
        }
        options.limit = intValue
    default:
        throw CLIError.invalidOption(arg)
    }
}

private func applyOption(arg: String, arguments: [String], index: inout Int, options: inout Options) throws {
    switch arg {
    case "-h", "--help":
        print(usageText())
        Foundation.exit(0)
    case "--json":
        options.json = true
    case "--include-temp":
        options.includeTempFiles = true
    default:
        let value = try nextArgument(arguments: arguments, index: &index, option: arg)
        try applyOptionWithValue(arg: arg, value: value, options: &options)
    }
}

private func parseOptions(arguments: [String]) throws -> Options {
    var options = Options()
    var index = 0
    while index < arguments.count {
        let arg = arguments[index]
        try applyOption(arg: arg, arguments: arguments, index: &index, options: &options)
        index += 1
    }
    return options
}

private func readUInt16LE(_ data: Data, _ offset: Int) -> UInt16 {
    let b0 = UInt16(data[data.startIndex + offset])
    let b1 = UInt16(data[data.startIndex + offset + 1])
    return b0 | (b1 << 8)
}

private func readUInt32LE(_ data: Data, _ offset: Int) -> UInt32 {
    let b0 = UInt32(data[data.startIndex + offset])
    let b1 = UInt32(data[data.startIndex + offset + 1])
    let b2 = UInt32(data[data.startIndex + offset + 2])
    let b3 = UInt32(data[data.startIndex + offset + 3])
    return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
}

private func readFloat32LE(_ data: Data, _ offset: Int) -> Float32 {
    Float32(bitPattern: readUInt32LE(data, offset))
}

private func decodeTabSeparatedFields(_ data: Data) -> [String] {
    let bytes = [UInt8](data)
    if bytes.isEmpty {
        return []
    }
    var fields: [String] = []
    var start = 0
    for i in 0 ... bytes.count {
        if i == bytes.count || bytes[i] == UInt8(ascii: "\t") {
            if start == i {
                fields.append("")
            } else {
                let fieldData = Data(bytes[start ..< i])
                let field = String(data: fieldData, encoding: .utf8) ?? ""
                fields.append(field)
            }
            start = i + 1
        }
    }
    return fields
}

private func parseEntryBlock(_ data: Data, shardFile: String) -> [Entry] {
    guard data.count >= 2 else {
        return []
    }
    let rowCount = Int(readUInt16LE(data, 0))
    let rowBytesLength = rowCount * 10
    let headerLength = 2 + rowBytesLength
    guard data.count >= headerLength else {
        return []
    }

    struct ParsedRow {
        let lcid: Int
        let rcid: Int
        let mid: Int
        let value: Float32
    }

    var values: [ParsedRow] = []
    values.reserveCapacity(rowCount)
    for i in 0 ..< rowCount {
        let offset = 2 + i * 10
        let lcid = Int(readUInt16LE(data, offset + 0))
        let rcid = Int(readUInt16LE(data, offset + 2))
        let mid = Int(readUInt16LE(data, offset + 4))
        let value = readFloat32LE(data, offset + 6)
        values.append(.init(lcid: lcid, rcid: rcid, mid: mid, value: value))
    }

    let fields = decodeTabSeparatedFields(data[data.startIndex + headerLength ..< data.endIndex])
    let ruby = fields.first ?? ""

    var entries: [Entry] = []
    entries.reserveCapacity(rowCount)
    for i in 0 ..< rowCount {
        let fieldIndex = i + 1
        let wordField = fieldIndex < fields.count ? fields[fieldIndex] : ""
        let word = wordField.isEmpty ? ruby : wordField
        entries.append(
            Entry(
                ruby: ruby,
                word: word,
                value: values[i].value,
                lcid: values[i].lcid,
                rcid: values[i].rcid,
                mid: values[i].mid,
                shardFile: shardFile
            )
        )
    }
    return entries
}

private func parseLoudstxt3File(url: URL) throws -> [Entry] {
    let data: Data
    do {
        data = try Data(contentsOf: url, options: [.mappedIfSafe])
    } catch {
        throw CLIError.failedToReadFile(url.path)
    }

    guard data.count >= 2 else {
        return []
    }
    let blockCount = Int(readUInt16LE(data, 0))
    let tableSize = 2 + blockCount * 4
    guard data.count >= tableSize else {
        return []
    }

    var offsets: [Int] = []
    offsets.reserveCapacity(blockCount)
    for i in 0 ..< blockCount {
        let offset = Int(readUInt32LE(data, 2 + i * 4))
        offsets.append(offset)
    }

    var entries: [Entry] = []
    for i in 0 ..< blockCount {
        let start = offsets[i]
        let end = i == blockCount - 1 ? data.count : offsets[i + 1]
        guard tableSize <= start, start < end, end <= data.count else {
            continue
        }
        let block = data[data.startIndex + start ..< data.startIndex + end]
        entries.append(contentsOf: parseEntryBlock(Data(block), shardFile: url.lastPathComponent))
    }
    return entries
}

private func parseMemoryFileIndex(_ fileName: String) -> Int? {
    guard fileName.hasPrefix("memory"), fileName.hasSuffix(".loudstxt3") else {
        return nil
    }
    let suffixRemoved = fileName
        .dropFirst("memory".count)
        .dropLast(".loudstxt3".count)
    return Int(suffixRemoved)
}

private func findTargetFiles(directoryURL: URL, includeTempFiles: Bool) throws -> [URL] {
    let fm = FileManager.default
    guard fm.fileExists(atPath: directoryURL.path, isDirectory: nil) else {
        throw CLIError.directoryNotFound(directoryURL.path)
    }
    let fileURLs = try fm.contentsOfDirectory(
        at: directoryURL,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
    )

    let loudstxt3URLs: [URL] = fileURLs.compactMap { fileURL in
        let name = fileURL.lastPathComponent
        if includeTempFiles {
            if name.hasPrefix("memory"), name.contains(".loudstxt3") {
                return fileURL
            }
            return nil
        } else if name.hasPrefix("memory"), name.hasSuffix(".loudstxt3"), !name.hasSuffix(".loudstxt3.2") {
            return fileURL
        }
        return nil
    }

    return loudstxt3URLs.sorted { lhs, rhs in
        let leftName = lhs.lastPathComponent.replacingOccurrences(of: ".2", with: "")
        let rightName = rhs.lastPathComponent.replacingOccurrences(of: ".2", with: "")
        let leftIndex = parseMemoryFileIndex(leftName) ?? .max
        let rightIndex = parseMemoryFileIndex(rightName) ?? .max
        if leftIndex == rightIndex {
            return lhs.lastPathComponent < rhs.lastPathComponent
        }
        return leftIndex < rightIndex
    }
}

private func filterEntries(_ entries: [Entry], rubyPattern: String?, wordPattern: String?) throws -> [Entry] {
    let rubyRegex: NSRegularExpression? = if let rubyPattern, !rubyPattern.isEmpty {
        try NSRegularExpression(pattern: rubyPattern)
    } else {
        nil
    }
    let wordRegex: NSRegularExpression? = if let wordPattern, !wordPattern.isEmpty {
        try NSRegularExpression(pattern: wordPattern)
    } else {
        nil
    }

    return entries.filter { entry in
        let rubyOK: Bool
        if let rubyRegex {
            let range = NSRange(entry.ruby.startIndex..<entry.ruby.endIndex, in: entry.ruby)
            rubyOK = rubyRegex.firstMatch(in: entry.ruby, options: [], range: range) != nil
        } else {
            rubyOK = true
        }
        let wordOK: Bool
        if let wordRegex {
            let range = NSRange(entry.word.startIndex..<entry.word.endIndex, in: entry.word)
            wordOK = wordRegex.firstMatch(in: entry.word, options: [], range: range) != nil
        } else {
            wordOK = true
        }
        return rubyOK && wordOK
    }
}

private func sortEntries(_ entries: [Entry], sortKey: SortKey) -> [Entry] {
    entries.sorted { lhs, rhs in
        switch sortKey {
        case .value:
            if lhs.value == rhs.value {
                if lhs.ruby == rhs.ruby {
                    return lhs.word < rhs.word
                }
                return lhs.ruby < rhs.ruby
            }
            return lhs.value < rhs.value
        case .ruby:
            if lhs.ruby == rhs.ruby {
                if lhs.word == rhs.word {
                    return lhs.value < rhs.value
                }
                return lhs.word < rhs.word
            }
            return lhs.ruby < rhs.ruby
        case .word:
            if lhs.word == rhs.word {
                if lhs.ruby == rhs.ruby {
                    return lhs.value < rhs.value
                }
                return lhs.ruby < rhs.ruby
            }
            return lhs.word < rhs.word
        }
    }
}

private func printSummary(
    directoryPath: String,
    files: [URL],
    allEntriesCount: Int,
    filteredCount: Int
) {
    print("=== learning-memory-inspector summary ===")
    print("- memory directory: \(directoryPath)")
    print("- loudstxt3 files: \(files.count)")
    if !files.isEmpty {
        print("- files:")
        for url in files {
            print("  - \(url.lastPathComponent)")
        }
    }
    print("- entries (before filter): \(allEntriesCount)")
    print("- entries (after filter): \(filteredCount)")
}

private func printEntries(_ entries: [Entry], limit: Int) {
    let shown = entries.prefix(limit)
    if shown.isEmpty {
        print("No entries found.")
        return
    }
    print("=== entries (showing \(shown.count) / \(entries.count)) ===")
    for (index, entry) in shown.enumerated() {
        print(
            "[\(index + 1)] ruby=\(entry.ruby)\tword=\(entry.word)\tvalue=\(entry.value)\tCID=(\(entry.lcid),\(entry.rcid))\tMID=\(entry.mid)\tfile=\(entry.shardFile)"
        )
    }
}

func run() throws {
    let options = try parseOptions(arguments: Array(CommandLine.arguments.dropFirst()))
    let directoryURL = URL(fileURLWithPath: options.memoryDir, isDirectory: true)
    let files = try findTargetFiles(directoryURL: directoryURL, includeTempFiles: options.includeTempFiles)

    var allEntries: [Entry] = []
    for file in files {
        allEntries.append(contentsOf: try parseLoudstxt3File(url: file))
    }

    let filteredEntries = try filterEntries(
        allEntries,
        rubyPattern: options.rubyRegexPattern,
        wordPattern: options.wordRegexPattern
    )
    let sortedEntries = sortEntries(filteredEntries, sortKey: options.sortKey)
    let summary = Summary(
        memoryDirectory: directoryURL.path,
        files: files.map(\.lastPathComponent),
        totalCount: allEntries.count,
        filteredCount: sortedEntries.count
    )

    if options.json {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let payload = JSONPayload(summary: summary, entries: Array(sortedEntries.prefix(options.limit)))
        let data = try encoder.encode(payload)
        if let text = String(data: data, encoding: .utf8) {
            print(text)
        }
    } else {
        printSummary(
            directoryPath: summary.memoryDirectory,
            files: files,
            allEntriesCount: summary.totalCount,
            filteredCount: summary.filteredCount
        )
        printEntries(sortedEntries, limit: options.limit)
    }
}

do {
    try run()
} catch {
    fputs("Error: \(error)\n", stderr)
    fputs("\n\(usageText())\n", stderr)
    Foundation.exit(1)
}
