import AuthenticationServices
import CTXCore
import SwiftUI
import WebKit

public struct InAppAuthWebModalView: View {
    let url: URL
    let userEmail: String?
    let callbackURLScheme: String?
    let onComplete: (Result<URL, Error>) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var webView: WKWebView?
    @State private var canGoBack = false
    @State private var canGoForward = false
    @State private var isLoading = false
    @State private var currentURL: URL?
    @State private var copiedURL = false

    public init(
        url: URL,
        userEmail: String? = nil,
        callbackURLScheme: String? = nil,
        onComplete: @escaping (Result<URL, Error>) -> Void
    ) {
        self.userEmail = userEmail
        self.callbackURLScheme = callbackURLScheme
        self.onComplete = onComplete

        // Pre-process URL with login_hint if email is present and not already in URL
        var finalURL = url
        if let email = userEmail, !email.isEmpty, email.contains("@") {
            if let host = url.host?.lowercased(), host.contains("google") || host.contains("microsoft") || host.contains("okta") {
                if var components = URLComponents(url: url, resolvingAgainstBaseURL: true) {
                    var items = components.queryItems ?? []
                    if !items.contains(where: { $0.name == "login_hint" }) {
                        items.append(URLQueryItem(name: "login_hint", value: email))
                        components.queryItems = items
                        if let u = components.url {
                            finalURL = u
                        }
                    }
                }
            }
        }

        self.url = finalURL
        _currentURL = State(initialValue: finalURL)
    }

    private var activeHost: String {
        (currentURL ?? url).host ?? "Authentication Provider"
    }

    private var isSecureSSL: Bool {
        (currentURL ?? url).scheme?.lowercased() == "https"
    }

    public var body: some View {
        VStack(spacing: 0) {
            // High-End macOS Header Bar
            HStack(spacing: 14) {
                // Navigation buttons
                HStack(spacing: 4) {
                    Button {
                        webView?.goBack()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 12, weight: .bold))
                    }
                    .disabled(!canGoBack)
                    .ctxHeaderButton()

                    Button {
                        webView?.goForward()
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .bold))
                    }
                    .disabled(!canGoForward)
                    .ctxHeaderButton()

                    Button {
                        webView?.reload()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .bold))
                    }
                    .ctxHeaderButton()
                }

                // CTX App Identity
                HStack(spacing: 8) {
                    CTXAppLogoView(size: 24)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("CTX Auth")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.primary)
                        Text(userEmail?.isEmpty == false ? (userEmail ?? "Identity & SSO") : "Identity & SSO")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 12)

                // URL SSL Capsule
                HStack(spacing: 6) {
                    Image(systemName: isSecureSSL ? "lock.fill" : "globe")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(isSecureSSL ? Color.green : Color.secondary)

                    Text(activeHost)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .lineLimit(1)
                        .foregroundStyle(.primary.opacity(0.9))

                    Button {
                        let targetURL = (currentURL ?? url).absoluteString
                        #if canImport(AppKit)
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(targetURL, forType: .string)
                        #endif
                        copiedURL = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            copiedURL = false
                        }
                    } label: {
                        Image(systemName: copiedURL ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(copiedURL ? Color.green : Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Copy URL")

                    Button {
                        let target = currentURL ?? url
                        #if canImport(AppKit)
                        NSWorkspace.shared.open(target)
                        #endif
                    } label: {
                        Image(systemName: "safari")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Open in System Browser")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                        )
                )

                Spacer(minLength: 12)

                // Close Button
                Button {
                    onComplete(.failure(CancellationError()))
                    dismiss()
                } label: {
                    HStack(spacing: 4) {
                        Text("Close")
                            .font(.system(size: 12, weight: .semibold))
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                    }
                }
                .ctxHeaderButton()
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                LinearGradient(
                    colors: [Color(nsColor: .windowBackgroundColor), Color(nsColor: .windowBackgroundColor).opacity(0.95)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )

            // Dynamic Accent Loading Bar
            ZStack(alignment: .leading) {
                Divider()
                if isLoading {
                    GeometryReader { geo in
                        Rectangle()
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color(red: 0.227, green: 0.941, blue: 0.443),
                                        Color(red: 0.125, green: 0.529, blue: 1.0)
                                    ],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: geo.size.width * 0.4, height: 2)
                            .offset(x: isLoading ? geo.size.width * 0.6 : 0)
                            .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: isLoading)
                    }
                    .frame(height: 2)
                }
            }
            .frame(height: 2)

            // Web View Container
            WebViewRepresentable(
                url: url,
                userEmail: userEmail,
                callbackURLScheme: callbackURLScheme,
                onComplete: { result in
                    onComplete(result)
                    dismiss()
                },
                webViewBinding: $webView,
                canGoBack: $canGoBack,
                canGoForward: $canGoForward,
                isLoading: $isLoading,
                currentURL: $currentURL
            )
        }
        .frame(minWidth: 840, minHeight: 760)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct WebViewRepresentable: NSViewRepresentable {
    let url: URL
    let userEmail: String?
    let callbackURLScheme: String?
    let onComplete: (Result<URL, Error>) -> Void
    @Binding var webViewBinding: WKWebView?
    @Binding var canGoBack: Bool
    @Binding var canGoForward: Bool
    @Binding var isLoading: Bool
    @Binding var currentURL: URL?

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.applicationNameForUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15 CTX/1.0"

        // Inject JS helper to auto-fill user email if provided
        if let email = userEmail, !email.isEmpty, email.contains("@") {
            let jsCode = """
            (function() {
                var userEmail = "\(email)";
                if (!userEmail) return;
                function tryFill() {
                    var inputs = document.querySelectorAll('input[type="email"], input[name="identifier"], input[name="loginfmt"], input[name="Email"], input[name="username"], input[id="input28"]');
                    inputs.forEach(function(input) {
                        if (!input.value || input.value === '') {
                            input.value = userEmail;
                            input.dispatchEvent(new Event('input', { bubbles: true }));
                            input.dispatchEvent(new Event('change', { bubbles: true }));
                        }
                    });
                }
                if (document.readyState === 'complete' || document.readyState === 'interactive') {
                    tryFill();
                } else {
                    document.addEventListener('DOMContentLoaded', tryFill);
                }
                setTimeout(tryFill, 400);
                setTimeout(tryFill, 1000);
            })();
            """
            let userScript = WKUserScript(source: jsCode, injectionTime: .atDocumentEnd, forMainFrameOnly: false)
            configuration.userContentController.addUserScript(userScript)
        }

        // Inject JS completion observer for StrongDM, AWS SSO, and SSO success screens
        let completionJS = """
        (function() {
            function checkCompletion() {
                var text = (document.body ? document.body.innerText : '') || '';
                var title = document.title || '';
                var lowerText = text.toLowerCase();
                var lowerTitle = title.toLowerCase();
                if (lowerText.includes('authentication complete') ||
                    lowerText.includes('you may now close this window') ||
                    lowerText.includes('you can close this window') ||
                    lowerText.includes('you may close this window') ||
                    lowerText.includes('successfully authenticated') ||
                    lowerText.includes('login successful') ||
                    lowerText.includes('request approved') ||
                    lowerText.includes('code verified') ||
                    lowerText.includes('device authorized') ||
                    lowerText.includes('successfully authorized') ||
                    lowerText.includes('request authorized') ||
                    lowerTitle.includes('authentication complete')) {
                    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.ctxAuthComplete) {
                        window.webkit.messageHandlers.ctxAuthComplete.postMessage("complete");
                    }
                }
            }
            if (document.readyState === 'complete' || document.readyState === 'interactive') {
                checkCompletion();
            } else {
                document.addEventListener('DOMContentLoaded', checkCompletion);
            }
            var checkInterval = setInterval(checkCompletion, 400);
            setTimeout(function() { clearInterval(checkInterval); }, 120000);
        })();
        """
        let completionScript = WKUserScript(source: completionJS, injectionTime: .atDocumentEnd, forMainFrameOnly: false)
        configuration.userContentController.addUserScript(completionScript)
        configuration.userContentController.add(context.coordinator, name: "ctxAuthComplete")

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")

        DispatchQueue.main.async {
            self.webViewBinding = webView
        }

        webView.load(URLRequest(url: url))
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: WebViewRepresentable
        private var didTriggerCompletion = false

        init(_ parent: WebViewRepresentable) {
            self.parent = parent
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "ctxAuthComplete" {
                triggerCompletion()
            }
        }

        private func triggerCompletion(withURL overrideURL: URL? = nil) {
            guard !didTriggerCompletion else { return }
            didTriggerCompletion = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self = self else { return }
                let targetURL = overrideURL ?? self.parent.currentURL ?? self.parent.url
                self.parent.onComplete(.success(targetURL))
            }
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            DispatchQueue.main.async {
                self.parent.isLoading = true
                self.parent.canGoBack = webView.canGoBack
                self.parent.canGoForward = webView.canGoForward
                if let u = webView.url {
                    self.parent.currentURL = u
                }
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            DispatchQueue.main.async {
                self.parent.isLoading = false
                self.parent.canGoBack = webView.canGoBack
                self.parent.canGoForward = webView.canGoForward
                if let u = webView.url {
                    self.parent.currentURL = u
                }
            }

            if let currentURL = webView.url {
                let host = currentURL.host?.lowercased() ?? ""
                let path = currentURL.path.lowercased()
                let isLocalHost = host == "127.0.0.1" || host == "localhost"
                let isCallbackPath = path.contains("/callback") ||
                                     path.contains("device/success") ||
                                     path.contains("auth/success") ||
                                     path.contains("auth/complete") ||
                                     path.contains("auth/return") ||
                                     path.contains("auth/finished") ||
                                     path.contains("authenticated") ||
                                     path.contains("/success")

                if isLocalHost || isCallbackPath {
                    triggerCompletion(withURL: currentURL)
                    return
                }
                // Nothing else to do here. The access portal is a normal hop on the
                // way to the CLI's callback, not a stall: re-loading the authorize
                // URL when it appears consumed a one-shot request mid-flight and
                // showed the user a sign-in error on a login that had succeeded.
            }

            let checkJS = """
            (function() {
                var text = (document.body ? document.body.innerText : '') || '';
                var title = document.title || '';
                var lowerText = text.toLowerCase();
                var lowerTitle = title.toLowerCase();
                return lowerText.includes('authentication complete') ||
                       lowerText.includes('you may now close this window') ||
                       lowerText.includes('you can close this window') ||
                       lowerText.includes('you may close this window') ||
                       lowerText.includes('successfully authenticated') ||
                       lowerText.includes('login successful') ||
                       lowerText.includes('request approved') ||
                       lowerText.includes('code verified') ||
                       lowerText.includes('device authorized') ||
                       lowerText.includes('successfully authorized') ||
                       lowerText.includes('request authorized') ||
                       lowerTitle.includes('authentication complete');
            })();
            """
            webView.evaluateJavaScript(checkJS) { [weak self] result, _ in
                if let isComplete = result as? Bool, isComplete {
                    self?.triggerCompletion()
                }
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if let url = navigationAction.request.url {
                DispatchQueue.main.async {
                    self.parent.currentURL = url
                }
                if let scheme = parent.callbackURLScheme, url.scheme?.lowercased() == scheme.lowercased() {
                    parent.onComplete(.success(url))
                    decisionHandler(.cancel)
                    return
                }
            }
            decisionHandler(.allow)
        }
    }
}
