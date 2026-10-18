import Foundation

/// Manifest / 表单里的标量值。支持 string / number / bool。
public enum FieldValue: Codable, Equatable, Hashable {
    case string(String)
    case number(Double)
    case bool(Bool)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .string("")
            return
        }
        if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
            return
        }
        if let number = try? container.decode(Double.self) {
            self = .number(number)
            return
        }
        if let string = try? container.decode(String.self) {
            self = .string(string)
            return
        }
        throw DecodingError.typeMismatch(
            FieldValue.self,
            .init(codingPath: decoder.codingPath, debugDescription: "不支持的字段值")
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        }
    }

    public var stringValue: String {
        switch self {
        case .string(let value): return value
        case .number(let value):
            if value.rounded() == value { return String(Int(value)) }
            return String(value)
        case .bool(let value): return value ? "true" : "false"
        }
    }

    public var doubleValue: Double {
        switch self {
        case .number(let value): return value
        case .string(let value): return Double(value) ?? 0
        case .bool(let value): return value ? 1 : 0
        }
    }

    public var boolValue: Bool {
        switch self {
        case .bool(let value): return value
        case .number(let value): return value != 0
        case .string(let value): return ["1", "true", "yes", "on"].contains(value.lowercased())
        }
    }

    public var rawObject: Any {
        switch self {
        case .string(let value): return value
        case .number(let value): return value
        case .bool(let value): return value
        }
    }

    public var isEmpty: Bool {
        switch self {
        case .string(let value): return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .number: return false
        case .bool: return false
        }
    }

    public static func from(_ any: Any?) -> FieldValue {
        switch any {
        case let value as String: return .string(value)
        case let value as Bool: return .bool(value)
        case let value as Double: return .number(value)
        case let value as Int: return .number(Double(value))
        case let value as NSNumber:
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                return .bool(value.boolValue)
            }
            return .number(value.doubleValue)
        default: return .string("")
        }
    }
}
