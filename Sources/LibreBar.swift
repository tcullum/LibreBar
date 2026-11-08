import AppKit
import SwiftUI
import Charts
import Security
import CryptoKit
import ServiceManagement

struct Credentials: Codable { var email: String; var password: String }
enum Vault {
    static let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "local.librebar.credentials", kSecAttrAccount as String: "LibreLinkUp"]
    static func load() -> Credentials? {
        var q = query; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(Credentials.self, from: data)
    }
    static func save(_ credentials: Credentials) throws {
        let data = try JSONEncoder().encode(credentials)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var q = query; q[kSecValueData as String] = data; q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(q as CFDictionary, nil) == errSecSuccess else { throw Failure("Couldn’t save sign-in details in Keychain.") }; return
        }
        guard status == errSecSuccess else { throw Failure("Couldn’t update sign-in details in Keychain.") }
    }
    static func clear() { SecItemDelete(query as CFDictionary) }
}
struct Failure: LocalizedError { let message: String; init(_ message: String) { self.message = message }; var errorDescription: String? { message } }
struct Reading {
    let mg: Double; let date: Date?; let trend: Int
    static func parse(_ json: [String: Any]) throws -> Reading {
        guard let mg = json["ValueInMgPerDl"] as? Double, mg > 0 else { throw Failure("No glucose reading available yet.") }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "M/d/yyyy h:mm:ss a"
        let date = (json["FactoryTimestamp"] as? String).flatMap { formatter.date(from: $0) }
        return Reading(mg: mg, date: date, trend: json["TrendArrow"] as? Int ?? 0)
    }
    func inRange(_ range: GlucoseRange) -> Bool { (range.low...range.high).contains(mg) }
    var arrow: String { [1: "↓", 2: "↘", 3: "→", 4: "↗", 5: "↑"][trend] ?? "" }
    func value(mmol: Bool) -> String { mmol ? String(format: "%.1f", mg / 18.0) : String(format: "%.0f", mg) }
    func stale(at now: Date = Date()) -> Bool { guard let date else { return true }; return now.timeIntervalSince(date) > 300 || date.timeIntervalSince(now) > 120 }
}
struct GlucoseRange {
    let low: Double
    let high: Double
    static let standard = GlucoseRange(low: 70, high: 180)
    static func parse(_ connection: [String: Any]) -> GlucoseRange? {
        guard let low = connection["targetLow"] as? NSNumber, let high = connection["targetHigh"] as? NSNumber,
              CFGetTypeID(low) != CFBooleanGetTypeID(), CFGetTypeID(high) != CFBooleanGetTypeID(),
              low.doubleValue.isFinite, high.doubleValue.isFinite,
              low.doubleValue > 0, high.doubleValue > low.doubleValue else { return nil }
        return GlucoseRange(low: low.doubleValue, high: high.doubleValue)
    }
    func label(mmol: Bool) -> String {
        mmol ? String(format: "%.1f–%.1f mmol/L", low / 18, high / 18) : String(format: "%.0f–%.0f mg/dL", low, high)
    }
}
struct GraphHistory {
    let readings: [Reading]
    let range: GlucoseRange?
}
enum PanelPlacement {
    static func frame(anchor: NSRect, visible: NSRect, size: NSSize) -> NSRect {
        let margin: CGFloat = 8
        let width = min(size.width, visible.width - margin * 2)
        let height = min(size.height, visible.height - margin * 2)
        let x = min(max(anchor.midX - width / 2, visible.minX + margin), visible.maxX - width - margin)
        let top = min(anchor.minY - margin, visible.maxY - margin)
        return NSRect(x: x, y: max(visible.minY + margin, top - height), width: width, height: height)
    }
}
final class HistoryPanel: NSPanel {
    override func cancelOperation(_ sender: Any?) { orderOut(sender) }
}
enum History {
    static func window(_ readings: [Reading], now: Date = Date()) -> [Reading] {
        var unique: [Date: Reading] = [:]
        for reading in readings {
            guard let date = reading.date, date >= now.addingTimeInterval(-43200), date <= now else { continue }
            unique[date] = reading
        }
        return unique.keys.sorted().compactMap { unique[$0] }
    }
}
struct Person { let id: String; let name: String; let reading: Reading? }
actor LibreAPI {
    static let hosts = ["us":"api-us.libreview.io", "eu":"api-eu.libreview.io", "eu2":"api-eu2.libreview.io", "de":"api-de.libreview.io", "fr":"api-fr.libreview.io", "jp":"api-jp.libreview.io", "ap":"api-ap.libreview.io", "au":"api-au.libreview.io", "ae":"api-ae.libreview.io", "ca":"api-ca.libreview.io", "la":"api-la.libreview.io", "ru":"api.libreview.ru", "cn":"api-cn.myfreestyle.cn"]
    var host = "api.libreview.io"; var token = ""; var account = ""
    let session: URLSession = { let c = URLSessionConfiguration.ephemeral; c.timeoutIntervalForRequest = 25; c.httpCookieStorage = nil; return URLSession(configuration: c) }()
    func reset() { token = ""; account = ""; host = "api.libreview.io" }
    func request(_ path: String, body: [String: String]? = nil) async throws -> [String: Any] {
        var r = URLRequest(url: URL(string: "https://\(host)\(path)")!); r.httpMethod = body == nil ? "GET" : "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type"); r.setValue("llu.ios", forHTTPHeaderField: "product"); r.setValue("4.16.0", forHTTPHeaderField: "version")
        if !token.isEmpty { r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization"); r.setValue(account, forHTTPHeaderField: "Account-Id") }
        if let body { r.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, response) = try await session.data(for: r)
        guard let http = response as? HTTPURLResponse else { throw Failure("No response from LibreLinkUp.") }
        if http.statusCode == 401 || http.statusCode == 403 { token = ""; throw Failure("Sign-in expired or was rejected. Check your LibreLinkUp account in Settings.") }
        guard (200..<300).contains(http.statusCode) else { throw Failure("LibreLinkUp returned an error (\(http.statusCode)). Try again later.") }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure("Unexpected LibreLinkUp response.") }
        return json
    }
    func login(_ credentials: Credentials) async throws {
        for _ in 0..<3 {
            let json = try await request("/llu/auth/login", body: ["email": credentials.email, "password": credentials.password])
            let data = json["data"] as? [String: Any] ?? [:]
            if data["redirect"] as? Bool == true, let region = data["region"] as? String, let next = Self.hosts[region.lowercased()] { host = next; continue }
            if let step = data["step"] as? [String: Any], step["type"] != nil { throw Failure("Open the official LibreLinkUp app to finish verification or accept updated terms, then retry.") }
            guard (json["status"] as? Int ?? -1) == 0, let ticket = data["authTicket"] as? [String: Any], let t = ticket["token"] as? String, let user = data["user"] as? [String: Any], let id = user["id"] as? String else { throw Failure("Sign-in failed. Use your LibreLinkUp follower account and verify it works in the official app.") }
            token = t; account = SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined(); return
        }
        throw Failure("Couldn’t resolve your account’s region.")
    }
    func history(for patient: String) async throws -> GraphHistory {
        guard let escaped = patient.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { throw Failure("Invalid connection.") }
        let json = try await request("/llu/connections/\(escaped)/graph")
        guard json["status"] as? Int == 0, let data = json["data"] as? [String: Any], let graph = data["graphData"] as? [[String: Any]] else { throw Failure("History is unavailable. Try refreshing.") }
        return GraphHistory(readings: graph.compactMap { try? Reading.parse($0) }, range: GlucoseRange.parse(data["connection"] as? [String: Any] ?? [:]))
    }
    func fetch(_ credentials: Credentials) async throws -> [Person] {
        if token.isEmpty { try await login(credentials) }
        let json = try await request("/llu/connections")
        guard (json["status"] as? Int ?? -1) == 0, let list = json["data"] as? [[String: Any]] else { throw Failure("Couldn’t read shared connections. Try signing in again.") }
        return list.compactMap { item in
            guard let id = item["patientId"] as? String else { return nil }
            let name = [item["firstName"] as? String, item["lastName"] as? String].compactMap { $0 }.joined(separator: " ")
            return Person(id: id, name: name.isEmpty ? "Shared connection" : name, reading: (item["glucoseMeasurement"] as? [String: Any]).flatMap { try? Reading.parse($0) })
        }
    }
}

@MainActor
final class Model: ObservableObject {
    @Published var message = "Sign in to LibreLinkUp to get started."
    @Published var busy = false
    @Published var people: [Person] = []
    @Published var history: [Reading] = []
    @Published var targetRange: GlucoseRange?
    var displayRange: GlucoseRange { targetRange ?? .standard }
    @Published var historyMessage = ""
    @Published var reading: Reading?
    let api = LibreAPI()
    var credentials = Vault.load()
    var onUpdate: (() -> Void)?
    var generation = 0
    var selected: String { get { UserDefaults.standard.string(forKey: "person") ?? "" } set { UserDefaults.standard.set(newValue, forKey: "person"); history = []; historyMessage = ""; targetRange = nil; chooseReading(); Task { await refresh() } } }
    var mmol: Bool { get { UserDefaults.standard.bool(forKey: "mmol") } set { UserDefaults.standard.set(newValue, forKey: "mmol"); objectWillChange.send(); onUpdate?() } }
    func chooseReading() {
        reading = people.first(where: { $0.id == selected })?.reading
        onUpdate?()
    }
    func save(email: String, password: String) async {
        do {
            let c = Credentials(email: email.trimmingCharacters(in: .whitespacesAndNewlines), password: password)
            guard !c.email.isEmpty && !c.password.isEmpty else { throw Failure("Enter your LibreLinkUp email and password.") }
            try Vault.save(c); generation += 1; credentials = c; reading = nil; people = []; history = []; historyMessage = ""; targetRange = nil; await api.reset(); await refresh()
        } catch { message = error.localizedDescription; onUpdate?() }
    }
    func signOut() { generation += 1; credentials = nil; Vault.clear(); people = []; reading = nil; history = []; historyMessage = ""; targetRange = nil; message = "Signed out."; Task { await api.reset() }; onUpdate?() }
    func refresh() async {
        guard !busy, let credentials else { onUpdate?(); return }
        busy = true; onUpdate?(); let current = generation
        defer { busy = false; onUpdate?() }
        do {
            let fetched = try await api.fetch(credentials)
            guard current == generation else { return }
            people = fetched
            if people.count == 1 && selected != people[0].id { selected = people[0].id }
            chooseReading()
            if people.isEmpty { message = "No shared connections. In your Libre app, open Connected Apps → LibreLinkUp and invite this follower account. Accept the invitation in LibreLinkUp." }
            else if !people.contains(where: { $0.id == selected }) { message = "Choose your connection from the menu bar menu." }
            else if reading == nil { message = "Connected. Waiting for a glucose reading." }
            else { message = "Connected to LibreLinkUp." }
            let patient = selected
            guard people.contains(where: { $0.id == patient }) else { history = []; targetRange = nil; return }
            do {
                let fetchedHistory = try await api.history(for: patient)
                guard current == generation, patient == selected else { return }
                targetRange = fetchedHistory.range
                history = History.window(fetchedHistory.readings + [reading].compactMap { $0 })
                historyMessage = history.isEmpty ? "No readings available in the last 12 hours." : ""
            } catch {
                guard current == generation, patient == selected else { return }
                history = History.window(history + [reading].compactMap { $0 })
                historyMessage = "Couldn’t update history. " + error.localizedDescription
            }
        } catch { if current == generation { message = error.localizedDescription } }
    }
}
struct HistoryView: View {
    @ObservedObject var model: Model
    let settings: () -> Void
    let options: () -> Void
    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let points = History.window(model.history, now: context.date)
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("LibreBar").font(.headline)
                    Spacer()
                    Text("Last 12 hours").foregroundStyle(.secondary)
                }
                if let reading = model.reading {
                    HStack(alignment: .firstTextBaseline) {
                        Text("\(reading.value(mmol: model.mmol)) \(reading.arrow)").font(.system(size: 34, weight: .semibold, design: .rounded))
                        Text(model.mmol ? "mmol/L" : "mg/dL").foregroundStyle(.secondary)
                        Spacer()
                    }
                    if reading.inRange(model.displayRange) {
                        Label("Glucose In Range", systemImage: "checkmark.circle.fill")
                            .font(.callout.weight(.medium)).foregroundStyle(.green)
                    }
                    if let date = reading.date {
                        Text("Updated \(date.formatted(date: .omitted, time: .shortened))\(reading.stale(at: context.date) ? " · Stale reading" : "")").font(.caption).foregroundStyle(.secondary)
                    } else { Text("Reading time unavailable").font(.caption).foregroundStyle(.secondary) }
                }
                if points.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "chart.xyaxis.line").font(.largeTitle).foregroundStyle(.secondary)
                        Text(model.busy ? "Loading history…" : "No history available yet")
                    }.frame(maxWidth: .infinity).frame(height: 200)
                } else {
                    Text("\(model.targetRange == nil ? "Default range" : "LibreLinkUp range"): \(model.displayRange.label(mmol: model.mmol))")
                        .font(.caption).foregroundStyle(.secondary)
                    Chart {
                        RectangleMark(yStart: .value("Range minimum", model.mmol ? model.displayRange.low / 18 : model.displayRange.low), yEnd: .value("Range maximum", model.mmol ? model.displayRange.high / 18 : model.displayRange.high))
                            .foregroundStyle(Color.green.opacity(0.14))
                            .accessibilityLabel("Target range: \(model.displayRange.label(mmol: model.mmol))")
                        ForEach(Array(points.enumerated()), id: \.offset) { index, reading in
                        if let date = reading.date {
                            let segment = points.prefix(index + 1).enumerated().filter { i, point in i > 0 && point.date!.timeIntervalSince(points[i - 1].date!) > 1200 }.count
                            LineMark(x: .value("Time", date), y: .value("Glucose", model.mmol ? reading.mg / 18 : reading.mg), series: .value("Segment", segment))
                                .foregroundStyle(Color.accentColor)
                            PointMark(x: .value("Time", date), y: .value("Glucose", model.mmol ? reading.mg / 18 : reading.mg)).symbolSize(12).foregroundStyle(Color.accentColor)
                        }
                        }
                    }
                    .chartXScale(domain: context.date.addingTimeInterval(-43200)...context.date)
                    .chartXAxis { AxisMarks(values: .stride(by: .hour, count: 3)) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.hour()) } }
                    .chartYAxis { AxisMarks(position: .leading) }
                    .frame(height: 210)
                    .accessibilityLabel("Glucose readings over the last 12 hours")
                }
                if !model.historyMessage.isEmpty { Text(model.historyMessage).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                Text(model.message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Divider()
                HStack {
                    Button(model.busy ? "Refreshing…" : "Refresh") { Task { await model.refresh() } }.disabled(model.busy)
                    Button("Settings…", action: settings)
                    Spacer()
                    Button("Options", action: options)
                }
            }.padding(20).frame(width: 440)
        }
    }
}
struct SettingsView: View {
    @ObservedObject var model: Model
    @State private var email = ""
    @State private var password = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("LibreBar").font(.largeTitle.bold())
            Text("Your glucose, at a glance.").font(.title3).foregroundStyle(.secondary)
            Text("Sign in with a LibreLinkUp follower account. In the Libre app, use Connected Apps → LibreLinkUp to share your readings with that account. Accept the invitation in LibreLinkUp first.").fixedSize(horizontal: false, vertical: true)
            TextField("LibreLinkUp email", text: $email).textFieldStyle(.roundedBorder)
            SecureField("Password", text: $password).textFieldStyle(.roundedBorder)
            HStack {
                Button("Save & Connect") { Task { await model.save(email: email, password: password); password = "" } }.keyboardShortcut(.defaultAction).disabled(model.busy)
                if model.busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Sign Out") { model.signOut(); password = "" }.disabled(model.busy || model.credentials == nil)
            }
            Text(model.message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Divider()
            Text("Sign-in details are saved in macOS Keychain and sent only to Abbott’s LibreLinkUp service. Readings refresh every minute while your Mac is awake.").font(.caption).foregroundStyle(.secondary)
            Text("Unofficial convenience display. Use the Libre app for treatment decisions and alarms. ⚠︎ means the reading is over 5 minutes old or its time is unavailable.").font(.caption).foregroundStyle(.secondary)
        }.padding(28).frame(width: 440).onAppear { email = model.credentials?.email ?? "" }
    }
}
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = Model()
    var status: NSStatusItem!
    var window: NSWindow?
    var timer: Timer?
    var historyPanel: HistoryPanel!
    var outsideClickMonitor: Any?
    var localClickMonitor: Any?
    func applicationDidFinishLaunching(_ notification: Notification) {
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        historyPanel = HistoryPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 460), styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        historyPanel.title = "LibreBar · Last 12 hours"
        historyPanel.isReleasedWhenClosed = false
        historyPanel.level = .floating
        historyPanel.hidesOnDeactivate = false
        historyPanel.contentViewController = NSHostingController(rootView: HistoryView(model: model, settings: { [weak self] in self?.historyPanel.orderOut(nil); self?.settings() }, options: { [weak self] in self?.showOptions() }))
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self else { return }
            let point = NSEvent.mouseLocation
            if self.historyPanel.frame.contains(point) { return }
            if let button = self.status.button, let window = button.window,
               window.convertToScreen(button.convert(button.bounds, to: nil)).contains(point) { return }
            self.historyPanel.orderOut(nil)
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            if let self, event.window !== self.historyPanel, event.window !== self.status.button?.window { self.historyPanel.orderOut(nil) }
            return event
        }
        status.button?.target = self
        status.button?.action = #selector(toggleHistory)
        model.onUpdate = { [weak self] in self?.render() }
        render()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in Task { @MainActor in await self?.model.refresh() } }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(woke), name: NSWorkspace.didWakeNotification, object: nil)
        if model.credentials == nil { settings() }
        Task { await model.refresh() }
        if CommandLine.arguments.contains("--ui-smoke-test") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                self.toggleHistory()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    let frame = self.historyPanel.frame
                    let visible = NSScreen.screens.contains { $0.visibleFrame.contains(frame) }
                    print("UI smoke: panelVisible=\(self.historyPanel.isVisible), insideScreen=\(visible), width=\(frame.width), height=\(frame.height)")
                    self.historyPanel.cancelOperation(nil)
                    print("UI smoke: escapeDismissed=\(!self.historyPanel.isVisible)")
                    NSApp.terminate(nil)
                }
            }
        }
    }
    @objc func woke() { render(); Task { await model.refresh() } }
    func render() {
        let title: String
        if let r = model.reading { title = "\(r.stale() ? "⚠︎ " : "")\(r.value(mmol: model.mmol)) \(r.arrow)" }
        else { title = "◉ —" }
        status.button?.title = title
        status.button?.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        status.button?.toolTip = "LibreBar · \(model.message)"
        let menu = NSMenu()
        @discardableResult func item(_ title: String, _ action: Selector? = nil) -> NSMenuItem { let i = NSMenuItem(title: title, action: action, keyEquivalent: ""); i.target = self; menu.addItem(i); return i }
        if let r = model.reading {
            item("\(r.value(mmol: model.mmol)) \(model.mmol ? "mmol/L" : "mg/dL") \(r.arrow)")
            if let date = r.date { item("Reading: \(date.formatted(date: .abbreviated, time: .standard))") } else { item("Reading time unavailable") }
            if r.stale() { item("⚠︎ Stale reading — check your Libre app") }
        }
        item(model.message)
        menu.addItem(.separator())
        if model.people.count > 1 {
            for p in model.people { let i = item(p.name, #selector(selectPerson(_:))); i.representedObject = p.id; i.state = p.id == model.selected ? .on : .off }
            menu.addItem(.separator())
        }
        item(model.busy ? "Refreshing…" : "Refresh Now", #selector(refresh)).isEnabled = !model.busy
        let units = item("Show mmol/L", #selector(toggleUnits)); units.state = model.mmol ? .on : .off
        let launch = item("Launch at Login", #selector(toggleLogin)); launch.state = SMAppService.mainApp.status == .enabled ? .on : .off
        item("Settings…", #selector(settings))
        menu.addItem(.separator())
        item("Quit LibreBar", #selector(quit))
        optionsMenu = menu
    }
    var optionsMenu: NSMenu?
    @objc func toggleHistory() {
        if historyPanel.isVisible { historyPanel.orderOut(nil); return }
        guard let button = status.button, let buttonWindow = button.window,
              let screen = buttonWindow.screen ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let fitting = NSSize(width: 440, height: 520)
        let size = historyPanel.frameRect(forContentRect: NSRect(origin: .zero, size: fitting)).size
        historyPanel.setFrame(PanelPlacement.frame(anchor: anchor, visible: screen.visibleFrame, size: size), display: true)
        NSApp.activate(ignoringOtherApps: true)
        historyPanel.makeKeyAndOrderFront(nil)
        Task { await model.refresh() }
    }
    func showOptions() {
        historyPanel.orderOut(nil)
        guard let button = status.button, let menu = optionsMenu else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY), in: button)
    }
    @objc func selectPerson(_ sender: NSMenuItem) { if let id = sender.representedObject as? String { model.selected = id } }
    @objc func refresh() { Task { await model.refresh() } }
    @objc func toggleUnits() { model.mmol.toggle() }
    @objc func toggleLogin() {
        do { if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() }; render() }
        catch { model.message = "Couldn’t change login setting. Check System Settings → General → Login Items."; render() }
    }
    @objc func settings() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 496, height: 510), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "LibreBar Settings"; w.contentView = NSHostingView(rootView: SettingsView(model: model)); w.isReleasedWhenClosed = false; w.center(); window = w
        }
        NSApp.activate(ignoringOtherApps: true); window?.makeKeyAndOrderFront(nil)
    }
    @objc func quit() { NSApp.terminate(nil) }
}
if CommandLine.arguments.contains("--self-test") {
    let r = try Reading.parse(["ValueInMgPerDl": 126.0, "TrendArrow": 4, "FactoryTimestamp": "11/2/2026 10:30:00 PM"])
    precondition(r.value(mmol: false) == "126" && r.value(mmol: true) == "7.0" && r.arrow == "↗")
    precondition(r.date != nil && !r.stale(at: r.date!.addingTimeInterval(60)) && r.stale(at: r.date!.addingTimeInterval(301)))
    precondition(try! Reading.parse(["ValueInMgPerDl": 100.0]).stale())
    do { _ = try Reading.parse([:]); fatalError("Missing value accepted") } catch {}
    for visible in [NSRect(x: 0, y: 0, width: 1440, height: 875), NSRect(x: -1920, y: 100, width: 1920, height: 1055)] {
        for x in [visible.minX, visible.midX, visible.maxX - 20] {
            let frame = PanelPlacement.frame(anchor: NSRect(x: x, y: visible.maxY, width: 20, height: 25), visible: visible, size: NSSize(width: 440, height: 480))
            precondition(visible.contains(frame) && frame.maxY <= visible.maxY - 8, "History panel must stay below the menu bar and inside its screen")
        }
    }
    for (mg, expected) in [(69.9, false), (70.0, true), (126.0, true), (180.0, true), (180.1, false)] {
        precondition(Reading(mg: mg, date: Date(), trend: 0).inRange(.standard) == expected, "Range must include 70 and 180 and exclude values outside them")
    }
    let customRange = GlucoseRange.parse(["targetLow": 80, "targetHigh": 150])!
    precondition(!Reading(mg: 75, date: nil, trend: 0).inRange(customRange))
    precondition(Reading(mg: 80, date: nil, trend: 0).inRange(customRange))
    precondition(Reading(mg: 150, date: nil, trend: 0).inRange(customRange))
    precondition(!Reading(mg: 151, date: nil, trend: 0).inRange(customRange))
    precondition(customRange.label(mmol: true) == "4.4–8.3 mmol/L")
    for invalid: [String: Any] in [[:], ["targetLow": 70], ["targetLow": 180, "targetHigh": 70], ["targetLow": 0, "targetHigh": 180], ["targetLow": true, "targetHigh": 180], ["targetLow": 70, "targetHigh": Double.infinity]] {
        precondition(GlucoseRange.parse(invalid) == nil, "Invalid targets must use the labeled default")
    }
    let now = Date(timeIntervalSince1970: 1800000000)
    let points = History.window([
        Reading(mg: 90, date: now.addingTimeInterval(-43201), trend: 0),
        Reading(mg: 100, date: now.addingTimeInterval(-3600), trend: 0),
        Reading(mg: 110, date: now.addingTimeInterval(-60), trend: 0),
        Reading(mg: 110, date: now.addingTimeInterval(-60), trend: 0),
        Reading(mg: 120, date: nil, trend: 0),
        Reading(mg: 130, date: now.addingTimeInterval(60), trend: 0)
    ], now: now)
    precondition(points.count == 2 && points.first?.mg == 100 && points.last?.mg == 110, "History must sort, deduplicate, and exclude missing, future, and old timestamps")
    print("PASS: glucose parsing, units, trend, UTC timestamps, stale/missing data, 12-hour history filtering, sorting, deduplication, API target parsing, custom range boundaries and fallback")
} else {
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        let delegate = AppDelegate(); app.delegate = delegate; app.setActivationPolicy(.accessory); app.run()
    }
}
