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
    @State private var showSettings = false
    @Environment(\.scenePhase) private var scenePhase
    private let mint = Color(red: 0.64, green: 0.96, blue: 0.77)

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 22) {
                    header
                    if let name = connection.connectedName {
                        HStack(spacing: 12) {
                            Image(systemName: "desktopcomputer").font(.title2).foregroundStyle(mint)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(name).font(.headline)
                                Text(connection.mouseControlEnabled == false ? "Mouse access blocked on Mac" : "Connected securely")
                                    .font(.caption).foregroundStyle(connection.mouseControlEnabled == false ? Color.orange : Color.secondary)
                            }
                            Spacer()
                            Button { connection.disconnect() } label: { Image(systemName: "xmark").padding(9).background(.white.opacity(0.08), in: Circle()) }
                                .accessibilityLabel("Disconnect from Mac")
                        }.padding(18).background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 22))
                        if connection.mouseControlEnabled == false {
                            Label("On your Mac, enable RemotePad in Privacy & Security → Accessibility. After an update, remove and add the app again if needed.", systemImage: "hand.raised.fill")
                                .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                        }
                        trackpad.frame(height: max(220, geometry.size.height - (connection.mouseControlEnabled == false ? 500 : 420)))
                        HStack(spacing: 12) {
                            clickButton("Left click", icon: "computermouse", action: .leftClick)
                            clickButton("Right click", icon: "cursorarrow.click.2", action: .rightClick)
                            Button { connection.toggleDrag() } label: {
                                VStack(spacing: 8) {
                                    Image(systemName: connection.dragging ? "hand.closed.fill" : "hand.draw").font(.title3)
                                    Text(connection.dragging ? "Release" : "Drag").font(.caption.weight(.semibold))
                                }.frame(maxWidth: .infinity).frame(height: 76)
                                    .background(connection.dragging ? mint : .white.opacity(0.06), in: RoundedRectangle(cornerRadius: 20))
                                    .foregroundStyle(connection.dragging ? .black : .white)
                            }.accessibilityLabel(connection.dragging ? "Release drag" : "Start drag")
                        }
                        HStack {
                            Button { connection.send(MouseCommand(.previousSpace)) } label: {
                                Image(systemName: "rectangle.portrait.and.arrow.left").frame(width: 44, height: 44)
                            }.accessibilityLabel("Previous desktop space").disabled(connection.dragging)
                            Spacer()
                            Button { showSettings = true } label: {
                                Label("Gesture guide", systemImage: "hand.tap.fill").font(.caption.weight(.semibold))
                            }
                            Spacer()
                            Button { connection.send(MouseCommand(.nextSpace)) } label: {
                                Image(systemName: "rectangle.portrait.and.arrow.right").frame(width: 44, height: 44)
                            }.accessibilityLabel("Next desktop space").disabled(connection.dragging)
                        }
                        Text(connection.dragging ? "Dragging · lift your finger or tap Release" : "Move · scroll · pinch · hold to drag")
                            .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    } else {
                        discovery.padding(.top, 24)
                    }
                }.padding(24).frame(minHeight: geometry.size.height, alignment: .top)
            }.scrollDisabled(connection.connectedName != nil)
        }
        .background(Color(red: 0.055, green: 0.065, blue: 0.075))
        .foregroundStyle(.white).tint(mint).preferredColorScheme(.dark)
        .sheet(isPresented: $showSettings) { settings }
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
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 6) {
                Text("REMOTE / 01").font(.system(size: 10, weight: .bold, design: .monospaced)).tracking(3).foregroundStyle(mint)
                Text("Your Mac, in hand.").font(.system(size: 28, weight: .semibold, design: .rounded)).minimumScaleFactor(0.7).lineLimit(1)
            }
            Spacer(minLength: 8)
            Button { showSettings = true } label: {
                Image(systemName: "slider.horizontal.3").font(.title3).frame(width: 44, height: 44).background(.white.opacity(0.06), in: Circle())
            }.accessibilityLabel("Settings and gesture guide")
        }
    }
    private var trackpad: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 30).fill(Color(red: 0.095, green: 0.115, blue: 0.12))
            Canvas { context, size in
                for x in stride(from: 20.0, to: size.width, by: 22) {
                    for y in stride(from: 20.0, to: size.height, by: 22) {
                        context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 2, height: 2)), with: .color(.white.opacity(0.08)))
                    }
                }
            }.clipShape(RoundedRectangle(cornerRadius: 30)).allowsHitTesting(false)
            VStack(spacing: 12) {
                Image(systemName: connection.dragging ? "hand.draw" : "cursorarrow.motionlines").font(.system(size: 30, weight: .light))
                Text(connection.dragging ? "DRAGGING" : "TOUCH TO MOVE").font(.system(size: 10, weight: .medium, design: .monospaced)).tracking(3)
            }.foregroundStyle(mint.opacity(0.5)).allowsHitTesting(false)
            Trackpad(sensitivity: speed, naturalScrolling: naturalScrolling, haptics: gestureHaptics, dragging: $connection.dragging, send: connection.send)
        }.overlay(RoundedRectangle(cornerRadius: 30).stroke(mint.opacity(connection.dragging ? 0.65 : 0.15), lineWidth: 1))
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
    private func clickButton(_ title: String, icon: String, action: MouseCommand.Action) -> some View {
        Button { connection.send(MouseCommand(action)) } label: {
            VStack(spacing: 8) {
                Image(systemName: icon).font(.title3)
                Text(title).font(.caption.weight(.semibold))
            }.frame(maxWidth: .infinity).frame(height: 76).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 20))
        }.foregroundStyle(.white).disabled(connection.dragging)
    }
    private var settings: some View {
        NavigationStack {
            Form {
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
                    Text("After the first approval, reconnects automatically when you reopen the app. iOS disconnects local peer sessions in the background; a force-closed app must be reopened.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Preferences") {
                    Toggle("Natural scrolling", isOn: $naturalScrolling)
                    Toggle("Gesture haptics", isOn: $gestureHaptics)
                }
                Section("Gestures") {
                    Label("Hold, then move to drag; lift to release", systemImage: "hand.draw.fill")
                    Label("Pinch to zoom in or out", systemImage: "arrow.up.left.and.arrow.down.right")
                    Label("Two-finger double-tap to reset zoom", systemImage: "arrow.counterclockwise")
                    Label("Three-finger swipe left/right: spaces", systemImage: "rectangle.split.3x1")
                    Label("Three-finger swipe up: Mission Control", systemImage: "rectangle.3.group")
                    Label("Three-finger swipe down: app windows", systemImage: "macwindow.on.rectangle")
                    Label("Move with one finger", systemImage: "hand.point.up")
                    Label("Tap to click", systemImage: "cursorarrow.click")
                    Label("Double-tap to double-click", systemImage: "cursorarrow.click.2")
                    Label("Two-finger tap to right-click", systemImage: "hand.tap")
                    Label("Two-finger swipe to scroll", systemImage: "arrow.up.arrow.down")
                    Label("Tap Drag, move, then Release", systemImage: "hand.draw")
                }
                Section("Gesture compatibility") {
                    Text("Zoom uses ⌘+ / ⌘− / ⌘0 in the active Mac app. Space and window gestures use your Mac’s configured Mission Control keyboard shortcuts, including custom modifiers. Enable these shortcuts in Mac Keyboard Shortcuts → Mission Control if needed.")
                }
                Section("Connection help") {
                    Text("Keep the Mac companion open, allow Local Network access on both devices, and enable Accessibility for RemotePad Mac. Guest Wi-Fi or VPNs may block discovery.")
                    Text("Leaving this app releases any held mouse button. Your approved pairing is saved, so reopening can reconnect automatically.")
                }
            }.navigationTitle("Make it yours").toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showSettings = false } } }
        }.preferredColorScheme(.dark).tint(mint)
    }
}
