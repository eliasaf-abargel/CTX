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
        if let nsImage = Bundle.module.image(forResource: assetName) {
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
