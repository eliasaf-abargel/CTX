import CTXCore
import Foundation

enum ResourceExportFormatter {
    static func jsonSingle(_ list: KubernetesResourceList) throws -> Data {
        let rows = list.rows.map { row in row.cells.merging(["id": row.id]) { existing, _ in existing } }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(rows)
    }

    static func jsonCombined(_ lists: [ClusterWorkspaceSection: KubernetesResourceList]) throws -> Data {
        var combinedDict: [String: [[String: String]]] = [:]
        for (section, list) in lists {
            let rows = list.rows.map { row in row.cells.merging(["id": row.id]) { existing, _ in existing } }
            combinedDict[section.rawValue.lowercased()] = rows
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(combinedDict)
    }

    static func csv(_ list: KubernetesResourceList) -> Data {
        var lines = [list.columns.map(escape).joined(separator: ",")]
        for row in list.rows {
            lines.append(list.columns.map { escape(row.cells[$0] ?? "") }.joined(separator: ","))
        }
        return lines.joined(separator: "\n").data(using: .utf8) ?? Data()
    }

    static func html(_ lists: [ClusterWorkspaceSection: KubernetesResourceList]) -> Data {
        let sortedLists = lists.sorted { $0.key.rawValue < $1.key.rawValue }

        var tabButtonsHTML = ""
        var tabContentsHTML = ""

        for (index, pair) in sortedLists.enumerated() {
            let section = pair.key
            let list = pair.value
            let activeClass = index == 0 ? "active" : ""

            tabButtonsHTML += """
            <button class="tab-btn \(activeClass)" onclick="showTab(event, '\(section.rawValue)')">
                \(section.rawValue) (\(list.rows.count))
            </button>
            """

            var tableRowsHTML = ""
            var headerCellsHTML = ""
            for col in list.columns {
                headerCellsHTML += "<th>\(col)</th>"
            }

            for row in list.rows {
                var rowCellsHTML = ""
                for col in list.columns {
                    let cellVal = row.cells[col] ?? ""
                    rowCellsHTML += "<td>\(cellVal)</td>"
                }
                tableRowsHTML += "<tr>\(rowCellsHTML)</tr>"
            }

            tabContentsHTML += """
            <div id="tab-\(section.rawValue)" class="tab-content \(activeClass)">
                <h2>\(section.rawValue)</h2>
                <p class="meta">Total items: \(list.rows.count) · Exported from CTX</p>
                <div style="overflow-x: auto;">
                    <table>
                        <thead>
                            <tr>\(headerCellsHTML)</tr>
                        </thead>
                        <tbody>
                            \(tableRowsHTML)
                        </tbody>
                    </table>
                </div>
            </div>
            """
        }

        let htmlString = """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="utf-8">
            <title>CTX Kubernetes Export Report</title>
            <style>
                body {
                    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
                    background-color: #121212;
                    color: #e0e0e0;
                    margin: 0;
                    padding: 24px;
                }
                .container {
                    max-width: 1200px;
                    margin: 0 auto;
                    background: #1e1e1e;
                    border-radius: 12px;
                    padding: 24px;
                    box-shadow: 0 8px 32px rgba(0,0,0,0.5);
                    border: 1px solid #2d2d2d;
                }
                h1 {
                    font-size: 22px;
                    font-weight: 700;
                    margin-top: 0;
                    margin-bottom: 4px;
                    color: #ffffff;
                }
                .subtitle {
                    font-size: 13px;
                    color: #888888;
                    margin-bottom: 24px;
                }
                .tabs-header {
                    display: flex;
                    gap: 8px;
                    border-bottom: 1px solid #2d2d2d;
                    padding-bottom: 8px;
                    margin-bottom: 24px;
                    overflow-x: auto;
                }
                .tab-btn {
                    background: none;
                    border: none;
                    color: #888888;
                    padding: 8px 16px;
                    font-size: 13px;
                    font-weight: 600;
                    cursor: pointer;
                    border-radius: 6px;
                    transition: all 0.15s ease;
                }
                .tab-btn:hover {
                    background: rgba(255,255,255,0.04);
                    color: #ffffff;
                }
                .tab-btn.active {
                    background: #007aff;
                    color: #ffffff;
                }
                .tab-content {
                    display: none;
                }
                .tab-content.active {
                    display: block;
                }
                h2 {
                    font-size: 18px;
                    margin-top: 0;
                    color: #ffffff;
                }
                .meta {
                    font-size: 12px;
                    color: #888888;
                    margin-bottom: 16px;
                }
                table {
                    width: 100%;
                    border-collapse: collapse;
                    font-size: 12px;
                }
                th, td {
                    padding: 10px 12px;
                    text-align: left;
                    border-bottom: 1px solid #2d2d2d;
                }
                th {
                    background-color: #262626;
                    color: #ffffff;
                    font-weight: 600;
                }
                tr:hover td {
                    background-color: rgba(255,255,255,0.02);
                }
            </style>
            <script>
                function showTab(event, sectionName) {
                    var contents = document.getElementsByClassName('tab-content');
                    for (var i = 0; i < contents.length; i++) {
                        contents[i].classList.remove('active');
                    }
                    var buttons = document.getElementsByClassName('tab-btn');
                    for (var i = 0; i < buttons.length; i++) {
                        buttons[i].classList.remove('active');
                    }
                    document.getElementById('tab-' + sectionName).classList.add('active');
                    event.currentTarget.classList.add('active');
                }
            </script>
        </head>
        <body>
            <div class="container">
                <h1>CTX Kubernetes Cluster Export Report</h1>
                <div class="subtitle">Generated dynamically from active cluster context</div>
                <div class="tabs-header">
                    \(tabButtonsHTML)
                </div>
                \(tabContentsHTML)
            </div>
        </body>
        </html>
        """
        return htmlString.data(using: .utf8) ?? Data()
    }

    private static func escape(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") else { return value }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    static func suggestedFileName(clusterName: String, sectionName: String? = nil, fileExtension: String) -> String {
        let cleanCluster = clusterName.lowercased()
            .replacingOccurrences(of: "[^a-z0-9_-]", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let prefix = cleanCluster.isEmpty ? "ctx-export" : "ctx-report-\(cleanCluster)"
        let sectionPart = sectionName.map { "-\($0.lowercased())" } ?? ""
        let dateStr = Date().formatted(.iso8601.year().month().day())
        return "\(prefix)\(sectionPart)-\(dateStr).\(fileExtension)"
    }
}
