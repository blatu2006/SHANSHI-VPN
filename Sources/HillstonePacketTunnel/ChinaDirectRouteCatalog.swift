import Foundation
import HillstoneProtocol

enum ChinaDirectRouteCatalog {
    static let resourceName = "china_ipv4_cidrs"
    static let resourceExtension = "txt"

    static func load(bundle: Bundle = catalogBundle) throws -> [IPv4Route] {
        guard let url = bundle.url(forResource: resourceName, withExtension: resourceExtension) else {
            throw CatalogError.resourceMissing
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        return try parse(text)
    }

    static func parse(_ text: String) throws -> [IPv4Route] {
        try text.split(whereSeparator: \Character.isNewline).compactMap { line in
            let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, !value.hasPrefix("#") else { return nil }
            return try IPv4Route.parseCIDR(value)
        }
    }

    private static var catalogBundle: Bundle {
        #if SWIFT_PACKAGE
        Bundle.module
        #else
        Bundle(for: PacketTunnelProvider.self)
        #endif
    }

    enum CatalogError: Error, LocalizedError {
        case resourceMissing

        var errorDescription: String? {
            "App 安装包中缺少 china_ipv4_cidrs.txt"
        }
    }
}
