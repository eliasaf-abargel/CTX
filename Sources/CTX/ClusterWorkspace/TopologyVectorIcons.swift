import SwiftUI

// MARK: - Premium Topological Vector Icons (SVG-style)

struct IngressVectorIcon: View {
    var body: some View {
        ZStack {
            Circle()
                .stroke(LinearGradient(colors: [.orange, .yellow], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1.5)
                .background(Circle().fill(.orange.opacity(0.08)))

            Circle()
                .stroke(.orange.opacity(0.3), lineWidth: 0.75)
                .padding(3)

            Ellipse()
                .stroke(.orange.opacity(0.6), lineWidth: 1)
                .frame(width: 8)

            Rectangle()
                .fill(.orange.opacity(0.6))
                .frame(height: 1)

            Rectangle()
                .fill(.orange.opacity(0.6))
                .frame(width: 1)
        }
        .frame(width: 22, height: 22)
    }
}

struct ServiceVectorIcon: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(LinearGradient(colors: [.blue, .cyan], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1.5)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.blue.opacity(0.08)))

            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height
                let cx = w / 2
                let cy = h / 2

                Path { path in
                    path.addEllipse(in: CGRect(x: cx - 2.5, y: cy - 2.5, width: 5, height: 5))
                    path.move(to: CGPoint(x: cx, y: cy))
                    path.addLine(to: CGPoint(x: cx, y: 4))
                    path.move(to: CGPoint(x: cx, y: cy))
                    path.addLine(to: CGPoint(x: cx - 5.5, y: h - 5))
                    path.move(to: CGPoint(x: cx, y: cy))
                    path.addLine(to: CGPoint(x: cx + 5.5, y: h - 5))
                }
                .stroke(Color.blue, lineWidth: 1.5)

                Circle().fill(Color.blue).frame(width: 3.5, height: 3.5).position(x: cx, y: 4)
                Circle().fill(Color.blue).frame(width: 3.5, height: 3.5).position(x: cx - 5.5, y: h - 5)
                Circle().fill(Color.blue).frame(width: 3.5, height: 3.5).position(x: cx + 5.5, y: h - 5)
            }
            .padding(2)
        }
        .frame(width: 22, height: 22)
    }
}

struct WorkloadVectorIcon: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(LinearGradient(colors: [.purple, .pink], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1.5)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.purple.opacity(0.08)))

            Path { path in
                let w: CGFloat = 16
                let cx: CGFloat = 8

                path.move(to: CGPoint(x: cx, y: 2))
                path.addLine(to: CGPoint(x: 2, y: 5.5))
                path.addLine(to: CGPoint(x: cx, y: 9))
                path.addLine(to: CGPoint(x: w - 2, y: 5.5))
                path.closeSubpath()

                path.move(to: CGPoint(x: 2, y: 5.5))
                path.addLine(to: CGPoint(x: 2, y: 12.5))
                path.addLine(to: CGPoint(x: cx, y: 16))
                path.addLine(to: CGPoint(x: cx, y: 9))
                path.closeSubpath()

                path.move(to: CGPoint(x: w - 2, y: 5.5))
                path.addLine(to: CGPoint(x: w - 2, y: 12.5))
                path.addLine(to: CGPoint(x: cx, y: 16))
                path.addLine(to: CGPoint(x: cx, y: 9))
                path.closeSubpath()
            }
            .stroke(Color.purple, lineWidth: 1.25)
            .padding(3)
        }
        .frame(width: 22, height: 22)
    }
}

struct PodVectorIcon: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(LinearGradient(colors: [.green, .mint], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1.5)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.green.opacity(0.08)))

            Path { path in
                let w: CGFloat = 16
                let cx: CGFloat = 8

                path.move(to: CGPoint(x: cx, y: 1.5))
                path.addLine(to: CGPoint(x: w - 2.5, y: 5))
                path.addLine(to: CGPoint(x: w - 2.5, y: 12))
                path.addLine(to: CGPoint(x: cx, y: 15.5))
                path.addLine(to: CGPoint(x: 2.5, y: 12))
                path.addLine(to: CGPoint(x: 2.5, y: 5))
                path.closeSubpath()
            }
            .stroke(Color.green, lineWidth: 1.25)
            .padding(3)

            Circle()
                .fill(Color.green)
                .frame(width: 4, height: 4)
        }
        .frame(width: 22, height: 22)
    }
}

struct TechBrandIconView: View {
    let name: String

    var brand: (icon: String, color: Color) {
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
        HStack(spacing: 4) {
            Image(systemName: brand.icon)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(brand.color)
            Text(name)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.primary)
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
