import Combine
import Foundation
#if canImport(AppKit)
import AppKit
#endif

extension ProfileStore {
    public func checkForUpdates(manual: Bool = false) {
        guard !isCheckingForUpdates else { return }
        isCheckingForUpdates = true
        if manual {
            updateCheckMessage = "Checking for updates..."
        }

        Task {
            do {
                let result = try await updateService.checkForUpdates()

                await MainActor.run {
                    self.isCheckingForUpdates = false
                    if result.isUpdateAvailable {
                        let wasAvailable = self.updateAvailable
                        self.updateAvailable = true
                        self.latestVersionString = result.tagName
                        self.updateCheckMessage = "Update available: \(result.tagName)"
                        if !wasAvailable {
                            self.triggerUpdateNotification(version: result.tagName)
                        }
                        if manual {
                            self.showUpdateAlert(version: result.tagName)
                        }
                    } else {
                        self.updateAvailable = false
                        self.updateCheckMessage = "CTX is up to date."
                        if manual {
                            self.showUpToDateAlert(currentVersion: result.currentVersion)
                        }
                    }
                }
            } catch {
                self.isCheckingForUpdates = false
                self.updateCheckMessage = "Could not check for updates right now. Try again later."
                try? LocalDiagnostics.shared.record(step: "update_check", outcome: "unavailable")
            }
        }
    }

    internal func showUpToDateAlert(currentVersion: String) {
        #if canImport(AppKit)
        let alert = NSAlert()
        alert.messageText = "You're up to date!"
        alert.informativeText = "CTX \(currentVersion) is currently the newest version available."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
        #endif
    }

    internal func showUpdateAlert(version: String) {
        #if canImport(AppKit)
        let alert = NSAlert()
        alert.messageText = "Update Available!"
        alert.informativeText = "A new version (\(version)) of CTX is available. Would you like to install it now?"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Install Update")
        alert.addButton(withTitle: "Later")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            self.installUpdate()
        }
        #endif
    }

    internal func triggerUpdateNotification(version: String) {
        notifications.sendUpdateAvailable(version: version)
    }

    public func installUpdate() {
        guard !latestVersionString.isEmpty else { return }

        isUpdating = true
        let tagName = latestVersionString

        lastMessage = "Downloading CTX update \(tagName)..."

        Task {
            do {
                await MainActor.run {
                    self.lastMessage = "Installing update..."
                }
                try await updateService.install(tagName: tagName, targetBundlePath: Bundle.main.bundlePath)

                #if canImport(AppKit)
                await MainActor.run {
                    NSApplication.shared.terminate(nil)
                }
                #else
                exit(0)
                #endif
            } catch {
                await MainActor.run {
                    self.isUpdating = false
                    self.lastMessage = "Update failed: \(error.localizedDescription)"
                }
            }
        }
    }
}
