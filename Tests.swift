import Foundation

@main
struct Tests {
    static func main() throws {
        func decode(_ json: String) throws -> QuotaResponse {
            try JSONDecoder().decode(QuotaResponse.self, from: Data(json.utf8))
        }
        let current = try decode(#"{"rateLimits":{"primary":{"usedPercent":99}},"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":11,"windowDurationMins":10080,"resetsAt":1735689600}}}}"#)
        precondition(current.title == "89%", "Prefer bucket map over legacy data")
        precondition(current.buckets[0].1.windows[0].label == "周额度", "Use actual window duration")
        let dual = try decode(#"{"rateLimits":{"primary":{"usedPercent":20,"windowDurationMins":300},"secondary":{"usedPercent":70,"windowDurationMins":10080}}}"#)
        precondition(dual.title == "5 小时 80% · 周 30%", "Show both windows separately")
        let unknown = try decode(#"{"rateLimits":{"primary":{"usedPercent":null}}}"#)
        precondition(unknown.title == "—", "Unknown usage must not become 100%")
        let empty = try decode(#"{"rateLimits":null,"rateLimitsByLimitId":{}}"#)
        precondition(empty.buckets.isEmpty && empty.title == "—")
        let fallback = try decode(#"{"rateLimits":{"primary":{"usedPercent":12.5}},"rateLimitsByLimitId":{}}"#)
        precondition(fallback.title == "87%", "Round remaining conservatively")
        let multi = try decode(#"{"rateLimitsByLimitId":{"other":{"primary":{"usedPercent":1}},"codex":{"primary":{"usedPercent":100}}}}"#)
        precondition(multi.title == "0%" && multi.buckets.count == 2, "Do not add or substitute quota buckets")
        print("Passed: current weekly quota, multiple windows, unknown data, empty data, legacy fallback, multiple buckets.")
    }
}
