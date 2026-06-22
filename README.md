# CTX ☁️

> **A native macOS Cloud Context Switcher** designed for developers who manage multiple cloud environments. 

CTX resides directly in your macOS Menu Bar, providing a native, lightweight, and fast experience to authenticate, verify, and switch between multiple cloud profiles. Currently supports **AWS SSO**, with **GCP** and **Azure** support on the horizon.

---

## Key Features 🚀

- **Native macOS Experience:** Built using Swift and SwiftUI, styled with clean layouts and smooth transitions that align with macOS system design.
- **Menu Bar & Sidebar Interface:** Access all profiles via a compact dropdown in the system status bar, or open the detailed sidebar interface.
- **Robust Path & CLI Resolution:** Directly locates Homebrew-installed binaries (`aws`) and operates correctly even when launched through macOS LaunchServices.
- **Single-Instance Reopening:** Correctly reactivates the active window when double-clicking the Dock/desktop icon instead of creating duplicate processes.
- **Security Backups:** Automatically makes timestamped backups (e.g. `config.ctx-backup-*`) of your `~/.aws/config` file before applying any modifications.
- **Secure Credentials Handling:** Exports and writes temporary STS credentials to `~/.aws/credentials` automatically after verification without storing static secrets.
- **Session Expiration Alerts:** Monitors local AWS token caches and pops up system alerts or banners when your active session is about to expire.

---

## Visual Design & Interaction 🎨

- **Sleek Action Buttons:** Key actions like *Edit*, *Duplicate*, *Move*, and *Delete* are represented as neat icon-only buttons with hover tooltips (`.help`), maintaining a clean and premium interface.
- **Dynamic Folders:** Group profiles into environments (e.g. *Production*, *Staging*, *Admin*). Toggle folder expansion by clicking anywhere on the folder row.
- **Status Indicators:** Clear indicators show whether a profile is connected (🟢), needs login (🟠), or is misconfigured.

---

## Architecture 🛠️

The project is structured as a Swift Package containing three main targets:
- **`CTXCore`:** The logic engine. Parsers/writers for configuration files, command runners, session expirations, and state management.
- **`CTX`:** The main SwiftUI macOS application bundle containing the Menu Bar interface, main WindowGroup, and settings window.
- **`CTXCheck`:** A lightweight validation target used to verify system logic.

---

## Installation 🛠️

To install CTX to your `/Applications` folder using a single terminal command without downloading or cloning this repository:

### Standard Installation (GitHub Releases)
```bash
curl -fsSL https://raw.githubusercontent.com/eliasaf-abargel/CTX/main/script/install.sh | bash
```

### Private Installation (e.g. JFrog Fly / Custom Registry)
If your organization distributes CTX internally via JFrog Fly or Artifactory, define the custom registry URL (and credentials if needed) before running the command:
```bash
export CTX_DOWNLOAD_URL="https://your-fly-subdomain/generic-local/ctx/0.1.0/CTX.app.zip"
# export CTX_REPO_CREDS="username:token" # If authentication is required
curl -fsSL https://raw.githubusercontent.com/eliasaf-abargel/CTX/main/script/install.sh | bash
```

---

## Development 💻

### Prerequisites
- macOS 14.0+
- Xcode 15.0+ or Swift 6.0+
- AWS CLI (`aws`) installed (e.g. via Homebrew `/opt/homebrew/bin/aws`)

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

## Security Guidelines 🔒

- **No Secrets Committed:** Do not commit `~/.aws/config`, token caches, or credentials.
- **Automatic Backups:** Backup files are created locally under `~/.aws/` during changes and are excluded from Git.
- **Ad-hoc Signing:** The local build script signs the application bundle ad-hoc. For distribution outside your Mac, compile with a valid Developer ID certificate.
