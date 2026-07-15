//
//  Keychain.swift
//  AltStore
//
//  Created by Riley Testut on 6/4/19.
//  Copyright © 2019 Riley Testut. All rights reserved.
//

import Foundation
import KeychainAccess

import AltSign

@propertyWrapper
public struct KeychainItem<Value>
{
    public let key: String
    
    public var wrappedValue: Value? {
        get {
            switch Value.self
            {
            case is Data.Type: return try? Keychain.shared.keychain.getData(self.key) as? Value
            case is String.Type: return try? Keychain.shared.keychain.getString(self.key) as? Value
            default: return nil
            }
        }
        set {
            switch Value.self
            {
            case is Data.Type: Keychain.shared.keychain[data: self.key] = newValue as? Data
            case is String.Type: Keychain.shared.keychain[self.key] = newValue as? String
            default: break
            }
        }
    }
    
    public init(key: String)
    {
        self.key = key
    }
}

/// The set of per-account secrets required to authenticate an Apple account and re-sign its apps.
///
/// Anisette machine state (`identifier` / `adiPb`) is intentionally NOT part of this — it is
/// device-scoped and shared across all accounts, so it stays in the global `Keychain` slots.
public struct AccountCredentials
{
    public var emailAddress: String?
    public var password: String?
    public var adsid: String?               // ALTAppleAPISession.dsid
    public var xcodeToken: String?          // ALTAppleAPISession.authToken
    public var signingCertificate: Data?    // PKCS#12
    public var signingCertificatePassword: String?

    public init(emailAddress: String? = nil,
                password: String? = nil,
                adsid: String? = nil,
                xcodeToken: String? = nil,
                signingCertificate: Data? = nil,
                signingCertificatePassword: String? = nil)
    {
        self.emailAddress = emailAddress
        self.password = password
        self.adsid = adsid
        self.xcodeToken = xcodeToken
        self.signingCertificate = signingCertificate
        self.signingCertificatePassword = signingCertificatePassword
    }

    /// Whether these credentials are sufficient to (attempt to) authenticate the account
    /// without prompting the user for a password again.
    public var canAuthenticate: Bool {
        let hasToken = (self.adsid?.isEmpty == false) && (self.xcodeToken?.isEmpty == false)
        let hasPassword = (self.emailAddress?.isEmpty == false) && (self.password?.isEmpty == false)
        return hasToken || hasPassword
    }
}

public class Keychain
{
    public static let shared = Keychain()

    public let keychain = KeychainAccess.Keychain(service: Bundle.Info.appbundleIdentifier).accessibility(.afterFirstUnlock).synchronizable(true)    
    @KeychainItem(key: "appleIDEmailAddress")
    public var appleIDEmailAddress: String?
    
    @KeychainItem(key: "appleIDPassword")
    public var appleIDPassword: String?
    
    @KeychainItem(key: "appleIDAdsid")
    public var appleIDAdsid: String?
    
    @KeychainItem(key: "appleIDXcodeToken")
    public var appleIDXcodeToken: String?
    
    @KeychainItem(key: "signingCertificate")
    public var signingCertificate: Data?
    
    @KeychainItem(key: "signingCertificatePassword")
    public var signingCertificatePassword: String?
    
    // TODO: mahee96: remove legacy keys in later versions coz by now our migrations should be effectively moved all
    // Legacy
    @KeychainItem(key: "signingCertificatePrivateKey")
    public var signingCertificatePrivateKey: Data?
    
    // TODO: mahee96: remove legacy keys in later versions coz by now our migrations should be effectively moved all
    // Legacy
    @KeychainItem(key: "signingCertificateSerialNumber")
    public var signingCertificateSerialNumber: String?
    
    @KeychainItem(key: "identifier")
    public var identifier: String?
    
    @KeychainItem(key: "adiPb")
    public var adiPb: String?
    
    // for some reason authenticated cert/session/team is completely not cached, which result in logging in for every request
    // we save it here so when user logs out we can clear cached account/session/team
    //
    // NOTE: These three properties mirror the *default* (active) account's cached state and are
    // kept for backwards compatibility. Multi-account callers should use the per-account cache
    // accessors below (`cachedCertificate(forAccount:)` etc.), which isolate each account's
    // in-memory session/certificate/team.
    public var certificate: ALTCertificate? = nil
    public var session: ALTAppleAPISession? = nil
    public var team: ALTTeam? = nil

    // MARK: Per-account in-memory cache
    // Isolated, non-persisted cache of the authenticated session/certificate/team for each
    // account, keyed by `Account.identifier`. Guarded by `accountCacheLock` because multiple
    // accounts can be authenticated/refreshed concurrently.
    private let accountCacheLock = NSLock()
    private var accountSessions: [String: ALTAppleAPISession] = [:]
    private var accountCertificates: [String: ALTCertificate] = [:]
    private var accountTeams: [String: ALTTeam] = [:]

    private init()
    {
        self.migrateLegacyKeychainItems()
    }
    
    private func migrateLegacyKeychainItems()
    {
        let signingCertificateKey = "signingCertificate"
        let privateKeyKey = "signingCertificatePrivateKey"
        let serialNumberKey = "signingCertificateSerialNumber"
        
        // 1. Check if signingCertificate contains data and is NOT a PKCS#12 archive
        guard let certData = try? self.keychain.getData(signingCertificateKey), !certData.isPKCS12 else { return }
        
        // 2. Check if we have the private key
        guard let privateKey = try? self.keychain.getData(privateKeyKey) else { return }
        
        // 3. Load the raw certificate
        guard let cert = ALTCertificate(data: certData) else { return }
        cert.privateKey = privateKey
        
        // 4. Create PKCS12 data structure
        if let p12Data = cert.p12Data()
        {
            // 5. Store the new PKCS12 format in signingCertificate slot
            try? self.keychain.set(p12Data, key: signingCertificateKey)
            try? self.keychain.set("", key: "signingCertificatePassword")
            
            // 6. Clear legacy keys
            try? self.keychain.remove(privateKeyKey)
            try? self.keychain.remove(serialNumberKey)
            
            debugLog("[Keychain] Successfully migrated legacy certificate and private key to PKCS12 format and cleared legacy keys.")
        }
    }
    
    public func reset(keepCertificate: Bool = false)
    {
        self.appleIDEmailAddress = nil
        self.appleIDPassword = nil
        self.appleIDAdsid = nil
        self.appleIDXcodeToken = nil
        
        if !keepCertificate {
            // Legacy
            self.signingCertificatePrivateKey = nil
            self.signingCertificateSerialNumber = nil

            self.signingCertificate = nil
            self.signingCertificatePassword = nil
        }
        
        self.certificate = nil
        self.session = nil
        self.team = nil
    }
}

// MARK: - Per-account credential & session storage
//
// Multi-account support stores each account's secrets under a namespaced key
// ("account.<identifier>.<field>") so that any number of Apple accounts can remain
// authenticated simultaneously with fully isolated sessions, certificates and tokens.
// The same underlying (synchronizable, after-first-unlock) keychain is reused, preserving
// SideStore's existing security posture.
public extension Keychain
{
    private func accountKey(_ accountID: String, _ field: String) -> String
    {
        return "account.\(accountID).\(field)"
    }

    private func string(_ accountID: String, _ field: String) -> String?
    {
        return try? self.keychain.getString(self.accountKey(accountID, field))
    }

    private func data(_ accountID: String, _ field: String) -> Data?
    {
        return try? self.keychain.getData(self.accountKey(accountID, field))
    }

    private func set(_ value: String?, _ accountID: String, _ field: String)
    {
        let key = self.accountKey(accountID, field)
        if let value = value { try? self.keychain.set(value, key: key) }
        else { try? self.keychain.remove(key) }
    }

    private func set(_ value: Data?, _ accountID: String, _ field: String)
    {
        let key = self.accountKey(accountID, field)
        if let value = value { try? self.keychain.set(value, key: key) }
        else { try? self.keychain.remove(key) }
    }

    /// The stored credentials for the given account (empty fields if none stored).
    func credentials(forAccount accountID: String) -> AccountCredentials
    {
        return AccountCredentials(
            emailAddress: self.string(accountID, "appleIDEmailAddress"),
            password: self.string(accountID, "appleIDPassword"),
            adsid: self.string(accountID, "appleIDAdsid"),
            xcodeToken: self.string(accountID, "appleIDXcodeToken"),
            signingCertificate: self.data(accountID, "signingCertificate"),
            signingCertificatePassword: self.string(accountID, "signingCertificatePassword")
        )
    }

    /// Persist credentials for the given account. Only non-nil fields are written; pass an
    /// explicit nil field to clear just that value.
    func setCredentials(_ credentials: AccountCredentials, forAccount accountID: String)
    {
        self.set(credentials.emailAddress, accountID, "appleIDEmailAddress")
        self.set(credentials.password, accountID, "appleIDPassword")
        self.set(credentials.adsid, accountID, "appleIDAdsid")
        self.set(credentials.xcodeToken, accountID, "appleIDXcodeToken")
        self.set(credentials.signingCertificate, accountID, "signingCertificate")
        self.set(credentials.signingCertificatePassword, accountID, "signingCertificatePassword")
    }

    /// Remove all persisted credentials and drop the in-memory session cache for an account.
    func removeCredentials(forAccount accountID: String)
    {
        for field in ["appleIDEmailAddress", "appleIDPassword", "appleIDAdsid", "appleIDXcodeToken", "signingCertificate", "signingCertificatePassword"]
        {
            try? self.keychain.remove(self.accountKey(accountID, field))
        }
        self.clearCachedSession(forAccount: accountID)
    }

    /// Whether the account has enough stored credentials to attempt a silent re-authentication.
    func hasCredentials(forAccount accountID: String) -> Bool
    {
        return self.credentials(forAccount: accountID).canAuthenticate
    }

    // MARK: In-memory per-account session cache

    func cachedSession(forAccount accountID: String) -> ALTAppleAPISession?
    {
        self.accountCacheLock.lock(); defer { self.accountCacheLock.unlock() }
        return self.accountSessions[accountID]
    }

    func cachedCertificate(forAccount accountID: String) -> ALTCertificate?
    {
        self.accountCacheLock.lock(); defer { self.accountCacheLock.unlock() }
        return self.accountCertificates[accountID]
    }

    func cachedTeam(forAccount accountID: String) -> ALTTeam?
    {
        self.accountCacheLock.lock(); defer { self.accountCacheLock.unlock() }
        return self.accountTeams[accountID]
    }

    func cache(session: ALTAppleAPISession?, certificate: ALTCertificate?, team: ALTTeam?, forAccount accountID: String)
    {
        self.accountCacheLock.lock(); defer { self.accountCacheLock.unlock() }
        self.accountSessions[accountID] = session
        self.accountCertificates[accountID] = certificate
        self.accountTeams[accountID] = team
    }

    func clearCachedSession(forAccount accountID: String)
    {
        self.accountCacheLock.lock(); defer { self.accountCacheLock.unlock() }
        self.accountSessions[accountID] = nil
        self.accountCertificates[accountID] = nil
        self.accountTeams[accountID] = nil
    }
}
