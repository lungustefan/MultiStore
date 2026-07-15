//
//  LaunchViewController.swift
//  AltStore
//
//  Created by Riley Testut on 7/30/19.
//  Copyright © 2019 Riley Testut. All rights reserved.
//

import UIKit

import WidgetKit

import AltSign
import AltStoreCore
import UniformTypeIdentifiers

let pairingFileName = "ALTPairingFile.mobiledevicepairing"

final class LaunchViewController: UIViewController, UIDocumentPickerDelegate {
    private var didFinishLaunching = false
    private var retries = 0
    private var maxRetries = 3
    private var splashView: SplashView!
    private var destinationViewController: TabBarController?
    private var startTime: Date!

    override func viewDidLoad() {
        super.viewDidLoad()
        splashView = SplashView(frame: view.bounds, appName: "SideStore")
        destinationViewController = storyboard!.instantiateViewController(withIdentifier: "tabBarController") as? TabBarController
        view.addSubview(splashView)
    }

    override func viewDidAppear(_ animated: Bool) {
        debugLog("LaunchViewController.viewDidAppear() invoked")
        super.viewDidAppear(animated)
        guard !didFinishLaunching else { return }
        startTime = Date()
        
        // spin off the startup sequence concurrently
        Task.detached { [weak self] in
            await self?.runLaunchSequence()
        }
        Task.detached { [weak self] in
            await self?.doPostLaunch()
        }
    }

    private nonisolated func runLaunchSequence() async {
        guard await retries < maxRetries else { return }
        await MainActor.run{
            retries += 1
        }
        if !DatabaseManager.shared.isStarted {
            await withCheckedContinuation { continuation in
                DatabaseManager.shared.start { error in
                    if let error {
                        Task { await self.handleLaunchError(error, retryCallback: self.runLaunchSequence) }
                    } else {
                        Task { await self.finishLaunching() }
                    }
                    continuation.resume(returning: ())
                }
            }
        } else {
            await self.finishLaunching()
        }
    }

    private nonisolated func doPostLaunch() async {
        #if !targetEnvironment(simulator)
        await detectAndImportAccountFile()
        #endif
    }

    @MainActor
    func showPairingPrompt(isRetry: Bool) {
        let title = isRetry ? NSLocalizedString("Invalid Pairing File", comment: "") : NSLocalizedString("Pairing File", comment: "")
        let message = isRetry
            ? NSLocalizedString("The selected pairing file is invalid or not usable. Please select a valid pairing file.", comment: "")
            : NSLocalizedString("Select the pairing file or select \"Help\" for help.", comment: "")
        
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        
        alert.addAction(UIAlertAction(title: NSLocalizedString("Help", comment: ""), style: .default) { _ in
            if let url = URL(string: "https://docs.sidestore.io/docs/advanced/pairing-file") { UIApplication.shared.open(url) }
            sleep(2); exit(0)
        })
        
        alert.addAction(UIAlertAction(title: NSLocalizedString("Select File", comment: ""), style: .default) { _ in
            // Accept any file: pairing files exported by external tools come with varied extensions
            // (.plist, .mobiledevicepairing, none, …) and iOS sometimes tags a plain .plist in a way
            // the narrow type list didn't match, greying it out. `.item` is the universal supertype,
            // so every file is selectable; the chosen file is validated when minimuxer starts, so a
            // wrong pick just fails gracefully instead of blocking selection.
            let types: [UTType] = [.propertyList, .xml, .text, .data, .item]
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: types)
            picker.delegate = self
            picker.shouldShowFileExtensions = true
            self.present(picker, animated: true)
        })
        
        let cancelTitle = isRetry ? NSLocalizedString("Skip", comment: "") : NSLocalizedString("Cancel", comment: "")
        alert.addAction(UIAlertAction(title: cancelTitle, style: .cancel) { _ in
            self.showPairingWarningAndProceed()
        })
        
        self.present(alert, animated: true)
    }

    func showPairingWarningAndProceed() {
        let warningAlert = UIAlertController(
            title: "⚠️ " + NSLocalizedString("Pairing Required", comment: ""),
            message: NSLocalizedString("Without a valid pairing file, operations that require a pairing file (such as installing, refreshing, or resigning apps) will not function.", comment: ""),
            preferredStyle: .alert
        )
        warningAlert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: ""), style: .default))
        self.present(warningAlert, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        let isSecuredURL = url.startAccessingSecurityScopedResource()
        defer {
            if isSecuredURL {
                url.stopAccessingSecurityScopedResource()
            }
        }
        
        do {
            debugLog("[LaunchViewController] User picked pairing file from: \(url.path)")
            let data = try Data(contentsOf: url)
            guard let pairingString = String(data: data, encoding: .utf8) else {
                debugLog("[LaunchViewController] Unable to read pairing file")
                self.showPairingPrompt(isRetry: true)
                return
            }
            let fm = FileManager.default
            let documentsPath = fm.documentsDirectory.appendingPathComponent(pairingFileName)
            if fm.fileExists(atPath: documentsPath.path) {
                try? fm.removeItem(at: documentsPath)
            }
            try pairingString.write(to: documentsPath, atomically: true, encoding: .utf8)
            debugLog("[LaunchViewController] Successfully copied and saved pairing file to: \(documentsPath.path)")
            UserDefaults.standard.isPairingReset = false
            
            Task {
                do {
                    try await AppBootManager.shared.startMinimuxer(pairingFile: pairingString)
                } catch {
                    await MainActor.run {
                        self.showPairingPrompt(isRetry: true)
                    }
                }
            }
        } catch {
            debugLog("[LaunchViewController] Error importing pairing file: \(error)")
            self.showPairingPrompt(isRetry: true)
        }
    }
    
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        self.showPairingPrompt(isRetry: true)
    }

    func fetchPairingFile() -> String? { AppBootManager.shared.getSavedPairingFile() }

    @MainActor
    func displayError(_ msg: String) {
        debugLog("[SideStore] \(msg)")
        let alert = UIAlertController(title: "Error launching SideStore", message: msg, preferredStyle: .alert)
        self.present(alert, animated: true)
    }
    
    func importAccountAtFile(_ file: URL, remove: Bool = false) {
        _ = file.startAccessingSecurityScopedResource()
        defer { file.stopAccessingSecurityScopedResource() }
        guard let accountD = try? Data(contentsOf: file) else {
            return debugLog("Could not parse data from file \(file)")
        }
        guard let account = try? Foundation.JSONDecoder().decode(ImportedAccount.self, from: accountD) else {
            return debugLog("Could not parse data from file \(file)")
        }
        debugLog("We want to import this account probably: \(account)")
        if remove {
            try? FileManager.default.removeItem(at: file)
        }
        Keychain.shared.appleIDEmailAddress = account.email
        Keychain.shared.appleIDPassword = account.password
        Keychain.shared.adiPb = account.adiPB
        Keychain.shared.identifier = account.local_user
        do {
            let altCert = try ALTCertificate(p12Data: account.cert, password: account.certpass)
            Keychain.shared.signingCertificate = altCert.encryptedP12Data(withPassword: "")!
            Keychain.shared.signingCertificatePassword = account.certpass
            let toastView = ToastView(text: NSLocalizedString("Successfully imported '\(account.email)'!", comment: ""), detailText: "SideStore should be fully operational!")
            return toastView.show(in: self)
        } catch {
            let toastView = ToastView(text: NSLocalizedString("Failed to import account certificate!", comment: ""), detailText: "Error: \(error.localizedDescription). Still imported account/adi.pb details!")
            return toastView.show(in: self)
        }
    }
    
    func detectAndImportAccountFile() {
        let accountFileURL = FileManager.default.documentsDirectory.appendingPathComponent("Account.sideconf")
        #if !DEBUG
        importAccountAtFile(accountFileURL, remove: true)
        #else
        importAccountAtFile(accountFileURL)
        #endif
    }
}

extension LaunchViewController {
    @MainActor
    func handleLaunchError(_ error: Error, retryCallback: (() async -> Void)? = nil) {
        do { throw error } catch let error as NSError {
            let title = error.userInfo[NSLocalizedFailureErrorKey] as? String ?? NSLocalizedString("Unable to Launch SideStore", comment: "")
            let desc: String
            if #available(iOS 14.5, *) {
                desc = ([error.debugDescription] + error.underlyingErrors.map { ($0 as NSError).debugDescription }).joined(separator: "\n\n")
            } else {
                desc = error.debugDescription
            }
            let alert = UIAlertController(title: title, message: desc, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: NSLocalizedString("Retry", comment: ""), style: .default) { _ in
                Task { await retryCallback?() }
            })
            present(alert, animated: true)
        }
    }

    @MainActor
    func finishLaunching() async {
        guard !didFinishLaunching else { return }
        didFinishLaunching = true
        
        AppManager.shared.update()
        AppManager.shared.updateAllSources { result in
            guard case .failure(let error) = result else { return }
            debugLog("Failed to update sources on launch. \(error.localizedDescription)")
            
            
            let errorDesc = ErrorProcessing(.fullError).getDescription(error: error as NSError)
            debugLog("Failed to update sources on launch. \(errorDesc)")
            
            var mode: ToastView.InfoMode = .fullError
            if String(describing: error).contains("The Internet connection appears to be offline"){
                mode = .localizedDescription    // dont make noise!
            }
            let toastView = ToastView(error: error, mode: mode)
            toastView.addTarget(self.destinationViewController, action: #selector(TabBarController.presentSources), for: .touchUpInside)
            toastView.show(in: self.destinationViewController!.selectedViewController ?? self.destinationViewController!)
        }
        updateKnownSources()
        WidgetCenter.shared.reloadAllTimelines()
        didFinishLaunching = true
        
        let destinationVC = destinationViewController!
        
        let elapsed = abs(startTime.timeIntervalSinceNow)
        let remaining = elapsed >= 1 ? 0 : 1 - elapsed
        try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
        
        destinationVC.loadViewIfNeeded()
        addChild(destinationVC)
        destinationVC.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(destinationVC.view)
        destinationVC.didMove(toParent: self)
        
        // Pin edges BEFORE animation
        NSLayoutConstraint.activate([
            destinationVC.view.topAnchor.constraint(equalTo: view.topAnchor),
            destinationVC.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            destinationVC.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            destinationVC.view.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])

        // Set initial alpha for fade-in
        destinationVC.view.alpha = 0

        UIView.transition(with: view, duration: 0.3, options: .transitionCrossDissolve) { [self] in
            self.splashView.alpha = 0
            destinationVC.view.alpha = 1
        } completion: { [self] _ in
            self.splashView.removeFromSuperview()
            self.destinationViewController = destinationVC
            
            if AppBootManager.shared.needsPairingPrompt {
                self.showPairingPrompt(isRetry: false)
            }
            
            if AppBootManager.shared.needsSideJITPrompt {
                SideJITManager.shared.presentJITPrompt(presentingVC: self)
            }
        }
    }

    func updateKnownSources() {
        AppManager.shared.updateKnownSources { result in
            switch result {
            case .failure(let error): debugLog("[ALTLog] Failed to update known sources: \(error)")
            case .success((_, let blockedSources)):
                DatabaseManager.shared.persistentContainer.performBackgroundTask { context in
                    let blockedSourceIDs = Set(blockedSources.lazy.map { $0.identifier })
                    let blockedSourceURLs = Set(blockedSources.lazy.compactMap { $0.sourceURL })
                    let predicate = NSPredicate(format: "%K IN %@ OR %K IN %@", #keyPath(Source.identifier), blockedSourceIDs, #keyPath(Source.sourceURL), blockedSourceURLs)
                    let sourceErrors = Source.all(satisfying: predicate, in: context).map { source in
                        let blocked = blockedSources.first { $0.identifier == source.identifier }
                        return SourceError.blocked(source, bundleIDs: blocked?.bundleIDs, existingSource: source)
                    }
                    guard !sourceErrors.isEmpty else { return }
                    Task {
                        for error in sourceErrors {
                            let title = String(format: NSLocalizedString("“%@” Blocked", comment: ""), error.$source.name)
                            let message = [error.localizedDescription, error.recoverySuggestion].compactMap { $0 }.joined(separator: "\n\n")
                            await self.presentAlert(title: title, message: message)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - SplashView
final class SplashView: UIView {
    let iconView = UIImageView()
    let titleLabel = UILabel()

    init(frame: CGRect, appName: String) {
        super.init(frame: frame)
        backgroundColor = .systemBackground
        setupIcon()
        setupTitle(appName: appName)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupIcon() {
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.layer.shadowColor = UIColor.black.cgColor
        container.layer.shadowOpacity = 0.25
        container.layer.shadowOffset = CGSize(width: 0, height: 4)
        container.layer.shadowRadius = 8
        addSubview(container)

        iconView.image = UIImage(named: "AppIcon") ?? UIImage(named: "AppIcon60x60") ?? UIImage(systemName: "app.fill")
        iconView.contentMode = .scaleAspectFit
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.layer.cornerRadius = 24
        iconView.clipsToBounds = true
        container.addSubview(iconView)

        NSLayoutConstraint.activate([
            container.centerXAnchor.constraint(equalTo: centerXAnchor),
            container.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -20),
            container.widthAnchor.constraint(equalToConstant: 120),
            container.heightAnchor.constraint(equalToConstant: 120),
            iconView.topAnchor.constraint(equalTo: container.topAnchor),
            iconView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            iconView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            iconView.trailingAnchor.constraint(equalTo: container.trailingAnchor)
        ])
    }

    private func setupTitle(appName: String) {
        titleLabel.text = appName
        titleLabel.font = .systemFont(ofSize: 24, weight: .bold)
        titleLabel.textColor = .label
        titleLabel.textAlignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 12),
            titleLabel.centerXAnchor.constraint(equalTo: centerXAnchor)
        ])
    }
}


final class SideJITManager {
    static let shared = SideJITManager()
    
    @MainActor
    func presentJITPrompt(presentingVC: UIViewController) {
        let alert = UIAlertController(
            title: "SideJITServer Detected",
            message: "Would you like to enable SideJITServer",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in UserDefaults.standard.sidejitenable = true })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        presentingVC.present(alert, animated: true)
    }
}
