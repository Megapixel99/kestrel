import AppKit
import WebKit

/// Screenshot capture: visible area, full page, element, region, and PDF.
///
/// Modelled on Longshot (../../screenshot), which solved the same problem as a Firefox
/// extension. The hard parts are the same in a native browser and are worth naming:
///
///  - **Sticky headers repeat in every band.** Scroll-and-stitch photographs the viewport
///    at successive offsets; anything `position: fixed` or `sticky` stays put and appears
///    once per band. They have to be neutralised before the descent and restored after.
///  - **Lazy content is not there yet.** Images and infinite lists only load when
///    scrolled near, so the page must be walked down once to prime them, and its height
///    re-measured afterwards because it grows.
///  - **Animations desynchronise bands.** Freezing them keeps successive bands coherent.
///  - **Tall pages exceed any sane bitmap.** A 50,000 px page at 2× is ~1.6 GB of RGBA.
///    In a browser built around a memory budget, capture has to be budgeted too, so the
///    plan scales down rather than allocating whatever the page asks for.
enum Screenshot {

    enum Mode { case visible, fullPage, element, pdf }

    /// Hard ceiling on a stitched image, in pixels. 80 MP is ~320 MB as RGBA — generous
    /// for a screenshot and small enough not to blow the budget the browser advertises.
    static let maxPixels = 80_000_000

    struct Plan {
        let contentSize: CGSize      // CSS px
        let viewport: CGSize         // CSS px
        let scale: CGFloat           // downscale applied to stay within maxPixels
        let bandCount: Int
        var scaledSize: CGSize {
            CGSize(width: (contentSize.width * scale).rounded(),
                   height: (contentSize.height * scale).rounded())
        }
        var wasDownscaled: Bool { scale < 0.999 }
    }

    static func plan(content: CGSize, viewport: CGSize, deviceScale: CGFloat) -> Plan {
        let full = content.width * deviceScale * content.height * deviceScale
        var scale: CGFloat = 1
        if full > CGFloat(maxPixels) {
            scale = sqrt(CGFloat(maxPixels) / full)
        }
        let bands = viewport.height > 0
            ? max(1, Int(ceil(content.height / viewport.height))) : 1
        return Plan(contentSize: content, viewport: viewport, scale: scale, bandCount: bands)
    }

    // MARK: - page-side helpers

    /// Injected once per capture. Kept in one string so a capture cannot half-apply.
    static let helperJS = """
    (function () {
      if (window.__kestrelShot) return 'ready';
      const S = {};
      S.stash = [];

      S.metrics = function () {
        const d = document.documentElement, b = document.body;
        return {
          width:  Math.max(d.scrollWidth,  b ? b.scrollWidth  : 0, d.clientWidth),
          height: Math.max(d.scrollHeight, b ? b.scrollHeight : 0, d.clientHeight),
          viewW: window.innerWidth, viewH: window.innerHeight,
          scrollX: window.scrollX, scrollY: window.scrollY,
          dpr: window.devicePixelRatio || 1
        };
      };

      // Sticky and fixed elements would otherwise appear in every band.
      S.prepare = function () {
        S.origScroll = { x: window.scrollX, y: window.scrollY };
        S.style = document.createElement('style');
        S.style.id = '__kestrel_shot_style';
        S.style.textContent =
          '*,*::before,*::after{animation-play-state:paused !important;' +
          'transition:none !important;scroll-behavior:auto !important}' +
          'html{scroll-behavior:auto !important}';
        document.documentElement.appendChild(S.style);

        const all = document.querySelectorAll('body *');
        for (const el of all) {
          const cs = getComputedStyle(el);
          if (cs.position === 'fixed' || cs.position === 'sticky') {
            S.stash.push([el, el.style.position, el.style.top, el.style.visibility]);
            // Sticky becomes static so it scrolls with content; fixed overlays that
            // cover content (cookie bars, chat widgets) are hidden outright.
            if (cs.position === 'sticky') { el.style.position = 'static'; }
            else { el.style.visibility = 'hidden'; }
          }
        }
        return S.stash.length;
      };

      S.restore = function () {
        for (const [el, pos, top, vis] of S.stash) {
          el.style.position = pos; el.style.top = top; el.style.visibility = vis;
        }
        S.stash = [];
        if (S.style) { S.style.remove(); S.style = null; }
        if (S.origScroll) window.scrollTo(S.origScroll.x, S.origScroll.y);
        return true;
      };

      // Walk the page to trigger lazy images and infinite lists, then report the height
      // it settled at -- it is usually taller than before.
      S.prime = function () {
        return new Promise(resolve => {
          const step = Math.floor(window.innerHeight * 0.9);
          let y = 0, stable = 0, lastH = 0;
          (function hop() {
            window.scrollTo(0, y);
            const h = S.metrics().height;
            if (h === lastH) stable++; else stable = 0;
            lastH = h;
            y += step;
            // Stop at the bottom, or once the height stops growing, or at a hard cap
            // so an endless feed cannot capture forever.
            if (y > h || stable > 2 || y > 200000) {
              document.querySelectorAll('img[loading="lazy"]').forEach(i => {
                i.loading = 'eager';
                if (i.dataset.src && !i.src) i.src = i.dataset.src;
              });
              setTimeout(() => resolve(S.metrics()), 250);
            } else {
              setTimeout(hop, 120);
            }
          })();
        });
      };

      S.scrollTo = function (y) { window.scrollTo(0, y); return window.scrollY; };

      S.elementRect = function (x, y) {
        const el = document.elementFromPoint(x, y);
        if (!el) return null;
        const r = el.getBoundingClientRect();
        return { x: r.left, y: r.top, w: r.width, h: r.height,
                 absY: r.top + window.scrollY, tag: el.tagName,
                 id: el.id || '', cls: (el.className || '').toString().slice(0, 60) };
      };

      window.__kestrelShot = S;
      return 'ready';
    })();
    """

    // MARK: - capture

    /// Visible viewport only.
    static func captureVisible(_ webView: WKWebView,
                               done: @escaping (NSImage?, String) -> Void) {
        let cfg = WKSnapshotConfiguration()
        cfg.afterScreenUpdates = true
        webView.takeSnapshot(with: cfg) { image, err in
            done(image, image != nil ? "visible area"
                 : "snapshot failed: \(err?.localizedDescription ?? "?")")
        }
    }

    /// Native full-page PDF. WebKit renders the whole document, so there is no stitching
    /// and no sticky-header problem at all — the reason to still have the raster path is
    /// that a PNG is what people usually want to paste.
    static func capturePDF(_ webView: WKWebView,
                           done: @escaping (Data?, String) -> Void) {
        let cfg = WKPDFConfiguration()          // default rect = the entire page
        webView.createPDF(configuration: cfg) { result in
            switch result {
            case .success(let data): done(data, "full page PDF, \(data.count / 1024) KB")
            case .failure(let e): done(nil, "PDF failed: \(e.localizedDescription)")
            }
        }
    }

    /// Full page by scroll-and-stitch.
    static func captureFullPage(_ webView: WKWebView,
                                progress: ((String) -> Void)? = nil,
                                done: @escaping (NSImage?, String) -> Void) {
        run(webView, helperJS) { _ in
            progress?("priming lazy content…")
            run(webView, "__kestrelShot.prepare()") { _ in
                runAsync(webView, "__kestrelShot.prime()") { primed in
                    guard let m = primed as? [String: Any],
                          let w = m["width"] as? CGFloat, let h = m["height"] as? CGFloat,
                          let vw = m["viewW"] as? CGFloat, let vh = m["viewH"] as? CGFloat
                    else {
                        finish(webView) { done(nil, "could not measure the page") }
                        return
                    }
                    let deviceScale = webView.window?.backingScaleFactor ?? 2
                    let p = plan(content: CGSize(width: w, height: h),
                                 viewport: CGSize(width: vw, height: vh),
                                 deviceScale: deviceScale)
                    progress?("capturing \(p.bandCount) bands…")
                    stitch(webView, plan: p, deviceScale: deviceScale,
                           progress: progress) { image in
                        finish(webView) {
                            var note = "full page \(Int(p.contentSize.width))×\(Int(p.contentSize.height)) "
                                     + "in \(p.bandCount) bands"
                            if p.wasDownscaled {
                                note += String(format: ", scaled to %.0f%% to stay under the "
                                               + "%d MP capture budget", p.scale * 100,
                                               maxPixels / 1_000_000)
                            }
                            done(image, image != nil ? note : "stitching failed")
                        }
                    }
                }
            }
        }
    }

    private static func stitch(_ webView: WKWebView, plan p: Plan, deviceScale: CGFloat,
                               progress: ((String) -> Void)?,
                               done: @escaping (NSImage?) -> Void) {
        let pxW = Int((p.contentSize.width * deviceScale * p.scale).rounded())
        let pxH = Int((p.contentSize.height * deviceScale * p.scale).rounded())
        guard pxW > 0, pxH > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pxW,
                                         pixelsHigh: pxH, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false,
                                         colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0)
        else { done(nil); return }

        let ctx = NSGraphicsContext(bitmapImageRep: rep)
        var band = 0

        func next() {
            guard band < p.bandCount else {
                NSGraphicsContext.current = nil
                let image = NSImage(size: NSSize(width: pxW, height: pxH))
                image.addRepresentation(rep)
                done(image)
                return
            }
            let y = CGFloat(band) * p.viewport.height
            progress?("band \(band + 1)/\(p.bandCount)")
            run(webView, "__kestrelShot.scrollTo(\(y))") { _ in
                // Give WebKit a moment to paint the newly scrolled region.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                    let cfg = WKSnapshotConfiguration()
                    cfg.afterScreenUpdates = true
                    webView.takeSnapshot(with: cfg) { img, _ in
                        if let img {
                            // The last band overlaps the previous one when the page is
                            // not a whole number of viewports tall; draw it at its true
                            // offset so the overlap is painted over, not duplicated.
                            let actualY = min(y, max(0, p.contentSize.height - p.viewport.height))
                            let destY = (p.contentSize.height - actualY - p.viewport.height)
                                        * deviceScale * p.scale
                            let dest = NSRect(x: 0, y: destY,
                                              width: p.contentSize.width * deviceScale * p.scale,
                                              height: p.viewport.height * deviceScale * p.scale)
                            NSGraphicsContext.current = ctx
                            img.draw(in: dest, from: .zero,
                                     operation: .copy, fraction: 1.0)
                            NSGraphicsContext.current = nil
                        }
                        band += 1
                        next()
                    }
                }
            }
        }
        next()
    }

    private static func finish(_ webView: WKWebView, then: @escaping () -> Void) {
        // Never leave a page with its fixed elements torn out.
        run(webView, "__kestrelShot.restore()") { _ in then() }
    }

    /// Crop a already-captured image to a rect given in view points.
    static func crop(_ image: NSImage, to rect: NSRect, viewSize: NSSize) -> NSImage? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        let sx = CGFloat(rep.pixelsWide) / viewSize.width
        let sy = CGFloat(rep.pixelsHigh) / viewSize.height
        let px = NSRect(x: rect.minX * sx,
                        y: (viewSize.height - rect.maxY) * sy,
                        width: rect.width * sx, height: rect.height * sy)
        guard px.width >= 1, px.height >= 1,
              let cg = rep.cgImage?.cropping(to: px) else { return nil }
        let out = NSImage(size: NSSize(width: px.width, height: px.height))
        out.addRepresentation(NSBitmapImageRep(cgImage: cg))
        return out
    }

    // MARK: - output

    static func png(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    static func jpeg(_ image: NSImage, quality: Double = 0.9) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .jpeg,
                                  properties: [.compressionFactor: quality])
    }

    static func copyToClipboard(_ image: NSImage) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
    }

    static func suggestedFilename(for url: URL, ext: String) -> String {
        let host = (url.host ?? "page").replacingOccurrences(of: ".", with: "-")
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        return "\(host)-\(stamp).\(ext)"
    }

    // MARK: - JS plumbing

    private static func run(_ wv: WKWebView, _ js: String,
                            done: @escaping (Any?) -> Void) {
        wv.evaluateJavaScript(js) { r, _ in DispatchQueue.main.async { done(r) } }
    }

    /// evaluateJavaScript does not await a Promise, so poll a resolved global instead.
    private static func runAsync(_ wv: WKWebView, _ promiseJS: String,
                                 done: @escaping (Any?) -> Void) {
        wv.evaluateJavaScript("""
        (function () {
          window.__kestrelShotResult = null;
          (\(promiseJS)).then(v => { window.__kestrelShotResult = v; });
          return true;
        })();
        """) { _, _ in
            var waited = 0.0
            func poll() {
                wv.evaluateJavaScript("window.__kestrelShotResult") { r, _ in
                    if let r, !(r is NSNull) { done(r); return }
                    waited += 0.15
                    if waited > 90 { done(nil); return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { poll() }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { poll() }
        }
    }
}
