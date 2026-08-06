import SwiftUI
import CTXCore

struct AWSRegionPickerView: View {
    @Binding var selection: String
    var label: String

    init(selection: Binding<String>, label: String = "AWS Region:") {
        self._selection = selection
        self.label = label
    }

    private var currentRegionDisplayName: String {
        if let found = AWSRegion.allCases.first(where: { $0.id == selection }) {
            return found.displayName
        }
        return selection.isEmpty ? "Select AWS Region..." : selection
    }

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Menu {
                Section("Popular Regions") {
                    Button("us-east-1 (N. Virginia)") { selection = "us-east-1" }
                    Button("us-west-2 (Oregon)") { selection = "us-west-2" }
                    Button("eu-west-1 (Ireland)") { selection = "eu-west-1" }
                    Button("eu-central-1 (Frankfurt)") { selection = "eu-central-1" }
                    Button("ap-southeast-1 (Singapore)") { selection = "ap-southeast-1" }
                }

                Divider()

                ForEach(AWSRegionGroup.allCases) { group in
                    Menu(group.rawValue) {
                        ForEach(group.regions) { region in
                            Button(region.displayName) {
                                selection = region.id
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(currentRegionDisplayName)
                        .font(.callout)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .menuStyle(.borderlessButton)
        }
    }
}
