import AgenticFortressCore
import Foundation

struct ProviderDashboardLink: Equatable {
    var title: String
    var url: URL
}

enum ProviderDashboardResolver {
    static func link(for profile: ProxyProfileSummary) -> ProviderDashboardLink? {
        let name = profile.name.lowercased()
        let host = profile.upstreamOrigin.host?.lowercased() ?? ""

        if name.contains("openai") || host == "api.openai.com" {
            return ProviderDashboardLink(
                title: "Open OpenAI Dashboard",
                url: URL(string: "https://platform.openai.com/api-keys")!
            )
        }

        if name.contains("anthropic") || host == "api.anthropic.com" {
            return ProviderDashboardLink(
                title: "Open Anthropic Console",
                url: URL(string: "https://console.anthropic.com/settings/keys")!
            )
        }

        return nil
    }
}
