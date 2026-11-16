import Darwin
import Foundation

public enum SamplingError: Error, Sendable, Equatable {
    case hostStatistics(kern_return_t)
    case sysctl(name: String, errno: Int32)
}

/// Reads a fixed-size value with `sysctlbyname`.
func sysctlValue<T>(_ name: String, as type: T.Type = T.self) throws -> T {
    let pointer = UnsafeMutablePointer<T>.allocate(capacity: 1)
    defer { pointer.deallocate() }
    var size = MemoryLayout<T>.size
    guard sysctlbyname(name, pointer, &size, nil, 0) == 0, size == MemoryLayout<T>.size else {
        throw SamplingError.sysctl(name: name, errno: errno)
    }
    return pointer.pointee
}

/// When the machine booted (`kern.boottime`), or nil if it cannot be read.
public func bootTime() -> Date? {
    guard let tv = try? sysctlValue("kern.boottime", as: timeval.self), tv.tv_sec > 0 else {
        return nil
    }
    return Date(timeIntervalSince1970: TimeInterval(tv.tv_sec) + TimeInterval(tv.tv_usec) / 1_000_000)
}

/// Converts a fixed-size C char array (imported as a tuple) to a String.
func string<T>(fromCCharTuple tuple: T) -> String {
    withUnsafeBytes(of: tuple) { raw in
        let bytes = raw.prefix { $0 != 0 }
        return String(decoding: bytes, as: UTF8.self)
    }
}
