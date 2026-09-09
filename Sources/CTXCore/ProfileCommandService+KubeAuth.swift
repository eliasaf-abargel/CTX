import Foundation

extension ProfileCommandService {
    public static func explicitAWSProfile(in data: Data) -> String? {
        guard let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let users = config["users"] as? [[String: Any]], users.count == 1,
              let user = users.first?["user"] as? [String: Any],
              let plugin = user["exec"] as? [String: Any],
              let command = plugin["command"] as? String,
              URL(fileURLWithPath: command).lastPathComponent == "aws" else { return nil }
        let args = plugin["args"] as? [String] ?? []
        for (index, arg) in args.enumerated() {
            if arg == "--profile", index + 1 < args.count, !args[index + 1].hasPrefix("-") {
                return args[index + 1].isEmpty ? nil : args[index + 1]
            }
            if arg.hasPrefix("--profile=") {
                let value = String(arg.dropFirst("--profile=".count))
                return value.isEmpty ? nil : value
            }
        }
        let environment = plugin["env"] as? [[String: String]] ?? []
        let value = environment.first { $0["name"] == "AWS_PROFILE" }?["value"]
        return value?.isEmpty == false ? value : nil
    }
}
