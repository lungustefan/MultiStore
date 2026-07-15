# MultiStore

> A **multi-account** fork of [SideStore](https://github.com/SideStore/SideStore) — sideload and refresh apps across **several Apple IDs at once**, from one app.

[![License: AGPL v3](https://img.shields.io/badge/License-AGPL%20v3-blue.svg)](https://www.gnu.org/licenses/agpl-3.0)
[![Fork of SideStore](https://img.shields.io/badge/fork%20of-SideStore-6f42c1.svg)](https://github.com/SideStore/SideStore)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](https://makeapullrequest.com)

MultiStore is a fork of SideStore that removes its single-Apple-ID limitation. You can add **multiple Apple accounts**, and every installed app **permanently remembers which account signed it** — so refreshes always use the correct account, and a problem with one account (expired session, revoked certificate, hit app limit) only affects *that account's* apps. The rest keep refreshing.

It installs under its own identity (**MultiStore**, `com.SideStore.MultiStore`), so it can live **side-by-side with a normal SideStore install** without conflicts.

Everything SideStore does still applies — untethered sideloading with just your Apple ID, on-device resigning via a [custom VPN](https://github.com/SideStore/em_proxy) + [minimuxer](https://github.com/SideStore/minimuxer), and automatic background refresh to beat the 7-day expiry. MultiStore only generalizes the *account* layer on top of that.

## Why multiple accounts?

A free Apple ID is limited to **3 active apps** and a **7-day** signing certificate. With several accounts you effectively get **more total app slots and staggered expirations**, all managed from a single app — instead of juggling separate installs.

## What's different from SideStore

- **Multiple Apple Developer accounts** authenticated simultaneously, with fully isolated sessions, certificates, teams and credentials.
- **Permanent app → account binding** — each `InstalledApp` stores a `signingAccountID`; refreshes are **partitioned per account** and run independently.
- **Failure isolation** — one account failing never stops the others from refreshing.
- **Automatic migration** — existing single-account users are upgraded transparently (credentials re-homed, existing apps stamped with their account), no data loss.
- **Minimal account UI** — add / remove / view accounts and their status in Settings, set a default account, and change any app's signing account.
- **Coexists with SideStore** — distinct bundle identifier, display name, keychain namespace and app group.

Deep dives:
- [`docs/multi-account/ARCHITECTURE.md`](./docs/multi-account/ARCHITECTURE.md) — how SideStore's single-account assumptions were analyzed.
- [`docs/multi-account/PLAN.md`](./docs/multi-account/PLAN.md) — the implementation plan, data-model change and migration strategy.

## Requirements

- macOS with **Xcode 16+** (the project uses file-system-synchronized groups)
- **iOS 15+** target device
- See [CONTRIBUTING.md](./CONTRIBUTING.md) for the full local build setup

## Building & CI

The app can only be built on macOS. The GitHub Actions workflow
[`.github/workflows/multi-account-ci.yml`](./.github/workflows/multi-account-ci.yml) builds the archive
(no signing required) and uploads an installable `SideStore-multi-account.ipa` artifact. Grab the IPA
from the latest green run under the repo's **Actions** tab.

## Installing on your device

The CI IPA is unsigned, so you sideload it with **your own Apple ID** (which re-signs it):

1. Download `SideStore-multi-account.ipa` from the latest green Actions run and unzip it.
2. Sideload with **[Sideloadly](https://sideloadly.io)** or **[AltServer](https://altstore.io)** using your Apple ID.
3. Complete the on-device setup (import a **pairing file**, enable the **VPN** and **Developer Mode**) — the steps are identical to SideStore: see the [SideStore docs](https://docs.sidestore.io).

It appears as **MultiStore** on your Home Screen, alongside any existing SideStore.

> Tip: when updating, re-sideload **over** the existing app with the **same** Apple ID — don't delete it first — so your added accounts and app data are preserved.

## Using multiple accounts

1. **Settings → tap your account (ACCOUNT section)** → **`+` Add Account** and sign in with another Apple ID.
2. New installs are signed with your **default** account; each app then refreshes with the account that signed it.
3. To move an app to a different account: open an account → **Manage Signed Apps** → pick the app → choose another account (it re-signs it).

## Notes & known quirks

- **It still calls itself "SideStore" internally.** Only the Home Screen name and bundle identifier are "MultiStore" (`com.SideStore.MultiStore`). The Xcode scheme, build artifacts (`SideStore.ipa` / `SideStore.app`), the internal product name and various log lines still say "SideStore" — this is intentional, so the build tooling and upstream compatibility stay intact.
- **"Re-sign / rebase signing key" prompt during Refresh All — you can safely refuse it.** If you run *Refresh All* while your **default account is not the account that signed MultiStore itself**, MultiStore may warn that its own signing certificate doesn't match and offer to re-sign ("rebase") its key. **Decline it.** It's only a warning about the *MultiStore app's own* certificate — every other app is still refreshed and re-signed with its own correct account/key, as intended by the per-account design. To avoid the prompt entirely, keep the account that signed MultiStore as your default (or refresh each account's apps from its own entry in the accounts screen).

## Credits & acknowledgements

MultiStore stands entirely on the shoulders of these projects:

- **[SideStore](https://github.com/SideStore/SideStore)** — the base this fork is built on.
- **[AltStore](https://github.com/rileytestut/AltStore)** by Riley Testut — which SideStore itself forked.
- [em_proxy](https://github.com/SideStore/em_proxy), [minimuxer](https://github.com/SideStore/minimuxer), [AltSign](https://github.com/SideStore/AltSign), [Jitterbug](https://github.com/osy/Jitterbug), and [Roxas](https://github.com/rileytestut/roxas).

The multi-account layer is the only substantive addition here; all sideloading/refresh/VPN machinery is SideStore's work.

## Contributing

Contributions are welcome! Please see [CONTRIBUTING.md](./CONTRIBUTING.md).

## License

This project is licensed under the **AGPLv3 license**, inherited from SideStore. See [LICENSE](./LICENSE).
