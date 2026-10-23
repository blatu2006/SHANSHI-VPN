import Foundation

public struct SPAConfiguration: Sendable {
    public var server: String
    public var port: UInt16
    public var targetProtocol: ConnectionProfile.DataTransport

    public init(server: String, port: UInt16, targetProtocol: ConnectionProfile.DataTransport) {
        self.server = server
        self.port = port
        self.targetProtocol = targetProtocol
    }
}

public protocol SPAPacketGenerating: Sendable {
    func makePacket(configuration: SPAConfiguration) throws -> Data
}

/// The observed gateway profile has SPA mode disabled. An empty preamble means
/// the extension proceeds directly to its TLS 1.2 control connection.
public struct DirectConnectionPreamble: SPAPacketGenerating {
    public init() {}

    public func makePacket(configuration: SPAConfiguration) throws -> Data {
        Data()
    }
}
