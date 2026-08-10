import Foundation
import HelixPatch

extension ReleasePipeline {
/// Local signing exists for tests and isolated internal workflows. Production
/// callers should inject a service client whose key operation stays in an HSM.
public struct LocalSigningService: PatchPackage.SignatureProviding, Sendable {
    public var certificate: PatchPackage.SigningCertificate
    public var signingKey: ReleasePipeline.SigningKeyDocument

    public init(
        certificate: PatchPackage.SigningCertificate,
        signingKey: ReleasePipeline.SigningKeyDocument
    ) {
        self.certificate = certificate
        self.signingKey = signingKey
    }

    public func sign(
        _ request: PatchPackage.SigningRequest
    ) throws -> PatchPackage.SignatureEnvelope {
        let signer = try PatchPackage.Signer(
            certificate: certificate,
            privateKey: signingKey.privateKey()
        )
        return try signer.sign(request)
    }
}
}
