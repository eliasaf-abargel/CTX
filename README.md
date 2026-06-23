<p align="center">
  <img src="Resources/CTXIcon.svg" width="120" height="120" alt="CTX Logo" />
</p>

<h1 align="center">CTX</h1>

<p align="center">
  <strong>A lightweight, native macOS Cloud Context Switcher</strong>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS%2014.0%2B-blue?style=flat-square" alt="Platform" />
  <img src="https://img.shields.io/badge/language-Swift%206-orange?style=flat-square" alt="Language" />
  <img src="https://img.shields.io/badge/license-MIT-green?style=flat-square" alt="License" />
</p>

---

CTX resides directly in your macOS Menu Bar, providing a native, lightweight, and fast experience to authenticate, verify, and switch between multiple cloud profiles. Fully supports **AWS SSO** and **Google Cloud Platform (GCP)**.

Designed for developers and DevOps engineers who manage complex multi-account environments and need a seamless, keyboard-friendly way to swap contexts.

---

## Key Features 🚀

- **Native macOS Experience:** Built using Swift and SwiftUI, styled with clean layouts and smooth transitions that align with macOS system design.
- **Multi-Cloud Support:** Authenticate and switch both AWS and GCP profiles concurrently.
- **Menu Bar & Sidebar Interface:** Access all profiles via a compact dropdown in the system status bar, or open the detailed sidebar interface.
- **Robust Path & CLI Resolution:** Directly locates Homebrew-installed binaries (`aws`, `gcloud`) and operates correctly even when launched through macOS LaunchServices.
- **Single-Instance Reopening:** Correctly reactivates the active window when double-clicking the Dock/desktop icon instead of creating duplicate processes.
- **Dynamic Folders:** Group profiles into environments (e.g. *Production*, *Staging*, *Admin*). Toggle folder expansion by clicking anywhere on the folder row.
- **Complete Folder Control:** Delete built-in or custom folders easily from the UI to keep your workspace decluttered.
- **Secure Credentials Handling:** Exports and writes temporary AWS STS credentials and switches active gcloud configurations safely without storing static secrets.
- **Session Expiration Alerts:** Monitors local AWS token caches and pops up system alerts or banners when your active session is about to expire.

---

## Installation 🛠️

To install CTX to your `/Applications` folder using a single terminal command:

### Option 1: Homebrew Cask (Recommended)
Add the tap and install the Cask:
```bash
brew install --cask eliasaf-abargel/tap/ctx
```

### Option 2: Standard Installation Script
```bash
curl -fsSL https://raw.githubusercontent.com/eliasaf-abargel/CTX/main/script/install.sh | bash
```

---

## Development 💻

### Prerequisites
- macOS 14.0+
- Xcode 15.0+ or Swift 6.0+
- AWS CLI (`aws`) and Google Cloud SDK (`gcloud`) installed (e.g. via Homebrew)

### Run in Development
To build, sign, and launch the application in development:
```bash
./script/build_and_run.sh run
```

Other modes:
- `./script/build_and_run.sh logs` — Opens the app and starts streaming system logs.
- `./script/build_and_run.sh verify` — Verifies the app is running.

### Run Verification Tests
```bash
swift run CTXCheck
```

---

## Security & Privacy 🔒

- **Local & Private:** CTX does not store, transmit, or share your credentials or profiles. All operations happen entirely offline on your local machine.
- **No Secrets Committed:** Configs, token caches, and active credentials remain safe within your home directory (`~/.aws/` and `~/.config/gcloud/`) and are excluded from Git.
- **Automatic Backups:** Backup files are created locally during changes and are excluded from Git.
- **Ad-hoc Signing:** The local build script signs the application bundle ad-hoc. For distribution outside your Mac, compile with a valid Developer ID certificate.

---

## Contact & Support 📬

Developed by **Eliasaf Abargel**  
Email: [eliasafabargel@gmail.com](mailto:eliasafabargel@gmail.com)
