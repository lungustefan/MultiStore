# Multi-Account Signing — Architecture Analysis (Phase 1)

This document explains how SideStore currently authenticates, signs, installs and
refreshes apps, and enumerates every place that assumes a **single** Apple
Developer account. It is the basis for the incremental refactor described in
[`PLAN.md`](PLAN.md).

> TL;DR — The **signing/provisioning pipeline is already parameterised** by an
> `AuthenticatedOperationContext` that carries a `session` + `team` +
> `certificate`. The single-account assumption is **not** in the pipeline; it is
> concentrated in five places: the global `Keychain`, `AuthenticationOperation`,
> `AppManager.refresh`, `InstallAppOperation`, and the account UI. Generalising
> those five is the whole job.

---

## 1. Authentication

### Apple ID login
- **`AltStore/Operations/AuthenticationOperation.swift`** is the whole login flow.
  It is a `ResultOperation<(ALTTeam, ALTCertificate?, ALTAppleAPISession)>`.
- Login path (`signIn()` → `authenticate(appleID:password:)` /
  `authenticateWithToken(adsid:xcodeToken:)`): fetch anisette data → call
  `ALTAppleAPI.shared.authenticate(...)` (2FA handled via alert) → obtain
  `ALTAccount` + `ALTAppleAPISession`.
- Team selection: `fetchTeam(for:session:)` → `ALTAppleAPI.fetchTeams` →
  if a DB "active team" exists use it, else `selectTeam` (UI if >1).
- Certificate: `fetchCertificate(for:session:)` reuses the cached
  `signingCertificate` if it matches a live cert, else requests/replaces one.
- Device registration + `cacheAppIDs`.

### Session persistence / token storage
- **`AltStoreCore/Components/Keychain.swift`** — a **singleton** (`Keychain.shared`)
  that stores exactly one set of credentials:
  - `appleIDEmailAddress`, `appleIDPassword`, `appleIDAdsid` (dsid),
    `appleIDXcodeToken` (authToken) — **per-account** values, stored globally.
  - `signingCertificate` (PKCS#12), `signingCertificatePassword` — **per-account**.
  - `identifier`, `adiPb` — **per-device anisette** state (correctly shared
    across accounts; must NOT be duplicated per account).
  - In-memory cache: `certificate`, `session`, `team` — one of each.
- The cached `session/team/certificate` short-circuit re-login in
  `AuthenticationOperation.main()`.

### Team IDs / certificate management / provisioning
- Team, certificate, device, App ID and provisioning-profile calls all take an
  explicit `team` + `session`, so they are **not** globally bound — they are
  driven by whatever the operation's context holds.

### Single-account assumptions (auth)
| Location | Assumption |
|---|---|
| `Keychain.swift` (all credential keys + `certificate`/`session`/`team`) | One credential set, one cached session/cert/team for the whole app. |
| `AuthenticationOperation.main` L96-134 | Reuses the single cached `Keychain.shared.session/team/certificate`. |
| `AuthenticationOperation.postAuthenticationCleanup` L237-256 | Sets `isActiveAccount = true` on this account and `false` on **all others**, and same for `isActiveTeam` — i.e. exactly one active account/team. |
| `AuthenticationOperation.signIn` L358-382 | Reads the single global `appleIDEmailAddress`/`appleIDAdsid`. |
| `AuthenticationOperation.fetchTeam` L505-509 | Uses `DatabaseManager.activeTeam` as "the" team. |

---

## 2. Signing pipeline

Entry points live in **`AltStore/Managing Apps/AppManager.swift`**; the heavy
lifting is in `AltStore/Operations/*`. Every operation is threaded an
`AppOperationContext` whose `authenticatedContext` is an
`AuthenticatedOperationContext` (`session`/`team`/`certificate`).

- **IPA preparation + resign** — `ResignAppOperation.swift`. Uses
  `self.context.team` + `self.context.certificate` and
  `ALTSigner(team:certificate:)`. **Already account-agnostic.** The only global
  read is the `app.isAltStoreApp` self-refresh branch (L142-144) which embeds
  `Keychain.shared.signingCertificate` into the SideStore bundle.
- **Provisioning profiles** — `FetchProvisioningProfilesOperation.swift`
  (`self.context.team`/`session`). Account-agnostic.
- **App IDs** — `FetchAppIDsOperation.swift` (`self.context.team`/`session`).
  Account-agnostic.
- **Entitlements** — handled inside `ResignAppOperation.prepare(...)` from the
  provisioning profile. Account-agnostic.
- **Install** — `InstallAppOperation.swift`. Uses `self.context.certificate` and
  provisioning profiles from context. **But** L153 binds the new
  `InstalledApp.team = DatabaseManager.shared.activeTeam` — the single point where
  the app→account link is (incorrectly, for multi-account) set to the active team
  instead of the team that actually signed it.

### Single-account assumptions (signing)
| Location | Assumption |
|---|---|
| `InstallAppOperation.findOrCreateInstalledApp` L153 | New apps are always bound to the **active** team. |
| `ResignAppOperation.prepareAppBundle` L142-144 | SideStore self-refresh embeds the single global certificate. |
| `AppManager._refresh` L1600 | Certificate-match check falls back to the single global `Keychain.shared.signingCertificate`. |

---

## 3. Installed applications

- **Model** — `AltStoreCore/Model/InstalledApp.swift` + Core Data entity
  `InstalledApp` (current model version **`AltStore 17_1`**).
  - Relationship chain already present: `InstalledApp.team → Team.account → Account`.
  - So an app already *can* name its account via `team?.account`. There is **no
    explicit, permanent** `signingAccountID` field yet.
- **Persistence** — `AltStoreCore/Model/DatabaseManager/DatabaseManager.swift`
  over `RSTPersistentContainer` (`AltStoreCore/Roxas/RSTPersistentContainer.swift`).
  - Migration is **progressive** and falls back to
    `NSMappingModel.inferredMappingModel` (lightweight). Adding an *optional*
    attribute in a new model version therefore migrates automatically with no
    explicit mapping model.
- **Refresh queue** — `AppManager` `operationQueue` (concurrent) +
  `serialOperationQueue` (install/refresh/backup serialised; SideStore-self last).
- **Expiration tracking** — `InstalledApp.expirationDate` (from the provisioning
  profile). `fetchAppsForRefreshingAll` / `fetchAppsForBackgroundRefresh` select
  apps to refresh, sorted by expiration.

### Single-account assumptions (installed apps / persistence)
| Location | Assumption |
|---|---|
| `Account.isActiveAccount`, `Team.isActiveTeam` (model + `DatabaseManager.activeAccount/activeTeam`) | Exactly one "current" account/team. |
| `InstalledApp` | No permanent per-app account field; the account is only implied by the mutable `team` relationship. |
| `Migrations/Policies/InstalledAppPolicy.swift` L24 | Migration policy fetches the single `isActiveTeam` team. |

---

## 4. Refresh workflow

- **Foreground** — `MyAppsViewController` / app detail → `AppManager.refresh(_:)`.
- **Background** — `BackgroundRefreshAppsOperation.swift` collects
  `fetchAppsForBackgroundRefresh` and calls **`AppManager.shared.refresh(apps, …)`**.
- **`AppManager.refresh(_:presentingViewController:group:)`** (L784) creates **one**
  `RefreshGroup` (one `AuthenticatedOperationContext`) for **all** apps.
- **`AppManager.perform(_:group:)`** (L1131): if `group.context.session == nil`,
  authenticate **once** (L1148) using the group's context (→ global keychain), then
  run every app's operations against that **single shared** session/team/cert.

### Single-account assumptions (refresh)
| Location | Assumption |
|---|---|
| `AppManager.refresh` L784-798 | All apps refreshed in a single group / single account. |
| `AppManager.perform` L1146-1159 | Exactly one authentication per refresh batch. |
| `BackgroundRefreshAppsOperation` | All background apps go through one `refresh(...)` group. |

**Consequence for failure isolation:** because there is one context and one
`context.error`, an auth/cert/provisioning failure for the single account fails
the *entire* batch. There is currently no isolation because there is only ever
one account.

---

## 5. UI touch-points that read the single account

| Location | Use |
|---|---|
| `AltStore/Settings/SettingsViewController.swift` (`activeTeam`, `signIn`, `signOut`, `.signIn`/`.account` sections) | Shows the one signed-in account; sign-in/out. |
| `AltStore/App IDs/AppIDsViewController.swift` L91/223/322 | Uses `activeTeam`. |
| `AltStore/My Apps/MyAppsViewController.swift` L1805/2187 | Footer / sizing keyed on `activeTeam != nil`. |
| `AltStore/LaunchViewController.swift` L185-192 & `SettingsViewController` L286-295 | "Import account" writes the global keychain credentials. |
| `AltStore/Settings/Certificates/CertificatesViewModel.swift` | Manages the single global certificate. |

---

## 6. Summary of the five things to generalise

1. **`Keychain`** — one credential set + one cached session/cert/team → keyed by
   account identifier (device-level anisette `identifier`/`adiPb` stay global).
2. **`AuthenticationOperation`** — authenticate a *specified* account; stop forcing
   a single `isActiveAccount`/`isActiveTeam`.
3. **`AppManager.refresh`** — partition apps by their assigned account and refresh
   each account in its own group/context (→ natural failure isolation).
4. **`InstallAppOperation`** — bind a new app to the team/account that *signed* it,
   and persist a permanent `signingAccountID`.
5. **UI** — manage N accounts (add/remove/list/status) and show/change an app's
   signing account.

Everything else (resign, provisioning, App IDs, entitlements, install transport)
is already context-driven and needs no change.
