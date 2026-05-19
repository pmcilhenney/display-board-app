import SwiftUI
import WebKit
import Security

// MARK: - AppConfig for reading managed AppConfig
struct AppConfig {
    static let localHomepageURLKey = "homepageURL"

    static var managed: [String: Any]? {
        UserDefaults.standard.dictionary(forKey: "com.apple.configuration.managed")
    }

    static var hasManagedHomepageURL: Bool {
        managedHomepageURL != nil
    }

    static var managedHomepageURL: String? {
        guard let managedConfig = managed,
              let url = managedConfig["homepageURL"] as? String else {
            return nil
        }

        return normalizedURLString(url)
    }

    static func homepageURL(localURL: String? = UserDefaults.standard.string(forKey: localHomepageURLKey)) -> String? {
        managedHomepageURL ?? normalizedURLString(localURL)
    }

    static func normalizedURLString(_ urlString: String?) -> String? {
        guard let urlString else { return nil }

        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let url = URL(string: trimmed), url.scheme != nil, url.host != nil {
            return url.absoluteString
        }

        let httpsURLString = "https://\(trimmed)"
        if let url = URL(string: httpsURLString), url.host != nil {
            return url.absoluteString
        }

        return nil
    }

    /// Optional: set this in Jamf AppConfig if you need to select a specific identity
    /// Example:
    /// <key>clientCertLabel</key>
    /// <string>org-youraladtecsystemname</string>
    static var clientCertLabel: String? {
        if let managedConfig = managed,
           let label = managedConfig["clientCertLabel"] as? String,
           !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return label
        }
        return nil
    }
}

// MARK: - Keychain helper to fetch a client identity (SecIdentity)
enum ClientIdentity {
    static func findIdentity(preferredLabel: String? = nil) -> SecIdentity? {
        // Base query: search identities (certificate + private key)
        var query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]

        // If a label is provided, try to match it first.
        // Note: Label matching behavior can vary by how the identity was installed.
        if let label = preferredLabel {
            query[kSecAttrLabel as String] = label
            if let identity = firstIdentity(matching: query) {
                return identity
            }

            // Fallback: remove label filter and continue
            query.removeValue(forKey: kSecAttrLabel as String)
        }

        // No label match, or no label provided: return the first identity found.
        return firstIdentity(matching: query)
    }

    private static func firstIdentity(matching query: [String: Any]) -> SecIdentity? {
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        guard status == errSecSuccess else { return nil }

        // If we asked for "all", we may get an array; if not, a single ref.
        if let array = item as? [Any], let first = array.first {
            return (first as! SecIdentity)
        } else if let identity = item {
            return (identity as! SecIdentity)
        }

        return nil
    }
}

// MARK: - WebView wrapper
struct WebView: UIViewRepresentable {
    let urlString: String
    @Binding var didFail: Bool

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator

        if let url = URL(string: urlString) {
            let req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
            webView.load(req)
        } else {
            didFail = true
        }

        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        guard let url = URL(string: urlString),
              uiView.url?.absoluteString != url.absoluteString else {
            return
        }

        let req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        uiView.load(req)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(didFail: $didFail)
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        @Binding var didFail: Bool

        init(didFail: Binding<Bool>) {
            _didFail = didFail
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            didFail = true
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            didFail = true
        }

        // Critical: handle TLS authentication challenges (client certificate)
        func webView(_ webView: WKWebView,
                     didReceive challenge: URLAuthenticationChallenge,
                     completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {

            let method = challenge.protectionSpace.authenticationMethod

            // 1) Client Certificate (mTLS): this is the Aladtec kiosk cert case.
            if method == NSURLAuthenticationMethodClientCertificate {
                if let identity = ClientIdentity.findIdentity(preferredLabel: AppConfig.clientCertLabel) {
                    var cert: SecCertificate?
                    SecIdentityCopyCertificate(identity, &cert)

                    let certs: [Any] = cert != nil ? [cert!] : []
                    let credential = URLCredential(identity: identity,
                                                  certificates: certs,
                                                  persistence: .forSession)

                    completionHandler(.useCredential, credential)
                    return
                } else {
                    // No identity available to the app: fail the load.
                    didFail = true
                    completionHandler(.cancelAuthenticationChallenge, nil)
                    return
                }
            }

            // 2) Server Trust: generally allow default handling.
            // If you have a private CA and need to trust it, that should be done via profiles (not here).
            if method == NSURLAuthenticationMethodServerTrust,
               let trust = challenge.protectionSpace.serverTrust {
                completionHandler(.useCredential, URLCredential(trust: trust))
                return
            }

            // 3) Anything else: default handling.
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

// MARK: - Main Content View
struct ContentView: View {
    private let maintenanceTapLimit = 7
    private let maintenanceTapWindow: TimeInterval = 5

    @AppStorage(AppConfig.localHomepageURLKey) private var localHomepageURL = ""
    @State private var didFail = false
    @State private var maintenanceTapCount = 0
    @State private var firstMaintenanceTapDate: Date?

    private var homepageURL: String? {
        AppConfig.homepageURL(localURL: localHomepageURL)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            content

            Color.clear
                .frame(width: 96, height: 96)
                .contentShape(Rectangle())
                .onTapGesture {
                    registerMaintenanceTap()
                }
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var content: some View {
        if let homepageURL, !didFail {
            WebView(urlString: homepageURL, didFail: $didFail)
                .id(homepageURL)
                .edgesIgnoringSafeArea(.all)
        } else {
            SetupLandingPage(
                initialURL: localHomepageURL,
                hasManagedURL: AppConfig.hasManagedHomepageURL,
                didFail: didFail,
                onSave: { newURL in
                    localHomepageURL = newURL
                    didFail = false
                    resetMaintenanceTapSequence()
                },
                onRetry: {
                    didFail = false
                    resetMaintenanceTapSequence()
                }
            )
        }
    }

    private func registerMaintenanceTap() {
        guard !AppConfig.hasManagedHomepageURL else {
            resetMaintenanceTapSequence()
            return
        }

        let now = Date()
        if let firstMaintenanceTapDate,
           now.timeIntervalSince(firstMaintenanceTapDate) <= maintenanceTapWindow {
            maintenanceTapCount += 1
        } else {
            firstMaintenanceTapDate = now
            maintenanceTapCount = 1
        }

        guard maintenanceTapCount >= maintenanceTapLimit else { return }

        localHomepageURL = ""
        didFail = false
        resetMaintenanceTapSequence()
    }

    private func resetMaintenanceTapSequence() {
        maintenanceTapCount = 0
        firstMaintenanceTapDate = nil
    }
}

// MARK: - Local setup page
struct SetupLandingPage: View {
    let initialURL: String
    let hasManagedURL: Bool
    let didFail: Bool
    let onSave: (String) -> Void
    let onRetry: () -> Void

    @State private var urlString: String
    @State private var validationMessage: String?

    init(
        initialURL: String,
        hasManagedURL: Bool,
        didFail: Bool,
        onSave: @escaping (String) -> Void,
        onRetry: @escaping () -> Void
    ) {
        self.initialURL = initialURL
        self.hasManagedURL = hasManagedURL
        self.didFail = didFail
        self.onSave = onSave
        self.onRetry = onRetry
        _urlString = State(initialValue: initialURL)
    }

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground)
                .ignoresSafeArea()

            VStack(spacing: 28) {
                VStack(spacing: 12) {
                    Image("gcemsLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 180)

                    Text("Display Board Setup")
                        .font(.system(size: 36, weight: .bold, design: .rounded))

                    Text(statusText)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 680)
                }

                VStack(spacing: 16) {
                    TextField("https://example.com/display", text: $urlString)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .disabled(hasManagedURL)
                        .padding(16)
                        .background(Color(.secondarySystemGroupedBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color(.separator), lineWidth: 1)
                        }

                    if let validationMessage {
                        Text(validationMessage)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    HStack(spacing: 12) {
                        Button("Retry") {
                            onRetry()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)

                        Button("Save and Launch") {
                            save()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(hasManagedURL)
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .frame(maxWidth: 720)
            }
            .padding(32)
        }
    }

    private var statusText: String {
        if hasManagedURL {
            return didFail
                ? "The managed display URL could not be loaded. Check the network, certificate, or Jamf AppConfig value, then retry."
                : "This device is configured by MDM. The managed display URL will be used automatically."
        }

        return didFail
            ? "The saved display URL could not be loaded. Update it below, then launch again."
            : "Enter the display URL for this device. Jamf AppConfig can still manage this later by setting homepageURL."
    }

    private func save() {
        guard let normalizedURL = AppConfig.normalizedURLString(urlString) else {
            validationMessage = "Enter a valid URL."
            return
        }

        validationMessage = nil
        onSave(normalizedURL)
    }
}
