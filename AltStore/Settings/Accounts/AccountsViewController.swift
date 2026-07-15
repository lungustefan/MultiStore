//
//  AccountsViewController.swift
//  AltStore
//
//  Minimal UI for managing multiple Apple accounts and each app's signing account.
//
//  Deliberately implemented programmatically and self-contained so it doesn't require changes to
//  the existing storyboard-driven screens. Backend behaviour (AccountManager) is the source of
//  truth; this screen is a thin presentation layer over it.
//

import UIKit

import AltStoreCore
import AltSign

class AccountsViewController: UITableViewController
{
    private var accounts: [Account] = []

    init()
    {
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder)
    {
        super.init(coder: coder)
    }

    override func viewDidLoad()
    {
        super.viewDidLoad()

        self.title = NSLocalizedString("Apple Accounts", comment: "")

        self.navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(AccountsViewController.done))
        self.navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .add, target: self, action: #selector(AccountsViewController.addAccount))

        self.tableView.register(UITableViewCell.self, forCellReuseIdentifier: "Cell")

        self.reloadAccounts()
    }

    private func reloadAccounts()
    {
        self.accounts = AccountManager.shared.listAccounts(in: DatabaseManager.shared.viewContext)
        if self.isViewLoaded
        {
            self.tableView.reloadData()
        }
    }

    @objc private func done()
    {
        self.dismiss(animated: true)
    }

    @objc private func addAccount()
    {
        AccountManager.shared.addAccount(presentingViewController: self) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result
                {
                case .success: self.reloadAccounts()
                case .failure(OperationError.cancelled): break
                case .failure(let error): self.present(error: error)
                }
            }
        }
    }
}

// MARK: - Table view
extension AccountsViewController
{
    override func numberOfSections(in tableView: UITableView) -> Int
    {
        return 1
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int
    {
        return max(self.accounts.count, 1)
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String?
    {
        return NSLocalizedString("SIGNED-IN ACCOUNTS", comment: "")
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String?
    {
        return NSLocalizedString("Each installed app is refreshed with the account that signed it. Tap an account to set it as the default for new installs, refresh its apps, or change which apps it signs.", comment: "")
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell
    {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)

        guard !self.accounts.isEmpty else
        {
            cell.textLabel?.text = NSLocalizedString("No accounts", comment: "")
            cell.detailTextLabel?.text = NSLocalizedString("Tap + to add an Apple account.", comment: "")
            cell.textLabel?.textColor = .secondaryLabel
            cell.selectionStyle = .none
            return cell
        }

        let account = self.accounts[indexPath.row]

        var title = account.localizedName
        if title.trimmingCharacters(in: .whitespaces).isEmpty
        {
            title = account.appleID
        }
        if account.isActiveAccount
        {
            title += " " + NSLocalizedString("(Default)", comment: "")
        }
        cell.textLabel?.text = title

        let status = AccountManager.shared.hasValidCredentials(for: account)
            ? NSLocalizedString("Signed in", comment: "")
            : NSLocalizedString("Needs sign-in", comment: "")
        cell.detailTextLabel?.text = "\(account.appleID) · \(status)"
        cell.detailTextLabel?.textColor = AccountManager.shared.hasValidCredentials(for: account) ? .secondaryLabel : .systemRed

        cell.accessoryType = .disclosureIndicator
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath)
    {
        tableView.deselectRow(at: indexPath, animated: true)
        guard !self.accounts.isEmpty else { return }

        let account = self.accounts[indexPath.row]
        self.presentActions(for: account, sourceView: tableView.cellForRow(at: indexPath))
    }

    override func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration?
    {
        guard !self.accounts.isEmpty else { return nil }
        let account = self.accounts[indexPath.row]

        let removeAction = UIContextualAction(style: .destructive, title: NSLocalizedString("Remove", comment: "")) { [weak self] _, _, completion in
            self?.confirmRemove(account)
            completion(true)
        }
        return UISwipeActionsConfiguration(actions: [removeAction])
    }
}

// MARK: - Actions
private extension AccountsViewController
{
    func presentActions(for account: Account, sourceView: UIView?)
    {
        let accountID = account.identifier
        let alertController = UIAlertController(title: account.localizedName, message: account.appleID, preferredStyle: .actionSheet)

        if !account.isActiveAccount
        {
            alertController.addAction(UIAlertAction(title: NSLocalizedString("Set as Default", comment: ""), style: .default) { [weak self] _ in
                self?.setDefault(accountID)
            })
        }

        alertController.addAction(UIAlertAction(title: NSLocalizedString("Refresh Apps", comment: ""), style: .default) { [weak self] _ in
            self?.refresh(accountID)
        })

        alertController.addAction(UIAlertAction(title: NSLocalizedString("Manage Signed Apps", comment: ""), style: .default) { [weak self] _ in
            let appsViewController = AccountAppsViewController(accountID: accountID)
            self?.navigationController?.pushViewController(appsViewController, animated: true)
        })

        alertController.addAction(UIAlertAction(title: NSLocalizedString("Remove Account", comment: ""), style: .destructive) { [weak self] _ in
            self?.confirmRemove(account)
        })

        alertController.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: ""), style: .cancel))

        alertController.popoverPresentationController?.sourceView = sourceView
        alertController.popoverPresentationController?.sourceRect = sourceView?.bounds ?? .zero
        self.present(alertController, animated: true)
    }

    func setDefault(_ accountID: String)
    {
        let context = DatabaseManager.shared.persistentContainer.newBackgroundContext()
        context.performAndWait {
            AccountManager.shared.setDefaultAccount(accountID, in: context)
            do { try context.save() }
            catch { debugLog("Failed to set default account: \(error)") }
        }
        self.reloadAccounts()
    }

    func refresh(_ accountID: String)
    {
        AccountManager.shared.refreshAccount(accountID, presentingViewController: self) { [weak self] result in
            DispatchQueue.main.async {
                switch result
                {
                case .success(let results):
                    let failures = results.values.filter { if case .failure = $0 { return true } else { return false } }
                    if let firstFailure = failures.first, case .failure(let error) = firstFailure
                    {
                        self?.present(error: error)
                    }
                case .failure(let error):
                    self?.present(error: error)
                }
                self?.reloadAccounts()
            }
        }
    }

    func confirmRemove(_ account: Account)
    {
        let accountID = account.identifier
        let alertController = UIAlertController(
            title: String(format: NSLocalizedString("Remove “%@”?", comment: ""), account.localizedName),
            message: NSLocalizedString("Its stored credentials will be deleted. Apps signed by this account will stop refreshing until you reassign them or sign in again.", comment: ""),
            preferredStyle: .alert
        )
        alertController.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: ""), style: .cancel))
        alertController.addAction(UIAlertAction(title: NSLocalizedString("Remove", comment: ""), style: .destructive) { [weak self] _ in
            AccountManager.shared.removeAccount(accountID) { result in
                DispatchQueue.main.async {
                    if case .failure(let error) = result
                    {
                        self?.present(error: error)
                    }
                    self?.reloadAccounts()
                }
            }
        })
        self.present(alertController, animated: true)
    }

    func present(error: Error)
    {
        let alertController = UIAlertController(title: NSLocalizedString("Operation Failed", comment: ""), message: error.localizedDescription, preferredStyle: .alert)
        alertController.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: ""), style: .default))
        self.present(alertController, animated: true)
    }
}
