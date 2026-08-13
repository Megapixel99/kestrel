import AppKit
import Foundation

/// The Kestrel scheduler, ported from bench/b4_scheduler/scheduler.py and driven by
/// measured footprint instead of a cost model.
///
/// Everything the simulation established is preserved:
///   - score = P(return) * restore_cost / bytes_recoverable, demote lowest first
///   - per-reason demotion floors (audible -> LIVE, pinned -> WARM, input -> COLD)
///   - the MIN_RECOVER fail-safe: never destroy state for a trivial gain, and give up
///     rather than shred tabs chasing a budget the live working set makes impossible
///   - a per-tab cap, without which the budget is unreachable
final class Scheduler {
    /// Never destroy state for a trivial gain (RESULTS.md §4).
    static let minRecoverBytes: Int64 = 1 * 1024 * 1024

    var budgetBytes: Int64
    var perTabCapBytes: Int64      // 0 = unlimited
    var keepLive: Int
    var halfLife: TimeInterval = 900

    private(set) var demotions = 0
    private(set) var promotions = 0
    private(set) var gaveUp = 0
    private(set) var stateLosses = 0

    init(budgetBytes: Int64, perTabCapBytes: Int64 = 0, keepLive: Int = 3) {
        self.budgetBytes = budgetBytes
        self.perTabCapBytes = perTabCapBytes
        self.keepLive = keepLive
    }

    /// How far down a tab may be demoted. WARM preserves everything, COLD preserves the
    /// session image; only STUB actually discards work.
    func floor(for tab: Tab) -> TabState {
        if tab.audible { return .live }
        // A tab on a refresh timer is being watched, not stored. Freezing it would stop
        // the thing the user asked for, so it holds LIVE and pays full price.
        if tab.refreshInterval != nil { return .live }
        if tab.pinned { return .warm }
        if tab.hasUnsubmittedInput { return .cold }
        return .stub
    }

    func pReturn(_ tab: Tab, now: Date) -> Double {
        let age = max(0, now.timeIntervalSince(tab.lastUsed))
        let recency = exp(-age * log(2) / halfLife)
        let familiarity = 1 - 1 / (1 + Double(tab.uses))
        return min(1, 0.25 * recency + 0.75 * recency * familiarity)
    }

    /// Measured, not modelled: what this tab is actually holding right now, minus what
    /// the rung below it has been observed to cost.
    func recoverableBytes(_ tab: Tab) -> Int64 {
        let now = tab.currentBytes
        guard now > 0 else { return 0 }
        switch tab.state {
        case .live: return Int64(Double(now) * 0.17)   // measured WARM recovery
        case .warm: return Int64(Double(now) * 0.63)   // measured WARM -> COLD recovery
        case .cold: return now                          // STUB drops the view entirely
        case .stub: return 0
        }
    }

    func restoreCostMs(_ tab: Tab, from state: TabState) -> Double {
        switch state {
        case .live: return 0
        case .warm: return 20
        case .cold: return tab.lastRestoreMs > 0 ? tab.lastRestoreMs : 82  // measured
        case .stub: return 1100
        }
    }

    func score(_ tab: Tab, now: Date) -> Double {
        let recoverable = recoverableBytes(tab)
        guard recoverable > 0 else { return .infinity }
        let next = TabState(rawValue: tab.state.rawValue - 1) ?? .stub
        return pReturn(tab, now: now) * restoreCostMs(tab, from: next) / Double(recoverable)
    }

    func totalBytes(_ tabs: [Tab]) -> Int64 {
        tabs.reduce(0) { $0 + $1.currentBytes }
    }

    /// Demote until under budget, or until nothing worth demoting remains.
    @discardableResult
    func enforce(_ tabs: [Tab], foreground: Int, now: Date = Date()) -> Int64 {
        var reclaimed: Int64 = 0
        let mru = tabs.filter { $0.state == .live }
                      .sorted { $0.lastUsed > $1.lastUsed }
        let protectedLive = Set(mru.prefix(keepLive).map(\.id)).union([foreground])

        // Per-tab cap first: a tab over its cap is demoted regardless of budget, because
        // the cap exists to bound the live set the scheduler may not touch.
        if perTabCapBytes > 0 {
            for tab in tabs where tab.state == .live && tab.id != foreground {
                if tab.currentBytes > perTabCapBytes && floor(for: tab) < .live {
                    tab.demote(to: .warm)
                    demotions += 1
                }
            }
        }

        var guard_ = 0
        while totalBytes(tabs) > budgetBytes && guard_ < 200 {
            guard_ += 1
            let candidates = tabs.filter { tab in
                tab.state > floor(for: tab)
                && tab.id != foreground
                && !(tab.state == .live && protectedLive.contains(tab.id))
                && recoverableBytes(tab) >= Scheduler.minRecoverBytes
            }
            guard let victim = candidates.min(by: { score($0, now: now) < score($1, now: now) })
            else { gaveUp += 1; break }

            let before = victim.currentBytes
            let next = TabState(rawValue: victim.state.rawValue - 1) ?? .stub
            if next == .stub { stateLosses += 1 }
            victim.demote(to: next)
            demotions += 1
            reclaimed += max(0, before - victim.currentBytes)
        }
        return reclaimed
    }

    /// The status-quo comparison: discard straight to a stub, as Chrome's Memory Saver
    /// and Firefox's tab unloader both do. Destructive, and it must skip anything that
    /// would lose work -- which is exactly why it runs out of legal victims.
    @discardableResult
    func enforceDiscardLRU(_ tabs: [Tab], foreground: Int) -> Int64 {
        var reclaimed: Int64 = 0
        var guard_ = 0
        while totalBytes(tabs) > budgetBytes && guard_ < 200 {
            guard_ += 1
            let candidates = tabs.filter {
                $0.state == .live && $0.id != foreground && floor(for: $0) == .stub
            }
            guard let victim = candidates.min(by: { $0.lastUsed < $1.lastUsed })
            else { gaveUp += 1; break }
            let before = victim.currentBytes
            victim.demote(to: .stub)
            demotions += 1
            stateLosses += 1
            reclaimed += max(0, before - victim.currentBytes)
        }
        return reclaimed
    }
}
