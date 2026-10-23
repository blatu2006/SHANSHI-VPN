import Foundation

public enum SessionStage: Int, CaseIterable, Codable, Sendable {
    case idle
    case discovering
    case knocking
    case securingControlChannel
    case authenticating
    case checkingDevice
    case receivingPolicy
    case exchangingKeys
    case startingDataChannel
    case applyingNetwork
    case connected
    case reconnecting
    case failed

    public var title: String {
        switch self {
        case .idle: "未连接"
        case .discovering: "检查网关"
        case .knocking: "安全敲门"
        case .securingControlChannel: "建立加密通道"
        case .authenticating: "验证身份"
        case .checkingDevice: "检查设备"
        case .receivingPolicy: "接收网络策略"
        case .exchangingKeys: "协商隧道密钥"
        case .startingDataChannel: "启动数据通道"
        case .applyingNetwork: "应用路由与 DNS"
        case .connected: "已安全连接"
        case .reconnecting: "正在重新连接"
        case .failed: "连接失败"
        }
    }
}

public struct SessionStateMachine: Sendable {
    public private(set) var stage: SessionStage = .idle
    public private(set) var receivedMessageTypes: [UInt16] = []

    public init() {}

    public mutating func begin() {
        stage = .discovering
        receivedMessageTypes.removeAll(keepingCapacity: true)
    }

    public mutating func didSendSPA() { stage = .securingControlChannel }
    public mutating func didSecureControlChannel() { stage = .authenticating }
    public mutating func didStartDataChannel() { stage = .startingDataChannel }
    public mutating func didReceiveFirstHeartbeat() { stage = .applyingNetwork }
    public mutating func didApplyNetworkSettings() { stage = .connected }
    public mutating func disconnect() { stage = .idle }
    public mutating func fail() { stage = .failed }

    public mutating func consume(_ message: ControlMessage) {
        receivedMessageTypes.append(message.type)
        switch message.knownType {
        case .auth:
            stage = .checkingDevice
        case .clientInfo:
            stage = .receivingPolicy
        case .setIP, .setRoute:
            stage = .receivingPolicy
        case .keyDone:
            stage = .exchangingKeys
        case .newKey:
            stage = .startingDataChannel
        case .some(.none), .clientLogout, .serverDisconnect, .keepAlive, .rekey, .hostCheck, .hostCheckUpdate, nil:
            break
        }
    }
}
