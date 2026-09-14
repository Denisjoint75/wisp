import Foundation

/// Length-prefixed framing shared by the daemon socket: `[u32 little-endian length][payload]`.
public enum Framing {
    public static let maxFrame = 8 * 1024 * 1024

    public static func encode(_ payload: Data) -> Data {
        var out = Data(capacity: payload.count + 4)
        var len = UInt32(payload.count).littleEndian
        withUnsafeBytes(of: &len) { out.append(contentsOf: $0) }
        out.append(payload)
        return out
    }

    public struct Decoder {
        private var buffer = Data()
        public init() {}

        /// Feeds bytes and returns every complete frame.
        public mutating func feed(_ data: Data) throws -> [Data] {
            buffer.append(data)
            var frames: [Data] = []
            while buffer.count >= 4 {
                let len = buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self) }.littleEndian
                if len > maxFrame { throw WispError(.protocolError, "frame too large: \(len)") }
                let total = 4 + Int(len)
                if buffer.count < total { break }
                frames.append(buffer.subdata(in: 4..<total))
                buffer.removeSubrange(0..<total)
            }
            return frames
        }
    }
}
