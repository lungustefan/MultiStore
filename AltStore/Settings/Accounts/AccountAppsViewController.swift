//
//  AccountAppsViewController.swift
//  AltStore
//
//  Lists the installed apps signed by a given account and lets the user reassign an app to a
//  different account (which re-signs it). Provides the "change signing account" capability
//  without modifying the existing storyboard-driven app detail screen.
//

import UIKit

import AltStoreCore
import AltSign

class AccountAppsViewController: UITableViewController
{
    private let accountID: String
    private var apps: [InstalledApp] = []

    init(accountID: String)
    {
        self.accountID = accountID
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder)
    {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad()
    {
        super.viewDidLoad()

        self.title = NSLocalizedString("Signed Apps", comment: "")
        self.reloadApps()
    }

    private func reloadApps()
    {
        self.apps = AccountManager.shared.appsForAccount(self.accountID, in: DatabaseManager.shared.viewContext)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if self.isViewLoaded
        {
            self.tableView.reloadData()
        }
    }

    override func numberOfSections(in tableView: UITableView) -> Int
    {
        return 1
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int
    {
        return max(self.apps.count, 1)
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String?
    {
        return NSLocalizedString("Tap an app to sign it with a different account. Changing the account re-signs the app.", comment: "")
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell
    {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)

        guard !self.apps.isEmpty else
        {
            cell.textLabel?.text = NSLocalizedString("No apps signed by this account", comment: "")
            cell.textLabel?.textColor = .secondaryLabel
            cell.selectionStyle = .none
            return cell
        }

        let app = self.apps[indexPath.row]
        cell.textLabel?.text = app.name
        cell.detailTextLabel?.text = app.bundleIdentifier
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath)
    {
        tableView.deselectRow(at: indexPath, animated: true)
        guard !self.apps.isEmpty else { return }

        let app = self.apps[indexPath.row]
        self.presentAccountPicker(for: app, sourceView: tableView.cellForRow(at: indexPath))
    }

    private func presentAccountPicker(for app: InstalledApp, sourceView: UIView?)
    {
        let candidates = AccountManager.shared.listAccounts(in: DatabaseManager.shared.viewContext)
            .filter { $0.identifier != self.accountID }

        guard !candidates.isEmpty else
        {
            let alertController = UIAlertController(
                title: NSLocalizedString("No Other Accounts", comment: ""),
                message: NSLocalizedString("Add another Apple account before changing an app's signing account.", comment: ""),
                preferredStyle: .alert
            )
            alertController.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: ""), style: .default))
            self.present(alertController, animated: true)
            return
        }

        let alertController = UIAlertController(
            title: String(format: NSLocalizedString("Sign “%@” with…", comment: ""), app.name),
            message: nil,
            preferredStyle: .actionSheet
        )

        for account in candidates
        {
            let accountID = account.identifier
            alertController.addAction(UIAlertAction(title: account.localizedName, style: .default) { [weak self] _ in
                self?.changeAccount(for: app, to: accountID)
            })
        }

        alertController.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: ""), style: .cancel))
        alertController.popoverPresentationController?.sourceView = sourceView
        alertController.popoverPresentationController?.sourceRect = sourceView?.bounds ?? .zero
        self.present(alertController, animated: true)
    }

    private func changeAccount(for app: InstalledApp, to accountID: String)
    {
        AccountManager.shared.changeSigningAccount(for: app, to: accountID, presentingViewController: self) { [weak self] result in
            DispatchQueue.main.async {
                if case .failure(let error) = result, !(error is CancellationError)
                {
                    let alertController = UIAlertController(title: NSLocalizedString("Couldn't Change Account", comment: ""), message: error.localizedDescription, preferredStyle: .alert)
                    alertController.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: ""), style: .default))
                    self?.present(alertController, animated: true)
                }
                self?.reloadApps()
            }
        }
    }
}
