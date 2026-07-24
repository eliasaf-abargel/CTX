import CTXCore
import SwiftUI

public struct CTXResourceLimitsGauge: View {
    let title: String
    let request: String
    let limit: String
    let usage: String
    let percentage: Double // 0.0 to 1.0
    let tint: Color

    public init(title: String, request: String, limit: String, usage: String, percentage: Double, tint: Color = .blue) {
        self.title = title
        self.request = request
        self.limit = limit
        self.usage = usage
        self.percentage = min(max(percentage, 0.0), 1.0)
        self.tint = tint
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title.uppercased())
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Usage: \(usage) / Limit: \(limit)")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.primary)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color.primary.opacity(0.1))

                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(tint)
                        .frame(width: geo.size.width * CGFloat(percentage))
                }
            }
            .frame(height: 6)

            HStack {
                Text("Req: \(request)")
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(percentage * 100))% of limit")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(percentage > 0.85 ? Color.red : tint)
            }
        }
        .padding(8)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}
