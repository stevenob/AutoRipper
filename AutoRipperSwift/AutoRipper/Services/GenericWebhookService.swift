import Foundation
import os

private let log = Logger(subsystem: "com.autoripper.app", category: "webhook")

/// Generic outbound webhook — POSTs a JSON payload to the configured URL on
/// job complete/fail events. Designed to plug into Home Assistant, n8n,
/// Slack/Mattermost incoming webhooks, custom dashboards, etc.
///
/// Discord is NOT routed through this — the existing DiscordService produces
/// its own rich embed cards. Generic webhooks are the boring "give me JSON"
/// alternative for everything else.
struct GenericWebhookService {
    let config: AppConfig

    init(config: AppConfig = .shared) {
        self.config = config
    }

    /// Fire a `job.completed` event for a successfully-finished job.
    func notifyComplete(_ job: Job) async {
        await send(event: "job.completed", job: job)
    }

    /// Fire a `job.failed` event with the error message included.
    func notifyFailed(_ job: Job) async {
        await send(event: "job.failed", job: job)
    }

    /// Fire a generic test payload — used by the Settings "Test" button.
    func sendTest() async -> Result<Void, Error> {
        let payload: [String: Any] = [
            "event": "test",
            "message": "AutoRipper webhook test",
            "version": UpdateService.currentVersion,
            "timestamp": Self.iso8601(Date()),
        ]
        return await post(payload: payload)
    }

    // MARK: - Private

    private func send(event: String, job: Job) async {
        let payload = Self.payload(event: event, job: job)
        switch await post(payload: payload) {
        case .success:
            log.info("\(event, privacy: .public) sent for \(job.discName, privacy: .public)")
        case .failure(let error):
            log.warning("\(event, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func post(payload: [String: Any]) async -> Result<Void, Error> {
        let urlStr = config.genericWebhookURL.trimmingCharacters(in: .whitespaces)
        guard !urlStr.isEmpty else { return .success(()) }
        guard let url = URL(string: urlStr) else {
            return .failure(NSError(domain: "GenericWebhook", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid URL"]))
        }
        do {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("AutoRipper/\(UpdateService.currentVersion)", forHTTPHeaderField: "User-Agent")
            req.timeoutInterval = 10
            req.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            let (_, response) = try await URLSession.shared.data(for: req)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                return .failure(NSError(domain: "GenericWebhook", code: http.statusCode,
                                        userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"]))
            }
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    /// Build a complete JSON payload for a job event. Internal/static so it can
    /// be unit-tested without a network roundtrip.
    static func payload(event: String, job: Job) -> [String: Any] {
        var p: [String: Any] = [
            "event": event,
            "id": job.id,
            "discName": job.discName,
            "status": job.status.rawValue,
            "intent": job.intent.rawValue,
            "rippedFile": job.rippedFile.path,
            "createdAt": iso8601(job.createdAt),
            "ripElapsed": job.ripElapsed,
            "encodeElapsed": job.encodeElapsed,
            "organizeElapsed": job.organizeElapsed,
            "scrapeElapsed": job.scrapeElapsed,
            "nasElapsed": job.nasElapsed,
        ]
        if let m = job.mediaResult {
            p["title"] = m.title
            p["year"] = m.year as Any? ?? NSNull()
            p["mediaType"] = m.mediaType
            p["tmdbId"] = m.tmdbId
        }
        if let edition = job.editionLabel { p["edition"] = edition }
        if let s = job.seasonNumber { p["season"] = s }
        if let e = job.episodeNumber { p["episode"] = e }
        if let et = job.episodeTitle { p["episodeTitle"] = et }
        if let f = job.encodedFile { p["encodedFile"] = f.path }
        if let f = job.organizedFile { p["organizedFile"] = f.path }
        if !job.error.isEmpty { p["error"] = job.error }
        if let finished = job.finishedAt { p["finishedAt"] = iso8601(finished) }
        if !job.resolution.isEmpty { p["resolution"] = job.resolution }
        return p
    }

    static func iso8601(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }
}
