#if canImport(Network) && canImport(Security)
import CryptoKit
import Dispatch
import Foundation
import Network
import Security
import HelixCore

public enum NetworkTransport {}

extension NetworkTransport {
public final class ByteTransport: DevProtocol.ByteTransport, @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue

    public init(connection: NWConnection, queueLabel: String = "dev.helix.transport") {
        self.connection = connection
        queue = DispatchQueue(label: queueLabel)
    }

    public static func pinnedTLSClient(
        host: NWEndpoint.Host,
        port: NWEndpoint.Port,
        expectedSPKIHash: Core.Digest
    ) -> NetworkTransport.ByteTransport {
        pinnedTLSClient(
            endpoint: .hostPort(host: host, port: port),
            expectedSPKIHash: expectedSPKIHash
        )
    }

    public static func pinnedTLSClient(
        endpoint: NWEndpoint,
        expectedSPKIHash: Core.Digest
    ) -> NetworkTransport.ByteTransport {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(
            tls.securityProtocolOptions,
            .TLSv13
        )
        let verificationQueue = DispatchQueue(label: "dev.helix.tls-verify")
        sec_protocol_options_set_verify_block(
            tls.securityProtocolOptions,
            { _, trust, completion in
                let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
                let pin = try? NetworkTransport.SPKIPin.hash(trust: secTrust)
                // The certificate is self-signed. The generated Shell contract
                // supplies the stable Host Identity SPKI pin as its trust root.
                completion(pin?.constantTimeEquals(expectedSPKIHash) == true)
            },
            verificationQueue
        )
        let parameters = NWParameters(tls: tls)
        parameters.includePeerToPeer = true
        return .init(connection: NWConnection(to: endpoint, using: parameters))
    }

    public static func tlsServerParameters(identity: SecIdentity) throws -> NWParameters {
        let tls = NWProtocolTLS.Options()
        guard let protocolIdentity = sec_identity_create(identity) else {
            throw NetworkTransport.Error.invalidIdentity
        }
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, protocolIdentity)
        sec_protocol_options_set_min_tls_protocol_version(
            tls.securityProtocolOptions,
            .TLSv13
        )
        let parameters = NWParameters(tls: tls)
        parameters.includePeerToPeer = true
        return parameters
    }

    public func start() async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Swift.Error>) in
            let state = NetworkTransport.ContinuationState()
            connection.stateUpdateHandler = { newState in
                switch newState {
                case .ready:
                    state.resumeOnce { continuation.resume() }
                case let .failed(error):
                    state.resumeOnce {
                        continuation.resume(throwing: NetworkTransport.Error.connectionFailed(error.debugDescription))
                    }
                case .cancelled:
                    state.resumeOnce {
                        continuation.resume(throwing: NetworkTransport.Error.cancelled)
                    }
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    public func send(_ bytes: Data) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Swift.Error>) in
            connection.send(content: bytes, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(
                        throwing: NetworkTransport.Error.connectionFailed(error.debugDescription)
                    )
                } else {
                    continuation.resume()
                }
            })
        }
    }

    public func receiveExactly(_ byteCount: Int) async throws -> Data {
        guard byteCount >= 0 else { throw NetworkTransport.Error.invalidLength }
        var result = Data()
        result.reserveCapacity(byteCount)
        while result.count < byteCount {
            let remaining = byteCount - result.count
            let part = try await receive(maximumLength: remaining)
            guard !part.isEmpty else { throw NetworkTransport.Error.endOfStream }
            result.append(part)
        }
        return result
    }

    public func close() async {
        connection.cancel()
    }

    public func tlsExporterHash() throws -> Core.Digest {
        guard let metadata = connection.metadata(
            definition: NWProtocolTLS.definition
        ) as? NWProtocolTLS.Metadata else {
            throw NetworkTransport.Error.missingTLSMetadata
        }
        let label = Array("EXPORTER-Helix-Dev-v1".utf8)
        let secret: dispatch_data_t? = label.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return nil }
            return sec_protocol_metadata_create_secret(
                metadata.securityProtocolMetadata,
                buffer.count,
                baseAddress,
                Core.Digest.byteCount
            )
        }
        guard let secret else { throw NetworkTransport.Error.missingTLSMetadata }
        let data = secret as DispatchData
        return try Core.Digest(bytes: Data(data))
    }

    private func receive(maximumLength: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(
                minimumIncompleteLength: 1,
                maximumLength: maximumLength
            ) { data, _, isComplete, error in
                if let error {
                    continuation.resume(
                        throwing: NetworkTransport.Error.connectionFailed(error.debugDescription)
                    )
                } else if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if isComplete {
                    continuation.resume(throwing: NetworkTransport.Error.endOfStream)
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }
}

public final class Listener: @unchecked Sendable {
    public typealias ConnectionHandler = @Sendable (NetworkTransport.ByteTransport) async -> Void

    private let listener: NWListener
    private let queue = DispatchQueue(label: "dev.helix.listener")
    private let handler: ConnectionHandler

    public init(
        parameters: NWParameters,
        port: NWEndpoint.Port? = nil,
        service: NWListener.Service? = nil,
        handler: @escaping ConnectionHandler
    ) throws {
        if let port {
            listener = try NWListener(using: parameters, on: port)
        } else {
            listener = try NWListener(using: parameters)
        }
        listener.service = service
        self.handler = handler
    }

    public var port: NWEndpoint.Port? { listener.port }

    public func start() async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Swift.Error>) in
            let state = NetworkTransport.ContinuationState()
            listener.stateUpdateHandler = { newState in
                switch newState {
                case .ready:
                    state.resumeOnce { continuation.resume() }
                case let .failed(error):
                    state.resumeOnce {
                        continuation.resume(throwing: NetworkTransport.Error.connectionFailed(error.debugDescription))
                    }
                case .cancelled:
                    state.resumeOnce {
                        continuation.resume(throwing: NetworkTransport.Error.cancelled)
                    }
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [handler] connection in
                let transport = NetworkTransport.ByteTransport(connection: connection)
                Task {
                    do {
                        try await transport.start()
                        await handler(transport)
                    } catch {
                        await transport.close()
                    }
                }
            }
            listener.start(queue: queue)
        }
    }

    public func cancel() {
        listener.cancel()
    }
}

public struct DiscoveredService: Hashable, Sendable {
    public var endpoint: NWEndpoint
    public var interfaces: Set<NWInterface.InterfaceType>
    public var name: String?
    public var type: String?
    public var domain: String?

    public init(
        endpoint: NWEndpoint,
        interfaces: Set<NWInterface.InterfaceType>,
        name: String? = nil,
        type: String? = nil,
        domain: String? = nil
    ) {
        self.endpoint = endpoint
        self.interfaces = interfaces
        self.name = name
        self.type = type
        self.domain = domain
    }
}

public final class Browser: @unchecked Sendable {
    public typealias UpdateHandler = @Sendable ([NetworkTransport.DiscoveredService]) async -> Void

    private let browser: NWBrowser
    private let queue = DispatchQueue(label: "dev.helix.browser")
    private let updateHandler: UpdateHandler

    public init(
        serviceType: String = "_helix-live._tcp",
        domain: String? = nil,
        updateHandler: @escaping UpdateHandler
    ) {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        browser = NWBrowser(
            for: .bonjour(type: serviceType, domain: domain),
            using: parameters
        )
        self.updateHandler = updateHandler
    }

    public func start() async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Swift.Error>) in
            let state = NetworkTransport.ContinuationState()
            browser.stateUpdateHandler = { newState in
                switch newState {
                case .ready:
                    state.resumeOnce { continuation.resume() }
                case let .failed(error):
                    state.resumeOnce {
                        continuation.resume(
                            throwing: NetworkTransport.Error.connectionFailed(
                                error.debugDescription
                            )
                        )
                    }
                case .cancelled:
                    state.resumeOnce {
                        continuation.resume(throwing: NetworkTransport.Error.cancelled)
                    }
                default:
                    break
                }
            }
            browser.browseResultsChangedHandler = { [updateHandler] results, _ in
                let services = results.map {
                    let identity: (String?, String?, String?)
                    if case let .service(name, type, domain, _) = $0.endpoint {
                        identity = (name, type, domain)
                    } else {
                        identity = (nil, nil, nil)
                    }
                    return NetworkTransport.DiscoveredService(
                        endpoint: $0.endpoint,
                        interfaces: Set($0.interfaces.map(\.type)),
                        name: identity.0,
                        type: identity.1,
                        domain: identity.2
                    )
                }.sorted { String(describing: $0.endpoint) < String(describing: $1.endpoint) }
                Task { await updateHandler(services) }
            }
            browser.start(queue: queue)
        }
    }

    public func cancel() {
        browser.cancel()
    }
}

public enum SPKIPin {
    public static func hash(trust: SecTrust) throws -> Core.Digest {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let certificate = chain.first
        else {
            throw NetworkTransport.Error.unsupportedPublicKey
        }
        return try hash(certificate: certificate)
    }

    public static func hash(certificate: SecCertificate) throws -> Core.Digest {
        guard let key = SecCertificateCopyKey(certificate),
              let attributes = SecKeyCopyAttributes(key) as? [String: Any],
              let keyType = attributes[kSecAttrKeyType as String] as? String,
              let bits = attributes[kSecAttrKeySizeInBits as String] as? Int
        else {
            throw NetworkTransport.Error.unsupportedPublicKey
        }
        var error: Unmanaged<CFError>?
        guard let representation = SecKeyCopyExternalRepresentation(key, &error) as Data? else {
            throw NetworkTransport.Error.unsupportedPublicKey
        }
        let algorithm: Data
        if keyType == kSecAttrKeyTypeECSECPrimeRandom as String, bits == 256 {
            algorithm = Data([
                0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01,
                0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07,
            ])
        } else if keyType == kSecAttrKeyTypeRSA as String {
            algorithm = Data([
                0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7,
                0x0d, 0x01, 0x01, 0x01, 0x05, 0x00,
            ])
        } else {
            throw NetworkTransport.Error.unsupportedPublicKey
        }
        var bitString = Data([0])
        bitString.append(representation)
        let spki = der(tag: 0x30, contents: algorithm + der(tag: 0x03, contents: bitString))
        return .sha256(spki)
    }

    private static func der(tag: UInt8, contents: Data) -> Data {
        var data = Data([tag])
        if contents.count < 128 {
            data.append(UInt8(contents.count))
        } else {
            var value = contents.count
            var bytes: [UInt8] = []
            while value > 0 {
                bytes.append(UInt8(truncatingIfNeeded: value))
                value >>= 8
            }
            data.append(0x80 | UInt8(bytes.count))
            data.append(contentsOf: bytes.reversed())
        }
        data.append(contents)
        return data
    }
}

private final class ContinuationState: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false

    func resumeOnce(_ body: () -> Void) {
        lock.lock()
        guard !resumed else {
            lock.unlock()
            return
        }
        resumed = true
        lock.unlock()
        body()
    }
}

public enum Error: Swift.Error, Equatable, Sendable, CustomStringConvertible {
    case invalidIdentity
    case unsupportedPublicKey
    case connectionFailed(String)
    case cancelled
    case endOfStream
    case invalidLength
    case missingTLSMetadata
    case identityGenerationFailed(String)
    case identityStorageFailed(String)
    case insecureIdentityStorage(String)

    public var description: String {
        switch self {
        case .invalidIdentity: "TLS server identity is invalid"
        case .unsupportedPublicKey: "TLS certificate must use RSA or P-256 for SPKI pinning"
        case let .connectionFailed(reason): "Network.framework connection failed: \(reason)"
        case .cancelled: "Network.framework connection was cancelled"
        case .endOfStream: "Network.framework connection reached end of stream"
        case .invalidLength: "transport requested a negative byte count"
        case .missingTLSMetadata: "TLS exporter metadata is unavailable"
        case let .identityGenerationFailed(reason):
            "cannot create the Helix TLS identity: \(reason)"
        case let .identityStorageFailed(reason):
            "cannot access the Helix Host Identity: \(reason)"
        case let .insecureIdentityStorage(reason):
            "Helix Host Identity storage is insecure: \(reason)"
        }
    }
}
}
#endif
