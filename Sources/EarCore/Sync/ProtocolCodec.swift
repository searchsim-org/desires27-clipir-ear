import Foundation

/// Protocol v1 control messages and binary frames (HANDOVER §7, docs/PROTOCOL.md, docs/protocol/*.schema.json).
public enum ProtocolCodec {
    public enum Kind: UInt8, Sendable {
        case pcmIn = 0x01
        case ttsPCM = 0x02
        case opus = 0x03
    }
    public static let closeBadToken = 4401

    public static func encode(_ type: String, _ fields: [String: Any] = [:]) -> String {
        var o = fields
        o["t"] = type
        let data = try! JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    public static func decode(_ text: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }

    public static func binary(_ kind: Kind, seq: UInt32, payload: Data) -> Data {
        var header = Data([kind.rawValue])
        var s = seq.littleEndian
        header.append(Data(bytes: &s, count: 4))
        return header + payload
    }

    public static func parseBinary(_ d: Data) -> (kind: UInt8, seq: UInt32, payload: Data)? {
        guard d.count >= 5 else { return nil }
        let bytes = [UInt8](d.prefix(5))
        let seq = UInt32(bytes[1]) | UInt32(bytes[2]) << 8 | UInt32(bytes[3]) << 16 | UInt32(bytes[4]) << 24
        return (bytes[0], seq, d.dropFirst(5))
    }

    public static func pcm16(_ samples: [Int16]) -> Data { samples.withUnsafeBytes { Data($0) } }

    public static func samples(_ d: Data) -> [Int16] {
        d.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
    }

    public static func segmentJSON(_ s: Segment) -> [String: Any] {
        var o: [String: Any] = ["t0": s.t0, "t1": s.t1, "text": s.text, "speaker": s.speaker]
        if let id = s.id { o["id"] = id }
        return o
    }
}
