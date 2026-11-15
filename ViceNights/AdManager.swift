import Foundation
import SwiftUI
import Combine
import UIKit
import WebKit
import AppTrackingTransparency
#if canImport(GoogleMobileAds)
import GoogleMobileAds
#endif

/// Central ad coordinator for GTA6 News.
///
/// Ported from the SWISH ARCADE shell's AdManager (same AdMob account,
/// same house rules), trimmed to what this app runs: one bottom banner
/// and native ads inside the Launch News feed. The AdMob app ID lives in
/// Info.plist (GADApplicationIdentifier); the units below are GTA6 News's
/// own (created 2026-11-15).
///
/// Ads are NOT loaded at init. Guideline 5.1.2(i): the App Tracking
/// Transparency request must come first — see beginAdFlow(). A "no" still
/// gets ads; they are simply not personalized.
final class AdManager: NSObject, ObservableObject {
    static let shared = AdManager()

    // MARK: GTA6 News ad units (AdMob account mzaras11@gmail.com)
    let bannerAdUnitID = "ca-app-pub-9461680459080238/4672477716"
    let nativeAdUnitID = "ca-app-pub-9461680459080238/3359396047"

    /// True only once a real banner ad has actually loaded. The banner
    /// strip exists on screen only while this is true (house rule from
    /// S.W.I.S.H: show the ad only when there is an actual ad).
    @Published var bannerLoaded = false
    private var bannerHasLoaded = false

    #if canImport(GoogleMobileAds)
    private weak var bannerView: GADBannerView?
    #endif

    private var adFlowStarted = false

    private override init() { super.init() }

    /// Entry point for the ad flow, called once from the app's init.
    /// Presents the ATT permission request (after a short settle delay so
    /// the first screen is on display); only after the user decides does
    /// the ads SDK start and the first ads load.
    func beginAdFlow() {
        guard !adFlowStarted else { return }
        adFlowStarted = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if #available(iOS 14, *) {
                ATTrackingManager.requestTrackingAuthorization { _ in
                    DispatchQueue.main.async { AdManager.shared.startAds() }
                }
            } else {
                AdManager.shared.startAds()
            }
        }
    }

    private func startAds() {
        #if canImport(GoogleMobileAds)
        GADMobileAds.sharedInstance().start(completionHandler: nil)
        #endif
        feedAds.startLoading()
    }

    // MARK: - Banner

    #if canImport(GoogleMobileAds)
    func makeBanner(delegate: GADBannerViewDelegate?) -> GADBannerView {
        let banner = GADBannerView(adSize: GADAdSizeBanner)
        banner.adUnitID = bannerAdUnitID
        banner.delegate = delegate
        bannerView = banner
        banner.load(GADRequest())
        return banner
    }

    /// A real banner ad arrived — the strip may show.
    func noteBannerLoaded() {
        bannerHasLoaded = true
        bannerLoaded = true
    }

    /// A banner load failed (for example no ad available). Before the
    /// first success the strip stays hidden; afterwards the on-screen ad
    /// is kept. Either way, retry later so one empty moment does not
    /// disable banners for the whole session.
    func noteBannerFailed() {
        if !bannerHasLoaded { bannerLoaded = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 45) { [weak self] in
            self?.bannerView?.load(GADRequest())
        }
    }
    #endif

    // MARK: - Feed (native) ads

    /// The native-ad side of the house: owns the loaded GADNativeAds and
    /// the overlay views that sit on top of the web view's news feed.
    let feedAds = FeedAdController()

    /// Called from the web view's representable once the WKWebView exists:
    /// the feed overlay tracks the web view's frame from here on.
    func attachFeedOverlay(to webView: WKWebView) {
        feedAds.attach(to: webView)
    }
}

#if canImport(GoogleMobileAds)
/// SwiftUI wrapper for an AdMob banner (same pattern as the SWISH shell).
struct BannerAdView: UIViewRepresentable {
    func makeUIView(context: Context) -> GADBannerView {
        let banner = AdManager.shared.makeBanner(delegate: context.coordinator)
        banner.rootViewController = topViewController()
        return banner
    }
    func updateUIView(_ uiView: GADBannerView, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator: NSObject, GADBannerViewDelegate {
        func bannerViewDidReceiveAd(_ bannerView: GADBannerView) {
            AdManager.shared.noteBannerLoaded()
        }
        func bannerView(_ bannerView: GADBannerView, didFailToReceiveAdWithError error: Error) {
            AdManager.shared.noteBannerFailed()
        }
    }
}
#endif

/// Returns the top-most view controller for presenting ads.
func topViewController() -> UIViewController? {
    guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
          let root = scene.windows.first?.rootViewController else { return nil }
    var vc = root
    while let presented = vc.presentedViewController { vc = presented }
    return vc
}

// MARK: - Feed native ads

/// One reported ad slot from the web layer: a placeholder div inside the
/// news list, in viewport (CSS point) coordinates.
struct AdSlotRect {
    let id: Int
    let rect: CGRect
}

/// Loads native ads for the Launch News feed and keeps one native ad view
/// glued over each placeholder slot the web layer reports.
///
/// How it works (the closest equivalent of the SWISH shell's bridge
/// pattern for an in-feed placement): the web page inserts a placeholder
/// div after every 5 news cards and reports the placeholders' viewport
/// rects through the "ads" message handler whenever they move (scroll,
/// resize, re-render). Native answers by telling the page how many ads
/// are actually loaded (window.onNativeAdsReady) so unfilled placeholders
/// are removed page-side, and positions a real GADNativeAdView over each
/// remaining placeholder. The overlay view passes touches through
/// everywhere except on the ad views themselves.
final class FeedAdController: NSObject {
    private weak var webView: WKWebView?
    private var overlay: AdOverlayView?
    private var frameTimer: Timer?

    #if canImport(GoogleMobileAds)
    private var adLoader: GADAdLoader?
    private var loadedAds: [GADNativeAd] = []
    #endif
    private var loadFinished = false
    private var slots: [AdSlotRect] = []
    private var slotViews: [Int: UIView] = [:]

    /// Start loading the feed ads (called once, after ATT + SDK start).
    func startLoading() {
        #if canImport(GoogleMobileAds)
        guard adLoader == nil else { return }
        // The loader needs a root view controller; the app has a single
        // window, so resolve it lazily on the next runloop turn.
        DispatchQueue.main.async { [weak self] in
            guard let self, let vc = topViewController() else { return }
            let options = GADMultipleAdsAdLoaderOptions()
            options.numberOfAds = 5
            let loader = GADAdLoader(adUnitID: AdManager.shared.nativeAdUnitID,
                                     rootViewController: vc,
                                     adTypes: [.native], options: [options])
            loader.delegate = self
            self.adLoader = loader
            loader.load(GADRequest())
        }
        #else
        loadFinished = true
        notifyWebAdCount()
        #endif
    }

    /// Attach the overlay above the given web view. The overlay lives in
    /// the web view's superview and is kept frame-synced to the web view
    /// (which shrinks when the banner strip appears).
    func attach(to webView: WKWebView) {
        guard self.webView !== webView else { return }
        self.webView = webView
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard let superview = webView.superview else {
                // Web view not in the hierarchy yet — try once more.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    guard let self, self.overlay == nil,
                          let superview = webView.superview else { return }
                    self.installOverlay(in: superview, frame: webView.frame)
                }
                return
            }
            self.installOverlay(in: superview, frame: webView.frame)
        }
    }

    private func installOverlay(in superview: UIView, frame: CGRect) {
        guard overlay == nil, let webView else { return }
        let overlay = AdOverlayView(frame: frame)
        overlay.backgroundColor = .clear
        overlay.isUserInteractionEnabled = true
        superview.addSubview(overlay)
        self.overlay = overlay
        frameTimer?.invalidate()
        frameTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self, let webView = self.webView, let overlay = self.overlay else { return }
            if overlay.frame != webView.frame { overlay.frame = webView.frame }
        }
        layoutSlotViews()
    }

    /// The web layer reported the current placeholder rects.
    func updateSlots(_ newSlots: [AdSlotRect]) {
        slots = newSlots
        layoutSlotViews()
    }

    private func notifyWebAdCount() {
        #if canImport(GoogleMobileAds)
        let count = loadedAds.count
        #else
        let count = 0
        #endif
        guard loadFinished, let webView else { return }
        let js = "window.onNativeAdsReady && window.onNativeAdsReady(\(count))"
        DispatchQueue.main.async { webView.evaluateJavaScript(js, completionHandler: nil) }
    }

    private func layoutSlotViews() {
        guard let overlay else { return }
        #if canImport(GoogleMobileAds)
        let usable = loadFinished ? loadedAds.count : 0
        var wanted = Set<Int>()
        for (index, slot) in slots.enumerated() {
            guard index < usable else { break }
            wanted.insert(slot.id)
            let view: NativeFeedAdView
            if let existing = slotViews[slot.id] as? NativeFeedAdView {
                view = existing
            } else {
                view = NativeFeedAdView(nativeAd: loadedAds[index])
                slotViews[slot.id] = view
                overlay.addSubview(view)
            }
            view.frame = slot.rect
        }
        for (id, view) in slotViews where !wanted.contains(id) {
            view.removeFromSuperview()
            slotViews.removeValue(forKey: id)
        }
        #endif
    }
}

#if canImport(GoogleMobileAds)
extension FeedAdController: GADNativeAdLoaderDelegate {
    func adLoader(_ adLoader: GADAdLoader, didReceive nativeAd: GADNativeAd) {
        loadedAds.append(nativeAd)
    }
    func adLoaderDidFinishLoading(_ adLoader: GADAdLoader) {
        loadFinished = true
        notifyWebAdCount()
        layoutSlotViews()
    }
    func adLoader(_ adLoader: GADAdLoader, didFailToReceiveAdWithError error: Error) {
        loadFinished = true
        notifyWebAdCount()
        layoutSlotViews()
    }
}
#endif

/// Overlay container: transparent to touches everywhere except on the
/// native ad views it hosts, so the web page scrolls normally around
/// (and "through") the gaps between ads.
final class AdOverlayView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        for subview in subviews.reversed() {
            let converted = subview.convert(point, from: self)
            if let hit = subview.hitTest(converted, with: event) { return hit }
        }
        return nil
    }
}

#if canImport(GoogleMobileAds)
/// A native ad rendered like a news card: dark panel, rounded corners,
/// the advertiser's icon + headline, body text, media, a call-to-action
/// button, and the required "Ad" badge in the meta row (same slot the
/// news cards use for their tag pill).
final class NativeFeedAdView: GADNativeAdView {
    init(nativeAd: GADNativeAd) {
        super.init(frame: .zero)
        backgroundColor = UIColor(red: 0.10, green: 0.07, blue: 0.20, alpha: 1)
        layer.cornerRadius = 18
        layer.borderWidth = 1
        layer.borderColor = UIColor.white.withAlphaComponent(0.14).cgColor
        clipsToBounds = true

        let badge = UILabel()
        badge.text = "Ad"
        badge.font = .systemFont(ofSize: 10.5, weight: .heavy)
        badge.textColor = UIColor(red: 1.0, green: 0.76, blue: 0.12, alpha: 1)
        badge.layer.borderWidth = 1
        badge.layer.borderColor = UIColor(red: 1.0, green: 0.76, blue: 0.12, alpha: 0.55).cgColor
        badge.layer.cornerRadius = 8
        badge.textAlignment = .center
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.widthAnchor.constraint(equalToConstant: 30).isActive = true
        badge.heightAnchor.constraint(equalToConstant: 17).isActive = true

        let advertiserLabel = UILabel()
        advertiserLabel.text = nativeAd.advertiser ?? nativeAd.store ?? "Advertisement"
        advertiserLabel.font = .systemFont(ofSize: 12, weight: .bold)
        advertiserLabel.textColor = UIColor.white.withAlphaComponent(0.55)

        let metaRow = UIStackView(arrangedSubviews: [badge, advertiserLabel])
        metaRow.axis = .horizontal
        metaRow.spacing = 10
        metaRow.alignment = .center

        let iconView = UIImageView()
        iconView.contentMode = .scaleAspectFill
        iconView.clipsToBounds = true
        iconView.layer.cornerRadius = 10
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.widthAnchor.constraint(equalToConstant: 44).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 44).isActive = true
        if let icon = nativeAd.icon?.image { iconView.image = icon } else { iconView.isHidden = true }

        let headlineLabel = UILabel()
        headlineLabel.text = nativeAd.headline
        headlineLabel.font = .systemFont(ofSize: 17, weight: .heavy)
        headlineLabel.textColor = .white
        headlineLabel.numberOfLines = 2

        let bodyLabel = UILabel()
        bodyLabel.text = nativeAd.body
        bodyLabel.font = .systemFont(ofSize: 14)
        bodyLabel.textColor = UIColor.white.withAlphaComponent(0.62)
        bodyLabel.numberOfLines = 2

        let textStack = UIStackView(arrangedSubviews: [headlineLabel, bodyLabel])
        textStack.axis = .vertical
        textStack.spacing = 4

        let headRow = UIStackView(arrangedSubviews: [iconView, textStack])
        headRow.axis = .horizontal
        headRow.spacing = 12
        headRow.alignment = .top

        let mediaView = GADMediaView()
        mediaView.mediaContent = nativeAd.mediaContent
        mediaView.clipsToBounds = true
        mediaView.layer.cornerRadius = 12
        mediaView.translatesAutoresizingMaskIntoConstraints = false
        mediaView.heightAnchor.constraint(equalToConstant: 120).isActive = true
        if !nativeAd.mediaContent.hasVideoContent && nativeAd.images?.first == nil {
            mediaView.isHidden = true
        }

        let cta = UIButton(type: .system)
        cta.setTitle(nativeAd.callToAction ?? "Learn More", for: .normal)
        cta.titleLabel?.font = .systemFont(ofSize: 14, weight: .heavy)
        cta.setTitleColor(UIColor(red: 0.11, green: 0.06, blue: 0.20, alpha: 1), for: .normal)
        cta.backgroundColor = UIColor(red: 1.0, green: 0.76, blue: 0.12, alpha: 1)
        cta.layer.cornerRadius = 999
        cta.contentEdgeInsets = UIEdgeInsets(top: 9, left: 20, bottom: 9, right: 20)
        cta.isUserInteractionEnabled = false // taps land on the ad view itself

        let stack = UIStackView(arrangedSubviews: [metaRow, headRow, mediaView, cta])
        stack.axis = .vertical
        stack.spacing = 10
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -14),
        ])

        // GADNativeAdView asset wiring — the SDK registers impressions
        // and clicks from these.
        self.headlineView = headlineLabel
        self.bodyView = bodyLabel
        self.iconView = iconView
        self.mediaView = mediaView
        self.callToActionView = cta
        self.advertiserView = advertiserLabel
        self.nativeAd = nativeAd
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
#endif

/// JS -> native ads bridge. The web layer posts:
///   window.webkit.messageHandlers.ads.postMessage(
///     {action: "adSlots", slots: [{id, x, y, w, h}, ...]})
/// whenever the news feed's ad placeholders move. Native positions real
/// native ad views over them (see FeedAdController) and calls back via
/// window.onNativeAdsReady(count) once ad loading has finished.
final class AdsBridge: NSObject, WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == "ads",
              let dict = message.body as? [String: Any],
              (dict["action"] as? String) == "adSlots",
              let raw = dict["slots"] as? [[String: Any]] else { return }
        let slots = raw.compactMap { item -> AdSlotRect? in
            guard let id = (item["id"] as? NSNumber)?.intValue,
                  let x = (item["x"] as? NSNumber)?.doubleValue,
                  let y = (item["y"] as? NSNumber)?.doubleValue,
                  let w = (item["w"] as? NSNumber)?.doubleValue,
                  let h = (item["h"] as? NSNumber)?.doubleValue else { return nil }
            return AdSlotRect(id: id, rect: CGRect(x: x, y: y, width: w, height: h))
        }
        DispatchQueue.main.async {
            AdManager.shared.feedAds.updateSlots(slots)
        }
    }
}
