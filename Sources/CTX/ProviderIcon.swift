import CTXCore
import SwiftUI

/// Renders a cloud provider's official logo from the app bundle, falling back
/// to a monochrome SF Symbol when the image asset isn't present.
///
/// Drop the official logo files into `Sources/CTX/Resources/` named exactly:
///   aws.svg · gcp.svg · azure.svg · kubernetes.svg
struct ProviderIcon: View {
    let provider: CloudProvider
    var size: CGFloat = 18
    /// Tint used only for the SF Symbol fallback (logos keep their own colors).
    var fallbackTint: Color? = nil

    private var assetName: String {
        switch provider {
        case .aws: "aws"
        case .gcp: "gcp"
        case .azure: "azure"
        case .kubernetes: "kubernetes"
        }
    }

    var body: some View {
        // We use Bundle.safeModule exclusively to prevent Bundle.module crashes
        // when the compiled app runs outside standard SwiftPM environment contexts.
        if let bundle = Bundle.safeModule,
           let url = bundle.url(forResource: assetName, withExtension: "svg"),
           let nsImage = NSImage(contentsOf: url) {
            Image(nsImage: nsImage)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        } else {
            Image(systemName: provider.systemImage + ".fill")
                .font(.system(size: size))
                .foregroundStyle(fallbackTint ?? .secondary)
        }
    }
}

extension Bundle {
    static var safeModule: Bundle? {
        // 1. Look for the resource bundle inside the main bundle's Resources directory (macOS app standard)
        if let bundleURL = Bundle.main.resourceURL?.appendingPathComponent("CTX_CTX.bundle"),
           let bundle = Bundle(url: bundleURL) {
            return bundle
        }
        // 2. Look for it directly inside the main bundle (flat)
        if let bundleURL = Bundle.main.bundleURL.appendingPathComponent("CTX_CTX.bundle") as URL?,
           let bundle = Bundle(url: bundleURL) {
            return bundle
        }
        // 3. Look for it relative to the executable (command line tool style)
        if let execURL = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("CTX_CTX.bundle"),
           let bundle = Bundle(url: execURL) {
            return bundle
        }
        // 4. Fallback: try to locate the bundle relative to the Swift build directory
        //    Works on any machine regardless of username or project path.
        if let execURL = Bundle.main.executableURL {
            // .build/<arch>/debug or .build/<arch>/release sibling to the executable
            let archDir = execURL.deletingLastPathComponent()
            for bundleName in ["CTX_CTX.bundle"] {
                let candidate = archDir.appendingPathComponent(bundleName)
                if let bundle = Bundle(url: candidate) {
                    return bundle
                }
            }
        }
        return nil
    }
}
