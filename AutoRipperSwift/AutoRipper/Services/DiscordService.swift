import Foundation
import os

private let log = Logger(subsystem: "com.autoripper.app", category: "discord")

/// Discord webhook client with single-message-per-job card support.
actor DiscordService {
    private let session = URLSession.shared
    private let config: AppConfig

    init(config: AppConfig = .shared) {
        self.config = config
    }

    private var webhookURL: String { config.discordWebhook }

    // MARK: - Low-level

    func sendEmbed(_ embed: [String: Any]) async -> String? {
        guard !webhookURL.isEmpty, let url = URL(string: "\(webhookURL)?wait=true") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["embeds": [embed]])
        request.timeoutInterval = 10

        do {
            let (data, _) = try await session.data(for: request)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return json["id"] as? String
            }
        } catch {
            log.error("Discord send failed: \(error.localizedDescription)")
        }
        return nil
    }

    func editEmbed(messageId: String, embed: [String: Any]) async {
        guard !webhookURL.isEmpty, !messageId.isEmpty,
              let url = URL(string: "\(webhookURL)/messages/\(messageId)") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["embeds": [embed]])
        request.timeoutInterval = 10

        do {
            _ = try await session.data(for: request)
        } catch {
            log.error("Discord edit failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - Job Card

/// Manages a single Discord embed that updates in-place per job.
class JobCard: @unchecked Sendable {
    private let discName: String
    private let nasEnabled: Bool
    private let discord: DiscordService
    private var messageId: String?
    private var stages: [String: String]
    private var stageDetails: [String: String] = [:]

    private static let stageOrder = ["rip", "encode", "organize", "scrape", "nas"]
    private static let stageLabels = [
        "rip": "Rip", "encode": "Encode", "organize": "Organize",
        "scrape": "Artwork & NFO", "nas": "Copy to NAS",
    ]
    private static let icons = [
        "pending": "⬜", "active": "🔄", "done": "✅", "failed": "❌", "skipped": "⏭️",
    ]

    init(discName: String, nasEnabled: Bool = false, discord: DiscordService = DiscordService()) {
        self.discName = discName
        self.nasEnabled = nasEnabled
        self.discord = discord
        self.stages = [
            "rip": "pending", "encode": "pending", "organize": "pending",
            "scrape": "pending", "nas": nasEnabled ? "pending" : "skipped",
        ]
    }

    func start(_ stage: String, detail: String = "") async {
        stages[stage] = "active"
        if !detail.isEmpty { stageDetails[stage] = detail }
        await sendOrEdit(color: 0x5865F2)
    }

    func finish(_ stage: String, detail: String = "") async {
        stages[stage] = "done"
        if !detail.isEmpty { stageDetails[stage] = detail }
        await sendOrEdit(color: 0x5865F2)
    }

    func fail(_ stage: String, detail: String = "") async {
        stages[stage] = "failed"
        if !detail.isEmpty { stageDetails[stage] = detail }
        await sendOrEdit(color: 0xED4245)
    }

    func skip(_ stage: String) async {
        stages[stage] = "skipped"
        await sendOrEdit(color: 0x5865F2)
    }

    func complete(footer: String = "") async {
        await sendOrEdit(color: 0x57F287, footer: footer)
    }

    // MARK: - Private

    private func buildEmbed(color: Int, footer: String = "") -> [String: Any] {
        var lines: [String] = []
        for key in Self.stageOrder {
            let status = stages[key] ?? "pending"
            let icon = Self.icons[status] ?? "⬜"
            var line = "\(icon)  \(Self.stageLabels[key] ?? key)"
            if let detail = stageDetails[key], !detail.isEmpty {
                line += "  —  \(detail)"
            }
            lines.append(line)
        }
        var embed: [String: Any] = [
            "title": "🎬  \(discName)",
            "description": lines.joined(separator: "\n"),
            "color": color,
        ]
        if !footer.isEmpty {
            embed["footer"] = ["text": footer]
        }
        return embed
    }

    private func sendOrEdit(color: Int, footer: String = "") async {
        let embed = buildEmbed(color: color, footer: footer)
        if let id = messageId {
            await discord.editEmbed(messageId: id, embed: embed)
        } else {
            messageId = await discord.sendEmbed(embed)
        }
    }
}
