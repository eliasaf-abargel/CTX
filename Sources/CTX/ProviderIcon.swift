import CTXCore
import SwiftUI

/// Renders a cloud provider's official logo from the app bundle, falling back
/// to a monochrome SF Symbol when the image asset isn't present.
///
/// Drop the official logo files into `Sources/CTX/Resources/` named exactly:
///   aws.png · gcp.png · azure.png   (kubernetes.png reserved for Phase 3)
/// PNG with transparency is preferred; JPEG also works.
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
        if let module = Bundle.safeModule,
           let nsImage = module.image(forResource: assetName) {
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
        // 4. Fallback: try standard build paths
        let buildPath = "/Users/eliasafa/IdeaProjects/CTX/.build/arm64-apple-macosx/debug/CTX_CTX.bundle"
        if let bundle = Bundle(path: buildPath) {
            return bundle
        }
        let buildPathRelease = "/Users/eliasafa/IdeaProjects/CTX/.build/arm64-apple-macosx/release/CTX_CTX.bundle"
        if let bundle = Bundle(path: buildPathRelease) {
            return bundle
        }
        return nil
    }
}
