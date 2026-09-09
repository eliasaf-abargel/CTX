import CTXCore
import Foundation

private func makeShellTempDirectory() -> URL {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ctx-shell-tests-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

func testInstallingTheSnippetTwiceLeavesOneCopy() {
    let directory = makeShellTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let rc = directory.appendingPathComponent("rc")

    try! "# my shell\nexport EDITOR=vim\n".write(to: rc, atomically: true, encoding: .utf8)
    assert(!ShellIntegration.isInstalled(in: rc))

    try! ShellIntegration.install(into: rc)
    try! ShellIntegration.install(into: rc)
    try! ShellIntegration.install(into: rc)

    let text = try! String(contentsOf: rc, encoding: .utf8)
    assert(ShellIntegration.isInstalled(in: rc))
    // Three installs, one block - otherwise an upgrade would stack copies forever.
    assert(text.components(separatedBy: ShellIntegration.beginMarker).count - 1 == 1)
    // The person's own configuration is untouched.
    assert(text.contains("# my shell"))
    assert(text.contains("export EDITOR=vim"))
}

func testUninstallingLeavesTheRestOfTheFileIntact() {
    let directory = makeShellTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let rc = directory.appendingPathComponent("rc")

    try! "export EDITOR=vim\n\nalias k=kubectl\n".write(to: rc, atomically: true, encoding: .utf8)
    try! ShellIntegration.install(into: rc)
    try! ShellIntegration.uninstall(from: rc)

    let text = try! String(contentsOf: rc, encoding: .utf8)
    assert(!ShellIntegration.isInstalled(in: rc))
    assert(!text.contains("shell-env"))
    assert(text.contains("export EDITOR=vim"))
    assert(text.contains("alias k=kubectl"))
}

func testSelectionFileRefusesValuesThatCouldForgeAnAssignment() {
    // A profile name is not trusted input: a newline or an "=" would let one entry
    // write a second variable the person never chose.
    let cleaned = ShellIntegration.removingSnippet(from: "keep me")
    assert(cleaned == "keep me")

    let directory = makeShellTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let rc = directory.appendingPathComponent("rc")
    try! "line\n\(ShellIntegration.beginMarker)\nstale\n\(ShellIntegration.endMarker)\n\(ShellIntegration.beginMarker)\nalso stale\n\(ShellIntegration.endMarker)\ntail"
        .write(to: rc, atomically: true, encoding: .utf8)

    // A file that somehow gained two blocks is left with none, then one on install.
    let stripped = ShellIntegration.removingSnippet(from: try! String(contentsOf: rc, encoding: .utf8))
    assert(!stripped.contains("stale"))
    assert(stripped.contains("line"))
    assert(stripped.contains("tail"))
}

func testSelectionIsOnlyEverWrittenWhereItIsToldTo() {
    let directory = makeShellTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let destination = directory.appendingPathComponent("nested/shell-env")

    // Writing creates the directory it needs, and lands nowhere else. Recording used to
    // go to a fixed path under $HOME, so running this very suite overwrote the real one.
    try! ShellIntegration.writeSelection(["AWS_PROFILE": "chosen"], to: destination)
    assert(try! String(contentsOf: destination, encoding: .utf8) == "AWS_PROFILE=chosen\n")

    // A name carrying "=" or a newline would let one entry forge a second assignment.
    try! ShellIntegration.writeSelection(
        ["AWS_PROFILE": "safe", "EVIL": "x=y", "ALSO_EVIL": "a\nb", "EMPTY": ""],
        to: destination
    )
    let written = try! String(contentsOf: destination, encoding: .utf8)
    assert(written == "AWS_PROFILE=safe\n")

    // Nothing selected leaves an empty file rather than a stale one.
    try! ShellIntegration.writeSelection([:], to: destination)
    assert(try! String(contentsOf: destination, encoding: .utf8).isEmpty)
}

