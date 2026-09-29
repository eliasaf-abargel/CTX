import SwiftUI

// MARK: - Premium Topological Vector Icons (SVG-style)

struct TechBrandIconView: View, Equatable {
    let name: String

    static func == (lhs: TechBrandIconView, rhs: TechBrandIconView) -> Bool {
        lhs.name == rhs.name
    }

    /// Resolved once per body. It was read four times — icon, foreground, background
    /// and stroke — and each read re-ran `lowercased()` plus up to twenty-five
    /// substring searches, so a table cell cost about a hundred searches per render.
    static func brand(for name: String) -> (icon: String, color: Color) {
        let lower = name.lowercased()
        if lower.contains("redis") { return ("cylinder.fill", .red) }
        if lower.contains("postgre") || lower.contains("sql") || lower.contains("db") || lower.contains("mongo") { return ("database.fill", .blue) }
        if lower.contains("nginx") || lower.contains("ingress") || lower.contains("front") || lower.contains("web") { return ("network", .green) }
        if lower.contains("kafka") || lower.contains("event") || lower.contains("mq") || lower.contains("pub") { return ("bolt.horizontal.fill", .orange) }
        if lower.contains("argo") || lower.contains("flux") || lower.contains("gitops") || lower.contains("deploy") { return ("arrow.triangle.pull", .indigo) }
        if lower.contains("prom") || lower.contains("graf") || lower.contains("metric") || lower.contains("monitor") { return ("chart.xyaxis.line", .orange) }
        if lower.contains("auth") || lower.contains("sec") || lower.contains("key") { return ("lock.shield.fill", .purple) }
        if lower.contains("pay") || lower.contains("bill") || lower.contains("checkout") { return ("creditcard.fill", .mint) }
        if lower.contains("api") || lower.contains("service") || lower.contains("app") { return ("gearshape.fill", .cyan) }
        return ("cube.fill", .blue)
    }

    var body: some View {
        let brand = Self.brand(for: name)
        return HStack(spacing: 4) {
            Image(systemName: brand.icon)
                .font(.system(.caption2, weight: .bold))
                .foregroundStyle(brand.color)
            Text(name)
                .font(.system(.caption2, design: .monospaced, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(brand.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(brand.color.opacity(0.3), lineWidth: 1)
        }
    }
}
