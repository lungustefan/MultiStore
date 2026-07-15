//
//  AccountManager.swift
//  AltStoreCore
//
//  Manages multiple Apple Developer accounts and the mapping between installed
//  apps and the account that signs them.
//

import Foundation
import CoreData

import AltSign

/// Single entry point for everything related to Apple accounts.
///
/// SideStore historically assumed exactly one Apple account (the "active" account/team plus one
/// global set of credentials in the `Keychain`). `AccountManager` generalises this to any number
/// of accounts: it owns the account ↔ app mapping, resolves which account should sign a given app,
/// and exposes per-account credential state. It deliberately holds **no mutable global state** —
/// every query reads from Core Data / the `Keychain`, so there is a single source of truth and no
/// cached "current account" to keep in sync.
///
/// Interactive operations that require the app layer (adding an account via the login UI, or
/// refreshing an account's apps) are implemented in an `AccountManager` extension inside the
/// AltStore target, where `AppManager` and `AuthenticationOperation` are available.
public class AccountManager
{
    public static let shared = AccountManager()

    private init() {}
}

// MARK: - Queries
public extension AccountManager
{
    /// All Apple accounts known to SideStore.
    func listAccounts(in context: NSManagedObjectContext = DatabaseManager.shared.viewContext) -> [Account]
    {
        return Account.all(sortedBy: [NSSortDescriptor(keyPath: \Account.appleID, ascending: true)], in: context)
    }

    /// The account with the given identifier (`Account.identifier`), if any.
    func account(_ identifier: String, in context: NSManagedObjectContext = DatabaseManager.shared.viewContext) -> Account?
    {
        let predicate = NSPredicate(format: "%K == %@", #keyPath(Account.identifier), identifier)
        return Account.first(satisfying: predicate, in: context)
    }

    /// The default account used when installing a new app (the legacy "active" account).
    func defaultAccount(in context: NSManagedObjectContext = DatabaseManager.shared.viewContext) -> Account?
    {
        return DatabaseManager.shared.activeAccount(in: context)
    }

    /// Accounts that currently have usable stored credentials (i.e. can be authenticated
    /// without prompting the user again). These are the accounts able to sign/refresh apps.
    func activeAccounts(in context: NSManagedObjectContext = DatabaseManager.shared.viewContext) -> [Account]
    {
        return self.listAccounts(in: context).filter { self.hasValidCredentials(for: $0) }
    }

    /// Whether the account has enough stored secrets to attempt a silent authentication.
    func hasValidCredentials(for account: Account) -> Bool
    {
        return Keychain.shared.hasCredentials(forAccount: account.identifier)
    }
}

// MARK: - App ↔ account mapping
public extension AccountManager
{
    /// The account responsible for signing `app`, resolved via its permanent `signingAccountID`
    /// (falling back to the account of its `team` for apps installed before multi-account support).
    ///
    /// Must be called on `app`'s managed object context's queue.
    func accountForApp(_ app: InstalledApp) -> Account?
    {
        guard let context = app.managedObjectContext else { return nil }
        guard let accountID = app.resolvedSigningAccountID else { return nil }
        return self.account(accountID, in: context)
    }

    /// All installed apps assigned to the given account.
    ///
    /// Matches on the stored `signingAccountID` as well as the legacy `team.account.identifier`
    /// path so apps are correctly grouped both before and after the backfill migration runs.
    func appsForAccount(_ accountID: String, in context: NSManagedObjectContext = DatabaseManager.shared.viewContext) -> [InstalledApp]
    {
        let predicate = NSPredicate(format: "%K == %@ OR (%K == nil AND %K == %@)",
                                    #keyPath(InstalledApp.signingAccountID), accountID,
                                    #keyPath(InstalledApp.signingAccountID),
                                    #keyPath(InstalledApp.team.account.identifier), accountID)
        return InstalledApp.all(satisfying: predicate, in: context)
    }

    /// Permanently record which account signs an app, keeping the `team` relationship consistent.
    ///
    /// This only updates the persisted mapping; callers are expected to trigger a re-sign
    /// afterwards so the app is actually signed by the newly-assigned account.
    /// Must be called on `context`'s queue; does not save.
    @discardableResult
    func assignAccount(_ accountID: String, toAppWithBundleIdentifier bundleIdentifier: String, in context: NSManagedObjectContext) -> Bool
    {
        let appPredicate = NSPredicate(format: "%K == %@", #keyPath(InstalledApp.bundleIdentifier), bundleIdentifier)
        guard let installedApp = InstalledApp.first(satisfying: appPredicate, in: context) else { return false }
        guard let account = self.account(accountID, in: context) else { return false }

        installedApp.signingAccountID = accountID

        // Bind the app to one of the account's teams so free/paid limits and profile lookups
        // continue to resolve through the existing team relationship. Prefer the active team.
        let team = account.teams.first(where: { $0.isActiveTeam }) ?? account.teams.first
        if let team = team
        {
            installedApp.team = team
        }

        // Re-signing is required to actually switch the signer.
        installedApp.needsResign = true

        return true
    }

    /// Designate `accountID` as the default account for new installs, keeping exactly one team of
    /// that account active, and mirror its credentials + cached session into the legacy global
    /// keychain slots so single-account UI/paths keep working. Pass `nil` to clear the default
    /// (e.g. after the last account is removed). Must be called on `context`'s queue; does not save.
    func setDefaultAccount(_ accountID: String?, in context: NSManagedObjectContext)
    {
        for account in self.listAccounts(in: context)
        {
            let isDefault = (account.identifier == accountID)
            account.isActiveAccount = isDefault

            if isDefault
            {
                let preferredTeam = account.teams.first(where: { $0.isActiveTeam }) ?? account.teams.first
                for team in account.teams { team.isActiveTeam = (team === preferredTeam) }
            }
            else
            {
                for team in account.teams { team.isActiveTeam = false }
            }
        }

        // Mirror the default account's secrets into the global keychain slots so legacy
        // single-account consumers (certificate management, "signed in?" checks, SideStore
        // self-sign) continue to work unchanged.
        let keychain = Keychain.shared
        if let accountID = accountID
        {
            let credentials = keychain.credentials(forAccount: accountID)
            keychain.appleIDEmailAddress = credentials.emailAddress
            keychain.appleIDPassword = credentials.password
            keychain.appleIDAdsid = credentials.adsid
            keychain.appleIDXcodeToken = credentials.xcodeToken
            keychain.signingCertificate = credentials.signingCertificate
            keychain.signingCertificatePassword = credentials.signingCertificatePassword
            keychain.session = keychain.cachedSession(forAccount: accountID)
            keychain.certificate = keychain.cachedCertificate(forAccount: accountID)
            keychain.team = keychain.cachedTeam(forAccount: accountID)
        }
        else
        {
            keychain.reset()
        }
    }

    /// Remove an account: clear its stored credentials, delete the `Account` (cascading to its
    /// teams), and — if it was the default — promote another account as the new default. Installed
    /// apps keep their `signingAccountID` so re-adding the same Apple ID automatically re-links
    /// them; until then those apps fail to refresh in isolation. Must be called on `context`'s
    /// queue; saves the context.
    func deleteAccount(_ accountID: String, in context: NSManagedObjectContext) throws
    {
        Keychain.shared.removeCredentials(forAccount: accountID)

        guard let account = self.account(accountID, in: context) else { return }
        let wasDefault = account.isActiveAccount

        context.delete(account)
        try context.save()

        if wasDefault
        {
            let replacement = self.activeAccounts(in: context).first ?? self.listAccounts(in: context).first
            self.setDefaultAccount(replacement?.identifier, in: context)
            try context.save()
        }
    }
}

// MARK: - Migration
public extension AccountManager
{
    /// Run the one-time (idempotent) multi-account migrations on a private background context:
    /// re-home legacy global credentials into per-account storage and backfill each app's
    /// `signingAccountID`. Safe to call on every launch.
    func performStartupMigrations()
    {
        let context = DatabaseManager.shared.persistentContainer.newBackgroundContext()
        context.performAndWait {
            self.migrateLegacyCredentialsIfNeeded(in: context)
            let updated = self.backfillSigningAccountIDs(in: context)

            if updated > 0 || context.hasChanges
            {
                do { try context.save() }
                catch { debugLog("[AccountManager] Failed to save startup migrations: \(error)") }
            }
        }
    }

    /// Migrate a pre-multi-account installation so the existing single account becomes a
    /// first-class account with its own per-account credentials. Copies the legacy global
    /// credentials into the default account's per-account slots. Idempotent and safe to call
    /// on every launch.
    func migrateLegacyCredentialsIfNeeded(in context: NSManagedObjectContext = DatabaseManager.shared.viewContext)
    {
        guard let account = self.defaultAccount(in: context) else { return }

        // Already migrated — nothing to do.
        guard !Keychain.shared.hasCredentials(forAccount: account.identifier) else { return }

        let keychain = Keychain.shared
        let legacy = AccountCredentials(
            emailAddress: keychain.appleIDEmailAddress ?? account.appleID,
            password: keychain.appleIDPassword,
            adsid: keychain.appleIDAdsid,
            xcodeToken: keychain.appleIDXcodeToken,
            signingCertificate: keychain.signingCertificate,
            signingCertificatePassword: keychain.signingCertificatePassword
        )

        guard legacy.canAuthenticate || legacy.signingCertificate != nil else { return }

        keychain.setCredentials(legacy, forAccount: account.identifier)
        debugLog("[AccountManager] Migrated legacy credentials to per-account storage for \(account.appleID).")
    }

    /// Backfill `signingAccountID` for apps installed before the field existed, using the account
    /// of each app's `team` (falling back to the default account). Idempotent; does not save.
    /// Returns the number of apps updated.
    @discardableResult
    func backfillSigningAccountIDs(in context: NSManagedObjectContext) -> Int
    {
        let predicate = NSPredicate(format: "%K == nil", #keyPath(InstalledApp.signingAccountID))
        let apps = InstalledApp.all(satisfying: predicate, in: context)
        guard !apps.isEmpty else { return 0 }

        let fallbackAccountID = self.defaultAccount(in: context)?.identifier

        var updated = 0
        for app in apps
        {
            guard let accountID = app.team?.account?.identifier ?? fallbackAccountID else { continue }
            app.signingAccountID = accountID
            updated += 1
        }

        if updated > 0
        {
            debugLog("[AccountManager] Backfilled signingAccountID for \(updated) app(s).")
        }

        return updated
    }
}
