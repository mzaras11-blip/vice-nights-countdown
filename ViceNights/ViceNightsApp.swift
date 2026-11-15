import SwiftUI
import WebKit
import EventKit

/// JS -> native haptics bridge. Web code can call:
///   window.webkit.messageHandlers.haptics.postMessage("light" | "medium" | "heavy"
///       | "success" | "warning" | "error" | "selection")
final class HapticsBridge: NSObject, WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == "haptics" else { return }
        let style = (message.body as? String) ?? "light"
        DispatchQueue.main.async {
            switch style {
            case "heavy":
                UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
            case "medium":
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            case "success":
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            case "warning":
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
            case "error":
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            case "selection":
                UISelectionFeedbackGenerator().selectionChanged()
            default:
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
        }
    }
}

/// JS -> native calendar bridge. The web core calls:
///   window.webkit.messageHandlers.calendar.postMessage({action: "addLaunch"})
/// Native adds the launch-night event (Thu Nov 19, 2026, 12:00 AM Eastern,
/// one hour) to the user's default calendar and calls back via
/// window.onCalendarResult('added' | 'denied' | 'error'). On plain web
/// (no bridge) the page falls back to downloading an .ics file instead.
final class CalendarBridge: NSObject, WKScriptMessageHandler {
    weak var webView: WKWebView?
    private let store = EKEventStore()

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == "calendar",
              let dict = message.body as? [String: Any],
              (dict["action"] as? String) == "addLaunch" else { return }
        store.requestWriteOnlyAccessToEvents { [weak self] granted, _ in
            guard let self else { return }
            guard granted else { self.reply("denied"); return }
            self.addLaunchEvent()
        }
    }

    private func addLaunchEvent() {
        var eastern = Calendar(identifier: .gregorian)
        eastern.timeZone = TimeZone(identifier: "America/New_York")!
        var comps = DateComponents()
        comps.year = 2026; comps.month = 11; comps.day = 19
        comps.hour = 0; comps.minute = 0; comps.second = 0
        guard let start = eastern.date(from: comps) else { reply("error"); return }
        let event = EKEvent(eventStore: store)
        event.title = "Launch Night"
        event.startDate = start
        event.endDate = start.addingTimeInterval(3600)
        event.notes = "The biggest launch night of the year is here. Midnight Eastern."
        event.calendar = store.defaultCalendarForNewEvents
        do {
            try store.save(event, span: .thisEvent)
            reply("added")
        } catch {
            reply("error")
        }
    }

    private func reply(_ result: String) {
        let js = "window.onCalendarResult && window.onCalendarResult('\(result)')"
        DispatchQueue.main.async { [weak self] in
            self?.webView?.evaluateJavaScript(js, completionHandler: nil)
        }
    }
}

/// Holds all JS bridges for the web view's lifetime.
final class WebCoordinator: NSObject {
    let haptics = HapticsBridge()
    let calendar = CalendarBridge()
}

/// Full-screen web view hosting the bundled countdown page at web/index.html.
/// This is the entire app UI — a clean web-bridge shell with no SDKs.
struct WebView: UIViewRepresentable {
    func makeCoordinator() -> WebCoordinator { WebCoordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.userContentController.add(context.coordinator.haptics, name: "haptics")
        config.userContentController.add(context.coordinator.calendar, name: "calendar")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.isOpaque = false
        webView.backgroundColor = .clear
        context.coordinator.calendar.webView = webView

        if let url = Bundle.main.url(forResource: "index", withExtension: "html",
                                     subdirectory: "web") {
            // Bundled copy — works fully offline.
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

/// Root layout. The web view fills the screen over the app's neon-night
/// gradient, so no gap can ever show a plain white window background
/// while the page loads.
struct RootView: View {
    var body: some View {
        WebView()
            .ignoresSafeArea()
            .background(
                LinearGradient(
                    colors: [Color(red: 0.09, green: 0.03, blue: 0.16),
                             Color(red: 0.16, green: 0.05, blue: 0.24),
                             Color(red: 0.05, green: 0.02, blue: 0.09)],
                    startPoint: .top, endPoint: .bottom)
            )
    }
}

@main
struct ViceNightsApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
