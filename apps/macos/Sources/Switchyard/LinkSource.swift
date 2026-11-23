import SwitchyardCore

extension LinkSource {
    @MainActor var label: String {
        switch self {
        case .app(let bundleID, let tool):
            let name = AppCatalog.name(for: bundleID)
            return tool.map { "\(name) via \($0)" } ?? name
        case .tool(let name): return name
        case .exited: return "Command-line tool"
        case .unknown: return "Unknown app"
        }
    }
}
