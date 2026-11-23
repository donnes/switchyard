import Foundation
import Security

/// Code-signing identity read from an app bundle on disk.
public struct BundleSigningInfo: Equatable, Sendable {
    public let bundleIdentifier: String
    public let teamIdentifier: String?
    public let isValid: Bool
    public let satisfiesDeveloperID: Bool

    public init(
        bundleIdentifier: String,
        teamIdentifier: String?,
        isValid: Bool,
        satisfiesDeveloperID: Bool
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.teamIdentifier = teamIdentifier
        self.isValid = isValid
        self.satisfiesDeveloperID = satisfiesDeveloperID
    }
}

/// Pure policy decisions for comparing a downloaded app's signature against the running app.
public enum CodeSignaturePolicy {
    /// Builds Apple's Developer ID Application designated requirement pinned to a bundle ID and Team ID.
    public static func developerIDRequirementString(bundleIdentifier: String, teamIdentifier: String) throws -> String {
        guard !bundleIdentifier.isEmpty,
              bundleIdentifier.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_") })
        else {
            throw UpdateError.signatureInvalid("invalid bundle identifier")
        }
        guard !teamIdentifier.isEmpty,
              teamIdentifier.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) })
        else {
            throw UpdateError.unsignedRunningApp
        }
        return #"identifier "\#(bundleIdentifier)" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */ and certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */ and certificate leaf[subject.OU] = "\#(teamIdentifier)""#
    }

    public static func validate(candidate: BundleSigningInfo, against current: BundleSigningInfo) throws {
        guard let expectedTeam = current.teamIdentifier, !expectedTeam.isEmpty else {
            throw UpdateError.unsignedRunningApp
        }
        guard candidate.bundleIdentifier == current.bundleIdentifier else {
            throw UpdateError.bundleIdentifierMismatch(expected: current.bundleIdentifier, actual: candidate.bundleIdentifier)
        }
        guard candidate.isValid else {
            throw UpdateError.signatureInvalid("code signature check failed")
        }
        guard candidate.teamIdentifier == expectedTeam else {
            throw UpdateError.teamIdentifierMismatch(expected: expectedTeam, actual: candidate.teamIdentifier)
        }
        guard candidate.satisfiesDeveloperID else {
            throw UpdateError.signatureInvalid("not signed with a trusted Developer ID certificate")
        }
    }
}

/// Verifies macOS app bundle signatures and Team IDs via Security.framework without shelling out.
public enum CodeSignatureVerifier {
    private static let strictFlags = SecCSFlags(rawValue:
        kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate
    )

    public static func signingInfo(for bundleURL: URL) throws -> BundleSigningInfo {
        let code = try staticCode(at: bundleURL)
        let info = try signingDictionary(for: code)

        guard let bundleID = info[kSecCodeInfoIdentifier as String] as? String, !bundleID.isEmpty else {
            throw UpdateError.signatureInvalid("missing signing identifier")
        }
        let teamID = (info[kSecCodeInfoTeamIdentifier as String] as? String).flatMap { $0.isEmpty ? nil : $0 }

        var checkError: Unmanaged<CFError>?
        let validStatus = SecStaticCodeCheckValidityWithErrors(code, strictFlags, nil, &checkError)
        checkError?.release()
        let isValid = validStatus == errSecSuccess

        var satisfiesDeveloperID = false
        if isValid, let teamID,
           let reqString = try? CodeSignaturePolicy.developerIDRequirementString(bundleIdentifier: bundleID, teamIdentifier: teamID) {
            var requirement: SecRequirement?
            if SecRequirementCreateWithString(reqString as CFString, [], &requirement) == errSecSuccess,
               let requirement {
                var reqError: Unmanaged<CFError>?
                let reqStatus = SecStaticCodeCheckValidityWithErrors(code, strictFlags, requirement, &reqError)
                reqError?.release()
                satisfiesDeveloperID = reqStatus == errSecSuccess
            }
        }

        return BundleSigningInfo(
            bundleIdentifier: bundleID,
            teamIdentifier: teamID,
            isValid: isValid,
            satisfiesDeveloperID: satisfiesDeveloperID
        )
    }

    /// Checks that the running app has a Team ID, then verifies the downloaded app's strict signature,
    /// Developer ID chain, bundle identifier, and Team ID against it.
    public static func verifyUpdate(at candidateURL: URL, against currentURL: URL) throws {
        let current = try signingInfo(for: currentURL)
        guard let expectedTeam = current.teamIdentifier, !expectedTeam.isEmpty else {
            throw UpdateError.unsignedRunningApp
        }

        let candidateCode = try staticCode(at: candidateURL)
        let reqString = try CodeSignaturePolicy.developerIDRequirementString(
            bundleIdentifier: current.bundleIdentifier,
            teamIdentifier: expectedTeam
        )
        var requirement: SecRequirement?
        let reqCreateStatus = SecRequirementCreateWithString(reqString as CFString, [], &requirement)
        guard reqCreateStatus == errSecSuccess, let requirement else {
            throw UpdateError.signatureInvalid("couldn’t build signature requirement (\(reqCreateStatus))")
        }

        let candidate = try signingInfo(for: candidateURL)
        try CodeSignaturePolicy.validate(candidate: candidate, against: current)

        var cfError: Unmanaged<CFError>?
        let status = SecStaticCodeCheckValidityWithErrors(candidateCode, strictFlags, requirement, &cfError)
        if status != errSecSuccess {
            let message = cfError?.takeRetainedValue().localizedDescription
                ?? (SecCopyErrorMessageString(status, nil) as String?)
                ?? "status \(status)"
            throw UpdateError.signatureInvalid(message)
        }
    }

    private static func staticCode(at bundleURL: URL) throws -> SecStaticCode {
        var code: SecStaticCode?
        let status = SecStaticCodeCreateWithPath(bundleURL as CFURL, [], &code)
        guard status == errSecSuccess, let code else {
            let message = (SecCopyErrorMessageString(status, nil) as String?) ?? "status \(status)"
            throw UpdateError.signatureInvalid(message)
        }
        return code
    }

    private static func signingDictionary(for code: SecStaticCode) throws -> [String: Any] {
        var cfInfo: CFDictionary?
        let status = SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &cfInfo)
        guard status == errSecSuccess, let dict = cfInfo as? [String: Any] else {
            let message = (SecCopyErrorMessageString(status, nil) as String?) ?? "status \(status)"
            throw UpdateError.signatureInvalid(message)
        }
        return dict
    }
}
