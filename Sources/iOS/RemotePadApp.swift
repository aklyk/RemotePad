import SwiftUI
#if canImport(RemotePadCore)
import RemotePadCore
#endif

@main
struct RemotePadApp: App {
    var body: some Scene { WindowGroup { RemotePadView() } }
}

struct RemotePadView: View {
    @StateObject private var connection = PhoneConnection()
    @AppStorage("pointerSpeed") private var speed = 1.5
    @AppStorage("naturalScrolling") private var naturalScrolling = true
    @AppStorage("gestureHaptics") private var gestureHaptics = true
    private enum SettingsPanel: String, Identifiable {
        case preferences, gestures
        var id: String { rawValue }
    }
    @State private var settingsPanel: SettingsPanel?
    @State private var rotationHelp = false
    @State private var directKey = ""
    @Environment(\.scenePhase) private var scenePhase
    private let mint = Color(red: 0.64, green: 0.96, blue: 0.77)

    var body: some View {
        GeometryReader { geometry in
            if let name = connection.connectedName {
                let landscape = geometry.size.width > geometry.size.height
                connectedTrackpad(name: name, landscape: landscape)
                    .statusBarHidden(landscape)
                    .persistentSystemOverlays(landscape ? .hidden : .automatic)
                    .defersSystemGestures(on: landscape ? [.bottom, .leading, .trailing] : [])
            } else {
                ScrollView {
                    VStack(spacing: 22) {
                        header
                        connectionSetup.padding(.top, 24)
                    }.padding(24).frame(minHeight: geometry.size.height, alignment: .top)
                }
            }
        }
        .background(Color(red: 0.055, green: 0.065, blue: 0.075).ignoresSafeArea())
        .foregroundStyle(.white).tint(mint).preferredColorScheme(.dark)
        .sheet(item: $settingsPanel) { panel in settings(panel) }
        .alert("Turn your iPhone sideways", isPresented: $rotationHelp) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("If the screen stays upright, turn off Portrait Orientation Lock in Control Center.")
        }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .active: connection.resume()
            case .inactive: connection.releaseDrag()
            case .background: connection.suspend()
            @unknown default: break
            }
            UIApplication.shared.isIdleTimerDisabled = phase == .active && connection.connectedName != nil
        }
        .onChange(of: connection.connectedName) { name in UIApplication.shared.isIdleTimerDisabled = name != nil }
        .onChange(of: connection.mode) { _ in directKey = "" }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 6) {
                Text("REMOTE / 01").font(.system(size: 10, weight: .bold, design: .monospaced)).tracking(3).foregroundStyle(mint)
                Text("Your Mac, in hand.").font(.system(size: 28, weight: .semibold, design: .rounded)).minimumScaleFactor(0.7).lineLimit(1)
            }
            Spacer(minLength: 8)
            Button { settingsPanel = .preferences } label: {
                Image(systemName: "slider.horizontal.3").font(.title3).frame(width: 44, height: 44).background(.white.opacity(0.06), in: Circle())
            }.accessibilityLabel("Settings and gesture guide")
        }
    }

    private func connectedTrackpad(name: String, landscape: Bool) -> some View {
        VStack(spacing: 14) {
            if !landscape { connectedHeader(name: name) }
            trackpad(fullScreen: landscape)
                .ignoresSafeArea(landscape ? .all : [])
                .overlay(alignment: .topTrailing) {
                    if landscape { landscapeControls }
                }
            if !landscape {
                HStack(spacing: 12) {
                    clickButton("Left click", icon: "computermouse", action: .leftClick)
                    clickButton("Right click", icon: "cursorarrow.click.2", action: .rightClick)
                    Button { connection.toggleDrag() } label: {
                        VStack(spacing: 8) {
                            Image(systemName: connection.dragging ? "hand.closed.fill" : "hand.draw").font(.title3)
                            Text(connection.dragging ? "Release" : "Drag").font(.caption.weight(.semibold))
                        }.frame(maxWidth: .infinity).frame(height: 64)
                            .background(connection.dragging ? mint : .white.opacity(0.06), in: RoundedRectangle(cornerRadius: 20))
                            .foregroundStyle(connection.dragging ? .black : .white)
                    }.accessibilityLabel(connection.dragging ? "Release drag" : "Start drag")
                }
                HStack {
                    Button { connection.send(MouseCommand(.previousSpace)) } label: {
                        Image(systemName: "rectangle.portrait.and.arrow.left").frame(width: 44, height: 44)
                    }.accessibilityLabel("Previous desktop space").disabled(connection.dragging)
                    Spacer()
                    Button { settingsPanel = .gestures } label: {
                        Label("Gesture guide", systemImage: "hand.tap.fill").font(.caption.weight(.semibold))
                    }.frame(minHeight: 44)
                    Spacer()
                    Button { connection.send(MouseCommand(.nextSpace)) } label: {
                        Image(systemName: "rectangle.portrait.and.arrow.right").frame(width: 44, height: 44)
                    }.accessibilityLabel("Next desktop space").disabled(connection.dragging)
                }
            }
        }.padding(landscape ? 0 : 18)
    }

    private func connectedHeader(name: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(name).font(.headline).lineLimit(1)
                    Text(connection.mouseControlEnabled == false ? "Mouse access blocked on Mac" : "\(connection.mode.label) · Connected securely")
                        .font(.caption).foregroundStyle(connection.mouseControlEnabled == false ? Color.orange : Color.secondary)
                }
                Spacer(minLength: 0)
                padButton("arrow.up.left.and.arrow.down.right", label: "Landscape trackpad") { rotate(to: .landscape) }
                padButton("slider.horizontal.3", label: "Settings") { settingsPanel = .preferences }
                padButton("xmark", label: "Disconnect from Mac") { connection.disconnect() }
            }
            if connection.mouseControlEnabled == false {
                Label("Enable RemotePad on the Mac in Privacy & Security → Accessibility.", systemImage: "hand.raised.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
        }.padding(10).background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 20))
    }

    private var landscapeControls: some View {
        HStack(spacing: 4) {
            if connection.mouseControlEnabled == false {
                Label("Enable Accessibility on Mac", systemImage: "hand.raised.fill")
                    .font(.caption).foregroundStyle(.orange).padding(.horizontal, 6)
            }
            Button { settingsPanel = .gestures } label: {
                Label("Gestures", systemImage: "hand.tap")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 10).frame(minHeight: 44).contentShape(Rectangle())
            }.accessibilityLabel("Gesture guide")
            padButton(connection.dragging ? "hand.closed.fill" : "hand.draw", label: connection.dragging ? "Release drag" : "Start drag") {
                connection.toggleDrag()
            }
            padButton("rectangle.portrait", label: "Return to portrait") { rotate(to: .portrait) }
            padButton("xmark", label: "Disconnect from Mac") { connection.disconnect() }
        }.padding(6).background(.thinMaterial, in: Capsule()).padding(8)
    }

    private func padButton(_ icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.body.weight(.semibold))
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }.accessibilityLabel(label)
    }

    private func rotate(to orientation: UIInterfaceOrientationMask) {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState == .foregroundActive }) else { return }
        connection.releaseDrag()
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: orientation)) { _ in
            if orientation == .landscape { rotationHelp = true }
        }
    }

    private func trackpad(fullScreen: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: fullScreen ? 0 : 24)
        return ZStack {
            shape.fill(Color(red: 0.095, green: 0.115, blue: 0.12))
            Canvas { context, size in
                for x in stride(from: 20.0, to: size.width, by: 22) {
                    for y in stride(from: 20.0, to: size.height, by: 22) {
                        context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 2, height: 2)), with: .color(.white.opacity(0.08)))
                    }
                }
            }.clipShape(shape).allowsHitTesting(false)
            VStack(spacing: 12) {
                Image(systemName: connection.dragging ? "hand.draw" : "cursorarrow.motionlines").font(.system(size: 30, weight: .light))
                Text(connection.dragging ? "Dragging" : "Move with one finger · Scroll with two")
                    .font(.caption.weight(.medium))
            }.foregroundStyle(mint.opacity(0.5)).allowsHitTesting(false)
            Trackpad(sensitivity: speed, naturalScrolling: naturalScrolling, haptics: gestureHaptics, dragging: $connection.dragging, send: connection.send)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }.overlay {
            if !fullScreen { shape.stroke(mint.opacity(connection.dragging ? 0.65 : 0.15), lineWidth: 1).allowsHitTesting(false) }
        }
    }
    private var connectionSetup: some View {
        VStack(alignment: .leading, spacing: 20) {
            Picker("Connection", selection: Binding(get: { connection.mode }, set: connection.selectMode)) {
                ForEach(ConnectionMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }.pickerStyle(.segmented).disabled(connection.connecting)
            if connection.mode == .nearby { discovery }
            else { directSetup }
        }
    }

    private var discovery: some View {
        VStack(alignment: .leading, spacing: 24) {
            ZStack {
                Circle().fill(mint.opacity(0.08)).frame(width: 100, height: 100)
                Image(systemName: "desktopcomputer").font(.system(size: 40, weight: .light)).foregroundStyle(mint)
            }.frame(maxWidth: .infinity).padding(.vertical, 24)
            Text("Meet your new trackpad.").font(.title2.bold())
            Text("Open RemotePad on your Mac and connect both devices to the same Wi-Fi. Your Mac will appear below.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("NEARBY MACS").font(.system(size: 11, weight: .bold, design: .monospaced)).tracking(2)
                Spacer()
                if connection.connecting { ProgressView() }
                else { Button("Refresh") { connection.refresh() }.font(.caption) }
            }
            if connection.macs.isEmpty {
                HStack(spacing: 14) {
                    ProgressView()
                    Text("Searching your local network…").font(.subheadline).foregroundStyle(.secondary)
                }.padding(22).frame(maxWidth: .infinity, alignment: .leading).background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 18))
            }
            ForEach(connection.macs) { mac in
                Button { connection.connect(mac) } label: {
                    HStack {
                        Image(systemName: "desktopcomputer").foregroundStyle(mint)
                        Text(mac.peer.displayName).font(.headline)
                        Spacer()
                        Image(systemName: "arrow.up.right").foregroundStyle(mint)
                    }.padding(22).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18))
                }.disabled(connection.connecting)
            }
            Text(connection.status).font(.callout).foregroundStyle(mint).fixedSize(horizontal: false, vertical: true)
            if connection.connecting { Button("Cancel") { connection.disconnect() } }
            Label("Encrypted connection · remembers approved pairing", systemImage: "lock.shield").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var directSetup: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(connection.mode == .usb ? "Connect by cable" : "Connect over \(connection.mode.label)")
                .font(.title2.bold())
            if !connection.connecting {
                directInstructions
                if connection.mode != .usb {
                    TextField("Mac VPN address", text: $connection.vpnAddress)
                        .accessibilityLabel("Mac VPN address")
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        .textFieldStyle(.roundedBorder)
                }
                SecureField(connection.hasDirectKey ? "Enter a new connection key (optional)" : "Connection key from Mac",
                            text: $directKey)
                    .accessibilityLabel("Connection key from Mac")
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
                Button(connection.mode == .usb ? "Listen for Mac" : "Connect") {
                    if connection.connectDirect(keyInput: directKey, manual: true) { directKey = "" }
                }.buttonStyle(.borderedProminent)
            } else {
                ProgressView()
                Button("Cancel") { connection.disconnect() }
            }
            Text(connection.status).font(.callout).foregroundStyle(mint).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var directInstructions: some View {
        if connection.mode == .usb {
            Text("Use a Lightning or USB-C data cable and trust the Mac if asked. Click Start USB in RemotePad on the Mac, then copy its connection key.")
                .foregroundStyle(.secondary)
        } else {
            Text("Connect both devices to the same \(connection.mode.label) network. On the Mac, enable VPN connections in RemotePad and copy the connection key.")
                .foregroundStyle(.secondary)
            if connection.mode == .zeroTier {
                DisclosureGroup("Set up ZeroTier") {
                    TextField("ZeroTier Network ID", text: $connection.zeroTierNetworkID)
                        .accessibilityLabel("ZeroTier Network ID")
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder)
                        .padding(.top, 8)
                    Button("Join in ZeroTier One") {
                        if let url = zeroTierJoinURL {
                            UIApplication.shared.open(url, options: [.universalLinksOnly: true]) { opened in
                                if !opened { UIApplication.shared.open(zeroTierStoreURL) }
                            }
                        }
                    }.disabled(zeroTierJoinURL == nil)
                    Button("Copy Network ID") {
                        UIPasteboard.general.string = validZeroTierNetworkID
                    }.disabled(validZeroTierNetworkID == nil)
                    Link("Get ZeroTier One", destination: zeroTierStoreURL)
                }
            } else {
                DisclosureGroup("Set up NetBird") {
                    Text("Sign in to the same NetBird network on both devices. For a self-hosted network, enter its management URL in NetBird.")
                        .foregroundStyle(.secondary).padding(.top, 8)
                    Button("Open NetBird") {
                        UIApplication.shared.open(URL(string: "netbird://")!) { opened in
                            if !opened { UIApplication.shared.open(URL(string: "https://apps.apple.com/app/id6469329339")!) }
                        }
                    }
                }
            }
        }
    }

    private let zeroTierStoreURL = URL(string: "https://apps.apple.com/app/id1084101492")!
    private var validZeroTierNetworkID: String? {
        let id = connection.zeroTierNetworkID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard id.utf8.count == 16, id.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
        return id
    }

    private var zeroTierJoinURL: URL? {
        guard let id = validZeroTierNetworkID else { return nil }
        return URL(string: "https://joinzt.com/addnetwork?nwid=" + id)
    }
    private func clickButton(_ title: String, icon: String, action: MouseCommand.Action) -> some View {
        Button { connection.send(MouseCommand(action)) } label: {
            VStack(spacing: 8) {
                Image(systemName: icon).font(.title3)
                Text(title).font(.caption.weight(.semibold))
            }.frame(maxWidth: .infinity).frame(height: 64).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 20))
        }.foregroundStyle(.white).disabled(connection.dragging)
    }
    private func settings(_ panel: SettingsPanel) -> some View {
        NavigationStack {
            Form {
                if panel == .gestures { gestureGuide }
                Section("Pointer speed") {
                    Slider(value: $speed, in: 0.5...3, step: 0.1)
                    Text(String(format: "%.1f×", speed)).foregroundStyle(.secondary)
                }
                Section("Connection") {
                    Toggle("Automatically reconnect", isOn: $connection.autoReconnect)
                    if let name = connection.rememberedMacName {
                        Label("Remembered: \(name)", systemImage: "desktopcomputer")
                        Button("Forget this Mac", role: .destructive) { connection.forgetMac() }
                    }
                    Text("After the first approval, reconnects using the selected connection when you return to RemotePad.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Preferences") {
                    Toggle("Natural scrolling", isOn: $naturalScrolling)
                    Toggle("Gesture haptics", isOn: $gestureHaptics)
                }
                if panel == .preferences { gestureGuide }
                Section("Connection help") {
                    Text("Keep the Mac companion open, allow Local Network access on both devices, and enable Accessibility for RemotePad Mac. Guest Wi-Fi or VPNs may block discovery.")
                    Text("Leaving this app releases any held mouse button. Your approved pairing is saved, so reopening can reconnect automatically.")
                }
            }.navigationTitle(panel == .gestures ? "Gesture guide" : "Settings")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { settingsPanel = nil } } }
        }.preferredColorScheme(.dark).tint(mint)
    }

    @ViewBuilder
    private var gestureGuide: some View {
        Section("One finger") {
            Label("Slide to move the pointer", systemImage: "hand.point.up")
            Label("Tap or double-tap to click", systemImage: "cursorarrow.click")
            Label("Hold, then move to drag. Lift to release.", systemImage: "hand.draw")
        }
        Section("Two fingers") {
            Label("Slide together to scroll", systemImage: "arrow.up.arrow.down")
            Label("Tap to right-click", systemImage: "hand.tap")
            Label("Pinch to zoom", systemImage: "arrow.up.left.and.arrow.down.right")
            Label("Double-tap to reset zoom", systemImage: "arrow.counterclockwise")
        }
        Section("Three fingers") {
            Label("Swipe left or right to switch spaces", systemImage: "rectangle.split.3x1")
            Label("Swipe up to open Mission Control", systemImage: "rectangle.3.group")
            Label("Swipe down to show app windows", systemImage: "macwindow.on.rectangle")
        }
        Section("Gesture compatibility") {
            Text("Zoom uses ⌘+ / ⌘− / ⌘0 in the active Mac app. Navigation uses your Mac’s Keyboard Shortcuts → Mission Control settings.")
        }
    }
}
