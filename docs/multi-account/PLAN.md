# Multi-Account Signing — Implementation Plan (Phase 2)

Derived from [`ARCHITECTURE.md`](ARCHITECTURE.md). The guiding principle is the
**smallest clean refactor** that generalises SideStore from one Apple account to
many, reusing the existing `AuthenticatedOperationContext`-driven pipeline and
matching the existing coding style. Existing single-account behaviour is a
special case (N = 1) of the new design.

## Design summary

- The signing pipeline already carries a per-operation `session`/`team`/`certificate`.
  We make **who fills that context** account-aware instead of globally fixed.
- Credentials become **per-account** in the Keychain, keyed by `Account.identifier`.
  Device-level anisette state (`identifier`, `adiPb`) stays global.
- Each `InstalledApp` gains a permanent **`signingAccountID`**.
- Refresh **partitions apps by account**, runs one authenticated group per account,
  and aggregates results — giving failure isolation for free.
- A new **`AccountManager`** facade is the single entry point the rest of the app
  uses; it holds **no mutable global state** (it reads/writes Core Data + Keychain).
- `isActiveAccount`/`isActiveTeam` are **retained** but re-interpreted as the
  **default account** (used for new installs / legacy UI), not "the only account".

## Architecture changes

| Area | Change |
|---|---|
| Data model | New model version **`AltStore 18`**: add optional `InstalledApp.signingAccountID: String`. Lightweight/inferred migration. |
| Keychain | Add per-account credential + session/cert/team storage keyed by account id; keep global keys for anisette + migration. |
| Context | `AuthenticatedOperationContext` gains `accountID: String?` (target account for this context). |
| Auth | `AuthenticationOperation` authenticates the context's `accountID` from per-account creds; stops nuking other accounts' active flags. |
| Install | `InstallAppOperation` binds the app to the **signing** team/account + sets `signingAccountID`. |
| Refresh | `AppManager.refresh` partitions by account into child groups + aggregate. |
| New type | `AccountManager` (AltStoreCore) with the required API. |
| UI | Accounts list + add/remove/status in Settings; signing-account row + change in app detail. |

## Files to modify / add

**Add**
- `AltStoreCore/Model/AltStore.xcdatamodeld/AltStore 18.xcdatamodel/contents` (+ set `.xccurrentversion`)
- `AltStoreCore/Managers/AccountManager.swift`
- `AltStore/Settings/Accounts/AccountsViewController.swift` (+ minimal cell/rows)
- `docs/multi-account/*` (this analysis/plan)

**Modify**
- `AltStoreCore/Model/InstalledApp.swift` — `signingAccountID` + `signingAccount` helpers
- `AltStoreCore/Components/Keychain.swift` — per-account API
- `AltStoreCore/Model/DatabaseManager/DatabaseManager.swift` — startup backfill/migration hook; keep `activeAccount/activeTeam` as "default"
- `AltStore/Operations/Common/OperationContexts.swift` — `accountID`
- `AltStore/Operations/AuthenticationOperation.swift` — per-account auth + credential store
- `AltStore/Operations/InstallAppOperation.swift` — bind signing team/account
- `AltStore/Managing Apps/AppManager.swift` — account-partitioned refresh + aggregate group; account-scoped resign helper
- `AltStore/Settings/SettingsViewController.swift` — entry to Accounts screen (keep existing single-account rows working)
- App detail (`AltStore/App Detail/…`) — signing-account row + change action

## Data-model change & migration strategy

1. Duplicate `AltStore 17_1.xcdatamodel` → `AltStore 18.xcdatamodel`, add
   `<attribute name="signingAccountID" optional="YES" attributeType="String"/>` to
   `InstalledApp`, bump `userDefinedModelVersionIdentifier` to `v18`, and point
   `.xccurrentversion` at it. Xcode 16 file-system-synchronised groups pick the new
   version up automatically; `RSTPersistentContainer` migrates via the inferred
   (lightweight) mapping model.
2. **Automatic data migration (Phase 8)** at startup (`DatabaseManager.prepareDatabase`
   or a dedicated one-shot): for every `InstalledApp` with `signingAccountID == nil`,
   backfill it from `team?.account?.identifier` (or the active account). Idempotent.
3. **Automatic credential migration**: on first launch after update, if legacy global
   credentials exist and an active account exists, copy them into that account's
   per-account Keychain slots. Preserves the existing user's login as "Account #1".

No user loses apps or signing info: existing rows keep their `team` relationship and
gain a `signingAccountID`; existing credentials are re-homed, not recreated.

## AccountManager API (Phase 3)

`AccountManager.shared` — stateless facade (no mutable stored properties):

- `listAccounts(in:) -> [Account]`
- `account(_ id: String, in:) -> Account?`
- `activeAccounts(in:) -> [Account]` — accounts that currently have usable credentials
- `defaultAccount(in:) -> Account?` — the `isActiveAccount` account (new-install default)
- `addAccount(presentingViewController:) async -> Result<Account, Error>` — interactive login for a new Apple ID, stored per-account
- `removeAccount(_:) async -> Result<Void, Error>` — clear that account's credentials + delete `Account`
- `updateAccount(_:) ` — refresh stored profile info
- `accountForApp(_ app: InstalledApp, in:) -> Account?` — resolve via `signingAccountID` (fallback `team?.account`)
- `assignAccount(_ id:, toApp:) ` — set `signingAccountID` (+ team) permanently
- `refreshAccount(_ id:, presentingViewController:) -> RefreshGroup` — refresh only that account's apps

## Multiple sessions (Phase 4)

- Per-account Keychain slots: `"<accountID>.appleIDPassword"` etc., plus a per-account
  in-memory `[accountID: (session, cert, team)]` cache.
- `AuthenticatedOperationContext.accountID` selects which credentials
  `AuthenticationOperation` loads/stores. `nil` = default account / interactive add.
- Sessions, certificates, teams and App IDs are already isolated by context; storing
  them per-account completes isolation.

## App→account mapping (Phase 5)

- `InstalledApp.signingAccountID` (permanent). Set on install from the signing team's
  account. `InstallAppOperation` uses `context.team` (the team that signed) rather than
  `activeTeam`.

## Per-account refresh + failure isolation (Phase 6/7)

- `AppManager.refresh(apps)`:
  1. Resolve each app's account (`AccountManager.accountForApp`).
  2. Group apps by account id.
  3. `N ≤ 1` → existing single-group path (unchanged behaviour).
  4. `N > 1` → one child `RefreshGroup` per account (`child.context.accountID = id`),
     run concurrently via `perform`; an **aggregate** group merges child results,
     progress and `beginInstallationHandler`, and fires its `completionHandler` when
     all children finish.
- Because each child has its own context/session/`error`, one account's failure only
  fails that child's apps — other accounts keep refreshing. Apps whose account is
  missing/credential-less fail only themselves with a clear error.

## UI (Phase 9 — minimal)

- **Settings → Accounts**: list accounts with status (has valid credentials?),
  Add Account, Remove Account. Existing single-account rows keep working (show default).
- **App detail**: a row showing the current signing account + an action to change it
  (assign a different account, then resign).

## Testing strategy (Phase 10)

Local `xcodebuild` is impossible on this Windows host, so **GitHub Actions
(`.github/workflows/multi-account-ci.yml`, macOS)** is the authoritative build/test:
- `build` job: `make build` (archive, no signing) — full compile of every changed file.
- `unit-tests` job: `make build-tests` + the DataStructures unit-test plan.
- Push after each logical milestone; fix compile errors before proceeding.

Behavioural verification (reasoned + code-level, mirroring the DoD scenarios):
single-account install/refresh/migration still work (N=1 path unchanged); install with
account A vs B; refresh A vs B apps; correct account auto-selected via `signingAccountID`;
failure isolation (bad creds / expired / removed account / revoked profile affect only
that account's apps).

## Milestones (commit boundaries)

1. CI workflow (done) + docs.
2. Data model v18 + `InstalledApp.signingAccountID`.
3. Keychain per-account storage.
4. `AccountManager`.
5. Context `accountID` + `AuthenticationOperation` per-account auth + credential migration.
6. `InstallAppOperation` signing-account binding + data backfill migration.
7. `AppManager` account-partitioned refresh + aggregate + isolation.
8. Minimal UI (accounts management + app-detail signing account).
9. Build/test hardening via CI until green.
