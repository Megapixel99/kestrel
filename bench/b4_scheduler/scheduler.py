#!/usr/bin/env python3
"""B4a: the Kestrel tab scheduler -- the actual policy, not a sketch.

Four states (DESIGN.md §2). The scheduler holds a global byte budget by demoting
tabs down the ladder, cheapest-regret-first:

    LIVE --freeze--> WARM --hibernate--> COLD --evict--> STUB

The scoring rule is the whole design. Demote the tab with the lowest

    score = P(return soon) * restore_cost / bytes_recoverable

i.e. prefer to demote tabs that are unlikely to be needed, cheap to bring back,
and expensive to keep. A tab that is huge but never revisited goes first; a small
tab you bounce off constantly stays live even though evicting it is easy.
"""
from dataclasses import dataclass, field
from enum import IntEnum
import math


class State(IntEnum):
    STUB = 0     # url + title + thumbnail; reload from network, state lost
    COLD = 1     # serialized session image on disk; process gone
    WARM = 2     # frozen: no execution, compacted heap, decoded surfaces dropped
    LIVE = 3     # fully resident


@dataclass
class Tab:
    tid: int
    live_bytes: int                  # cost when LIVE (sampled from real renderer RSS)
    state: State = State.LIVE
    last_used: float = 0.0
    uses: int = 0
    pinned: bool = False
    audible: bool = False
    has_unsubmitted_input: bool = False
    cooperates: bool = True          # implements serializestate/restorestate
    restore_ms_ewma: float = field(default=0.0)


@dataclass
class CostModel:
    """Per-state memory cost and restore latency.

    warm_frac / cold_bytes are the design's riskiest assumptions, so they are
    parameters here and swept in evaluate.py rather than asserted.
    """
    warm_frac: float = 0.15          # fraction of LIVE bytes a frozen tab still holds
    warm_floor: int = 512 * 1024
    cold_bytes: int = 32 * 1024      # descriptor + thumbnail atlas slot
    stub_bytes: int = 2 * 1024

    resume_warm_ms: float = 20.0     # repaint + refault
    resume_cold_ms: float = 150.0    # deserialize + restorestate + decode visible images
    resume_cold_uncoop_ms: float = 450.0   # snapshot shown, page reloads underneath
    reload_stub_ms: float = 1100.0   # full network reload

    # --- per-tab memory limit ---------------------------------------------------
    # A cap on what one tab may retain while LIVE. This is the prerequisite for the
    # global budget meaning anything: the scheduler may never touch the foreground
    # tab, so the budget can't be honoured below the size of the largest live tab.
    #
    # A cap is not free, and modelling it as free would be the whole error. Three
    # effects, all represented below:
    #   1. live bytes are truncated to the cap                     (the win)
    #   2. a tab whose natural demand exceeds the cap pays recurring in-tab reclaim
    #      -- a compacting GC plus re-decoding its visible images   (the jank)
    #   3. a tab far enough over the cap cannot function at all and is OOM'd back to
    #      a reload                                                 (the breakage)
    per_tab_cap: int = 0             # 0 = unlimited
    # One compacting full GC (~30 ms, B1) plus re-decode of a handful of visible
    # content images (~10 ms each, B2).
    reclaim_ms: float = 50.0
    # How far over cap a page can be pushed before it stops working rather than just
    # thrashing. A judgement call, swept in evaluate.py.
    break_ratio: float = 2.5

    def capped_live_bytes(self, tab: Tab) -> int:
        if self.per_tab_cap and tab.live_bytes > self.per_tab_cap:
            return self.per_tab_cap
        return tab.live_bytes

    def overshoot(self, tab: Tab) -> float:
        """How far the tab's natural demand exceeds its cap. 1.0 = fits exactly."""
        if not self.per_tab_cap:
            return 1.0
        return tab.live_bytes / self.per_tab_cap

    def reclaim_cost_ms(self, tab: Tab) -> float:
        """Recurring cost of holding a too-large page inside its cap. A tab at 2x its
        cap must free a cap's worth of memory roughly once per visit; at 1.1x, rarely."""
        o = self.overshoot(tab)
        return max(0.0, o - 1.0) * self.reclaim_ms

    def breaks(self, tab: Tab) -> bool:
        return self.overshoot(tab) > self.break_ratio

    def bytes_for(self, tab: Tab) -> int:
        if tab.state == State.LIVE:
            return self.capped_live_bytes(tab)
        if tab.state == State.WARM:
            return max(self.warm_floor,
                       int(self.capped_live_bytes(tab) * self.warm_frac))
        if tab.state == State.COLD:
            return self.cold_bytes
        return self.stub_bytes

    def restore_ms(self, tab: Tab) -> float:
        if tab.state == State.LIVE:
            return 0.0
        if tab.state == State.WARM:
            return self.resume_warm_ms
        if tab.state == State.COLD:
            return self.resume_cold_ms if tab.cooperates else self.resume_cold_uncoop_ms
        return self.reload_stub_ms


# How far down a given tab may be demoted. These carve-outs matter more than the
# algorithm: getting one wrong is a bug the user experiences as data loss.
#
# The floor is per-reason, not a single "protected" flag, because the states differ in
# what they actually risk. WARM preserves everything -- it is just a paused tab -- so
# unsubmitted input is no reason to refuse to freeze. COLD preserves DOM and form state
# via the session image. Only STUB genuinely throws work away.
def floor_state(tab: Tab) -> State:
    if tab.audible:
        return State.LIVE          # playing media: must keep executing
    if tab.pinned:
        return State.WARM          # user asked for it to stay resident and instant
    if tab.has_unsubmitted_input:
        return State.COLD          # serializable, but never discard to a reload
    return State.STUB


def is_protected(tab: Tab, now: float) -> bool:
    """True if the tab cannot be demoted any further."""
    return tab.state <= floor_state(tab)


class KestrelScheduler:
    # Never destroy state for a trivial gain. COLD already costs ~32 KB, so demoting
    # COLD -> STUB frees almost nothing while throwing away the session image and
    # forcing a network reload. Without this floor the scheduler thrashes every tab
    # to STUB whenever the protected live set alone exceeds budget -- chasing a target
    # it cannot reach and destroying user state on the way. Fail safe: stop instead.
    MIN_RECOVER_BYTES = 1024 * 1024

    def __init__(self, budget_bytes: int, cost: CostModel,
                 half_life_s: float = 900.0, keep_live: int = 4):
        self.budget = budget_bytes
        self.cost = cost
        self.half_life = half_life_s
        self.keep_live = keep_live          # MRU tabs always kept LIVE
        self.demotions = {s: 0 for s in State}
        self.gave_up = 0                    # times the budget was simply unreachable

    def p_return(self, tab: Tab, now: float) -> float:
        """Exponential recency decay, lifted by how often this tab gets revisited."""
        age = max(0.0, now - tab.last_used)
        recency = math.exp(-age * math.log(2) / self.half_life)
        familiarity = 1.0 - 1.0 / (1.0 + tab.uses)     # 0 -> 1 as uses grow
        return min(1.0, 0.25 * recency + 0.75 * recency * familiarity)

    def _recoverable(self, tab: Tab) -> int:
        return self.cost.bytes_for(tab) - self._bytes_in(tab, State(tab.state - 1))

    def score(self, tab: Tab, now: float) -> float:
        nxt = State(tab.state - 1)
        recoverable = self._recoverable(tab)
        if recoverable <= 0:
            return math.inf                            # nothing to gain; never pick
        probe = Tab(**{**tab.__dict__, "state": nxt})
        return self.p_return(tab, now) * self.cost.restore_ms(probe) / recoverable

    def _bytes_in(self, tab: Tab, state: State) -> int:
        probe = Tab(**{**tab.__dict__, "state": state})
        return self.cost.bytes_for(probe)

    def total_bytes(self, tabs) -> int:
        return sum(self.cost.bytes_for(t) for t in tabs)

    def enforce(self, tabs, now: float, foreground: int) -> int:
        """Demote until under budget. Returns bytes reclaimed."""
        reclaimed = 0
        mru = sorted((t for t in tabs if t.state == State.LIVE),
                     key=lambda t: t.last_used, reverse=True)
        protected_live = {t.tid for t in mru[:self.keep_live]} | {foreground}

        while self.total_bytes(tabs) > self.budget:
            cands = [t for t in tabs
                     if t.state > floor_state(t)
                     and t.tid != foreground
                     and not (t.state == State.LIVE and t.tid in protected_live)
                     and self._recoverable(t) >= self.MIN_RECOVER_BYTES]
            if not cands:
                self.gave_up += 1
                break
            victim = min(cands, key=lambda t: self.score(t, now))
            before = self.cost.bytes_for(victim)
            victim.state = State(victim.state - 1)
            self.demotions[victim.state] += 1
            reclaimed += before - self.cost.bytes_for(victim)
        return reclaimed


class DiscardLRUScheduler:
    """What browsers do today: nothing until pressure, then discard the least-recently
    used tab all the way to a stub, losing its state and forcing a network reload."""
    def __init__(self, budget_bytes: int, cost: CostModel):
        self.budget = budget_bytes
        self.cost = cost
        self.demotions = {s: 0 for s in State}

    def total_bytes(self, tabs) -> int:
        return sum(self.cost.bytes_for(t) for t in tabs)

    def enforce(self, tabs, now: float, foreground: int) -> int:
        reclaimed = 0
        while self.total_bytes(tabs) > self.budget:
            # Its only tool is destructive, so it must skip every tab that would lose
            # work -- exactly as Chrome's tab discarding skips pinned/audible/form tabs.
            cands = [t for t in tabs if t.state == State.LIVE
                     and t.tid != foreground and floor_state(t) == State.STUB]
            if not cands:
                break
            victim = min(cands, key=lambda t: t.last_used)
            before = self.cost.bytes_for(victim)
            victim.state = State.STUB
            self.demotions[State.STUB] += 1
            reclaimed += before - self.cost.bytes_for(victim)
        return reclaimed


class NoEvictionScheduler:
    """Status quo with headroom: keep everything live, grow without bound."""
    def __init__(self, budget_bytes: int, cost: CostModel):
        self.budget, self.cost = budget_bytes, cost
        self.demotions = {s: 0 for s in State}

    def total_bytes(self, tabs) -> int:
        return sum(self.cost.bytes_for(t) for t in tabs)

    def enforce(self, tabs, now: float, foreground: int) -> int:
        return 0
