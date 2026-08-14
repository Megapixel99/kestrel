import AppKit

/// `about:memory`, as a page rather than a window.
///
/// Firefox surfaces this as a page you can open, link to and keep in a tab; Kestrel had the
/// same data locked in a Task Manager window. Making it a page matters more here than it
/// does in Firefox: the budget is the product, and a browser that asks you to trust a
/// scheduler should let you read its books in a tab.
///
/// The page is a live document — it re-renders on the browser's own tick — and it counts
/// itself, because a memory page that hid its own cost would be exactly the kind of
/// dishonest instrumentation DEBUGGING.md §2 is about.
enum AboutMemory {

    static let sentinel = URL(string: "kestrel://memory")!

    static func isMemoryPage(_ url: URL?) -> Bool {
        guard let url else { return false }
        return url == sentinel || url.absoluteString == "about:memory"
    }

    static func html(tabs: [Tab], scheduler: Scheduler, foregroundId: Int) -> String {
        let total = scheduler.totalBytes(tabs)
        let budget = scheduler.budgetBytes
        let over = total > budget
        let pct = budget > 0 ? min(100, Double(total) / Double(budget) * 100) : 0

        func mb(_ b: Int64) -> String { String(format: "%.0f", Double(b) / 1_048_576) }

        var rows = ""
        for tab in tabs.sorted(by: { $0.currentBytes > $1.currentBytes }) {
            let name = tab.title.isEmpty ? tab.url.absoluteString : tab.title
            let live = tab.id == foregroundId
            rows += """
            <tr\(live ? " class=\"live\"" : "")>
              <td class="state \(tab.state.description.lowercased())">\(tab.state.description)</td>
              <td class="name" title="\(escape(tab.url.absoluteString))">\(escape(name))</td>
              <td class="num">\(mb(tab.currentBytes))</td>
              <td class="num">\(tab.pid.map(String.init) ?? "—")</td>
              <td class="num">\(tab.lastRestoreMs > 0 ? String(format: "%.0f ms", tab.lastRestoreMs) : "—")</td>
              <td class="num">\(tab.uses)</td>
            </tr>
            """
        }

        // Per-state totals: the shape of the ladder, which is the thing to read here.
        var ladder = ""
        for state in [TabState.live, .warm, .cold, .stub] {
            let group = tabs.filter { $0.state == state }
            guard !group.isEmpty else { continue }
            let sum = group.reduce(Int64(0)) { $0 + $1.currentBytes }
            let share = total > 0 ? Double(sum) / Double(total) * 100 : 0
            ladder += """
            <div class="rung">
              <span class="tag \(state.description.lowercased())">\(state.description)</span>
              <span class="bar"><i style="width:\(String(format: "%.1f", share))%"></i></span>
              <span class="figure">\(group.count) tab\(group.count == 1 ? "" : "s") ·
                \(mb(sum)) MB · \(String(format: "%.0f", share))%</span>
            </div>
            """
        }

        return """
        <!doctype html><html><head><meta charset="utf-8"><title>Memory</title>
        <style>
          :root { color-scheme: light dark; }
          body { font: 13px -apple-system, system-ui, sans-serif; margin: 0;
                 padding: 28px 32px 60px; }
          h1 { font-size: 20px; margin: 0 0 2px; }
          .sub { color: color-mix(in srgb, currentColor 55%, transparent); margin-bottom: 22px; }
          .headline { display: flex; align-items: baseline; gap: 12px; margin-bottom: 6px; }
          .big { font-size: 34px; font-weight: 600; font-variant-numeric: tabular-nums; }
          .of { color: color-mix(in srgb, currentColor 55%, transparent); }
          .gauge { height: 10px; border-radius: 5px; overflow: hidden;
                   background: color-mix(in srgb, currentColor 12%, transparent);
                   margin: 10px 0 26px; }
          .gauge i { display: block; height: 100%; background: #34c759; }
          .gauge.over i { background: #ff9f0a; }
          .rung { display: flex; align-items: center; gap: 10px; margin: 5px 0; }
          .tag { width: 52px; font-size: 10px; font-weight: 700; letter-spacing: .04em;
                 padding: 2px 0; text-align: center; border-radius: 4px; color: #fff; }
          .live { background: #34c759; } .warm { background: #ffcc00; color: #333; }
          .cold { background: #5ac8fa; color: #333; } .stub { background: #8e8e93; }
          .bar { flex: 1; height: 8px; border-radius: 4px;
                 background: color-mix(in srgb, currentColor 12%, transparent); }
          .bar i { display: block; height: 100%; border-radius: 4px; background: currentColor;
                   opacity: .5; }
          .figure { width: 220px; font-variant-numeric: tabular-nums;
                    color: color-mix(in srgb, currentColor 65%, transparent); }
          table { border-collapse: collapse; width: 100%; margin-top: 26px; }
          th { text-align: left; font-size: 11px; text-transform: uppercase;
               letter-spacing: .05em; padding: 6px 8px;
               color: color-mix(in srgb, currentColor 55%, transparent);
               border-bottom: 1px solid color-mix(in srgb, currentColor 15%, transparent); }
          td { padding: 5px 8px; border-bottom: 1px solid
               color-mix(in srgb, currentColor 8%, transparent); }
          td.num { text-align: right; font-variant-numeric: tabular-nums; width: 74px; }
          td.state { width: 54px; font-size: 10px; font-weight: 700; }
          td.state.live { color: #34c759; } td.state.warm { color: #d9a400; }
          td.state.cold { color: #2196c9; } td.state.stub { color: #8e8e93; }
          td.name { max-width: 0; overflow: hidden; text-overflow: ellipsis;
                    white-space: nowrap; }
          tr.live td.name { font-weight: 600; }
          .note { margin-top: 28px; font-size: 11px; line-height: 1.5;
                  color: color-mix(in srgb, currentColor 50%, transparent); max-width: 60ch; }
        </style></head><body>
          <h1>Memory</h1>
          <div class="sub">Live, from this browser's own scheduler. Refreshes as it runs.</div>
          <div class="headline">
            <span class="big" id="total">\(mb(total))</span><span class="of">MB of <span id="budget">\(mb(budget))</span> MB budget</span>
          </div>
          <div class="gauge\(over ? " over" : "")" id="gauge"><i style="width:\(String(format: "%.1f", pct))%"></i></div>
          <div id="ladder">\(ladder)</div>
          <table>
            <thead><tr><th>State</th><th>Tab</th><th>MB</th><th>PID</th>
              <th>Restore</th><th>Visits</th></tr></thead>
            <tbody id="rows">\(rows)</tbody>
          </table>
          <div class="note">
            Footprint is <code>phys_footprint</code> per WebContent process, which is what
            macOS's memory-pressure system acts on. A tab with no process of its own reads
            as zero — that is the point of COLD and STUB, not a gap in the measurement.
            This page is itself a tab, and it is counted in the total above.
          </div>
          <script>
          // Updated in place from the browser, rather than reloading the document.
          function updateMemory(d) {
            document.getElementById('total').textContent = d.total;
            document.getElementById('budget').textContent = d.budget;
            var g = document.getElementById('gauge');
            g.className = 'gauge' + (d.over ? ' over' : '');
            g.firstElementChild.style.width = d.pct.toFixed(1) + '%';
            document.getElementById('ladder').innerHTML = d.rungs.map(function (r) {
              return '<div class="rung"><span class="tag ' + r.state.toLowerCase() + '">'
                + r.state + '</span><span class="bar"><i style="width:'
                + r.share.toFixed(1) + '%"></i></span><span class="figure">'
                + r.count + ' tab' + (r.count === 1 ? '' : 's') + ' \\u00b7 ' + r.mb
                + ' MB \\u00b7 ' + Math.round(r.share) + '%</span></div>';
            }).join('');
            document.getElementById('rows').innerHTML = d.rows.map(function (t) {
              function esc(x) {
                return String(x).replace(/&/g, '&amp;').replace(/</g, '&lt;')
                                .replace(/>/g, '&gt;').replace(/"/g, '&quot;');
              }
              return '<tr' + (t.live ? ' class="live"' : '') + '><td class="state '
                + t.state.toLowerCase() + '">' + t.state + '</td><td class="name" title="'
                + esc(t.url) + '">' + esc(t.name) + '</td><td class="num">' + t.mb
                + '</td><td class="num">' + esc(t.pid) + '</td><td class="num">'
                + esc(t.restore) + '</td><td class="num">' + t.uses + '</td></tr>';
            }).join('');
          }
          </script>
        </body></html>
        """
    }

    /// The numbers, as JSON, for updating a page that is already open.
    ///
    /// The page used to be re-rendered and `loadHTMLString`d on every 1.5 s tick — a full
    /// document reload forty times a minute, which threw away the scroll position and any
    /// selection, and re-parsed the document each time. Rendering it is cheap (0.23 ms for
    /// 24 tabs); reloading it is not, and it made the page unusable as soon as it was long
    /// enough to scroll.
    static func payload(tabs: [Tab], scheduler: Scheduler, foregroundId: Int) -> String {
        let total = scheduler.totalBytes(tabs)
        let budget = scheduler.budgetBytes
        func mb(_ b: Int64) -> Int { Int(Double(b) / 1_048_576) }

        var rungs: [[String: Any]] = []
        for state in [TabState.live, .warm, .cold, .stub] {
            let group = tabs.filter { $0.state == state }
            guard !group.isEmpty else { continue }
            let sum = group.reduce(Int64(0)) { $0 + $1.currentBytes }
            rungs.append(["state": "\(state)", "count": group.count, "mb": mb(sum),
                          "share": total > 0 ? Double(sum) / Double(total) * 100 : 0])
        }

        let rows = tabs.sorted { $0.currentBytes > $1.currentBytes }.map { t -> [String: Any] in
            ["state": "\(t.state)",
             "name": t.title.isEmpty ? t.url.absoluteString : t.title,
             "url": t.url.absoluteString,
             "mb": mb(t.currentBytes),
             "pid": t.pid.map(String.init) ?? "—",
             "restore": t.lastRestoreMs > 0 ? String(format: "%.0f ms", t.lastRestoreMs) : "—",
             "uses": t.uses,
             "live": t.id == foregroundId]
        }

        let obj: [String: Any] = [
            "total": mb(total), "budget": mb(budget),
            "over": total > budget,
            "pct": budget > 0 ? min(100, Double(total) / Double(budget) * 100) : 0,
            "rungs": rungs, "rows": rows,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
