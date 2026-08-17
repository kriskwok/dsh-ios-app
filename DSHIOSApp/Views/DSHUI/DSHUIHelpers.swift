import Foundation

func flattenedDescription(_ value: JSONValue?) -> String {
    guard let value else { return "" }
    switch value {
    case .string(let string): return string
    case .number(let number): return number.formatted()
    case .bool(let bool): return bool ? "true" : "false"
    case .null: return "null"
    case .array(let values): return values.map { flattenedDescription($0) }.joined(separator: ", ")
    case .object: return jsonString(value)
    }
}

func jsonString(_ value: JSONValue?) -> String {
    guard let value, let data = try? JSONEncoder.pretty.encode(value) else { return "" }
    return String(data: data, encoding: .utf8) ?? ""
}

extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
