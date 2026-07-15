//
//  Contexts.swift
//  AltStore
//
//  Created by Riley Testut on 6/20/19.
//  Copyright © 2019 Riley Testut. All rights reserved.
//

import UIKit
import Foundation
import CoreData
import Network
import AltStoreCore
import AltSign

class OperationContext
{
    var error: Error?
    
    var presentingViewController: UIViewController?
    
    let operations: NSHashTable<Foundation.Operation>
    
    init(error: Error? = nil, operations: [Foundation.Operation] = [])
    {
        self.error = error
        
        self.operations = NSHashTable<Foundation.Operation>.weakObjects()
        for operation in operations
        {
            self.operations.add(operation)
        }
    }
    
    convenience init(context: OperationContext)
    {
        self.init(error: context.error, operations: context.operations.allObjects)
    }
}

final class AuthenticatedOperationContext: OperationContext
{
    var session: ALTAppleAPISession?

    var team: ALTTeam?
    var certificate: ALTCertificate?

    /// Identifier (`Account.identifier`) of the Apple account this context should authenticate as.
    ///
    /// When set, `AuthenticationOperation` loads/stores credentials and the cached session for
    /// this specific account, allowing multiple accounts to be authenticated simultaneously with
    /// isolated state. When `nil`, it behaves as the legacy single-account flow (global keychain,
    /// interactive sign-in), which is used for the default account and the "add account" UI.
    var accountID: String?

    weak var authenticationOperation: AuthenticationOperation?

    convenience init(context: AuthenticatedOperationContext)
    {
        self.init(error: context.error, operations: context.operations.allObjects)

        self.session = context.session
        self.team = context.team
        self.certificate = context.certificate
        self.accountID = context.accountID
        self.authenticationOperation = context.authenticationOperation
    }
}

@dynamicMemberLookup
class AppOperationContext
{
    let bundleIdentifier: String
    let authenticatedContext: AuthenticatedOperationContext
    
    var app: ALTApplication?
    var provisioningProfiles: [String: ALTProvisioningProfile]?
    var appexBundleIds: [String: String]?
    var useMainProfile = false
    
    var isFinished = false
    
    var error: Error? {
        get {
            return _error ?? self.authenticatedContext.error
        }
        set {
            _error = newValue
            
            if self.authenticatedContext.error == nil
            {
                // Assign newValue to authenticatedContext.error if the latter is nil.
                // This fixes some operations continuing even after an error has occured.
                self.authenticatedContext.error = newValue
            }
        }
    }
    private var _error: Error?
    
    init(bundleIdentifier: String, authenticatedContext: AuthenticatedOperationContext)
    {
        self.bundleIdentifier = bundleIdentifier
        self.authenticatedContext = authenticatedContext
    }
    
    subscript<T>(dynamicMember keyPath: WritableKeyPath<AuthenticatedOperationContext, T>) -> T
    {
        return self.authenticatedContext[keyPath: keyPath]
    }
}

class InstallAppOperationContext: AppOperationContext
{
    lazy var temporaryDirectory: URL = {
        let temporaryDirectory = FileManager.default.uniqueTemporaryURL()
        
        do { try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true, attributes: nil) }
        catch { self.error = error }
        
        return temporaryDirectory
    }()
    
    var ipaURL: URL?
    var resignedApp: ALTApplication?
    var installedApp: InstalledApp? {
        didSet {
            self.installedAppContext = self.installedApp?.managedObjectContext
        }
    }
    private var installedAppContext: NSManagedObjectContext?
    
    var beginInstallationHandler: ((InstalledApp) -> Void)?
    
    var alternateIconURL: URL?
    
    var shouldTurnOffData: Bool = false
    
    // Non-nil when installing from a source.
    @AsyncManaged
    var appVersion: AppVersion?
}
