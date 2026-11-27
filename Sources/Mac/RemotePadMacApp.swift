import SwiftUI

@main
struct RemotePadMacApp: App {
    @StateObject private var receiver = MacReceiver()
    var body: some Scene {
        WindowGroup("RemotePad for Mac", id: "main") {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 14) {
                    Image(systemName: "cursorarrow.motionlines").font(.system(size: 32)).foregroundStyle(.mint)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("RemotePad").font(.largeTitle.bold())
                        Text(receiver.computerName).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Circle().fill(receiver.controller == nil ? Color.orange : .mint).frame(width: 10, height: 10)
                }
                Text("Your iPhone. Your Mac’s trackpad.").font(.title3)
                VStack(alignment: .leading, spacing: 14) {
                    Label(receiver.status, systemImage: "wifi")
                    Label(receiver.permission ? "Mouse control is enabled" : "Mouse control needs permission",
                          systemImage: receiver.permission ? "checkmark.shield" : "hand.raised")
                    if !receiver.permission {
                        Button("Enable Accessibility Access") { receiver.requestPermission() }
                        Text("Allow RemotePad Mac in System Settings → Privacy & Security → Accessibility. If access stays blocked after an update, remove RemotePad Mac from this list, add this app again, then reopen it.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(20).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
                if let name = receiver.pendingName {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Allow \(name) to control your mouse?").font(.headline)
                        Text("Approve only your iPhone. This remembers its pairing so it can reconnect automatically.").foregroundStyle(.secondary)
                        HStack {
                            Button("Decline") { receiver.answer(false) }
                            Button("Allow Connection") { receiver.answer(true) }.buttonStyle(.borderedProminent).tint(.mint)
                        }
                    }
                }
                if let name = receiver.controller {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack { Text("Controlled by \(name)"); Spacer(); Button("Disconnect & Pause") { receiver.setAccepting(false) } }
                        Label("\(receiver.lastAction) · \(receiver.receivedCommands) commands", systemImage: "waveform.path")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if receiver.rememberedPhones > 0 || receiver.directKeyAvailable {
                    HStack {
                        Label("\(receiver.rememberedPhones) saved pairings", systemImage: "iphone")
                        Spacer()
                        Button("Forget All") { receiver.forgetPhones() }
                    }.font(.caption)
                }
                Toggle("Allow new connections", isOn: Binding(get: { receiver.accepting }, set: receiver.setAccepting))
                directConnections
                Text("For Nearby, select this Mac from your iPhone on the same Wi-Fi. Keep this window open for the first approval. Closing the window keeps RemotePad running in the menu bar.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .padding(32).frame(width: 500).tint(.mint)
        }.windowResizability(.contentSize)
        MenuBarExtra("RemotePad", systemImage: "cursorarrow.motionlines") {
            RemotePadMenu(receiver: receiver)
        }
    }

    private var directConnections: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Allow ZeroTier and NetBird connections",
                   isOn: Binding(get: { receiver.vpnEnabled }, set: receiver.setVPNEnabled))
            if let status = receiver.vpnStatus { Text(status).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Button(receiver.usbEnabled ? "Stop USB" : "Start USB") {
                    if receiver.usbEnabled { receiver.stopUSB() }
                    else { receiver.startUSB() }
                }
                if receiver.directKeyAvailable { Button("Copy Connection Key") { receiver.copyDirectKey() } }
            }
            if let status = receiver.usbStatus { Text(status).font(.caption).foregroundStyle(.secondary) }
        }
        .disabled(!receiver.accepting)
    }
}

private struct RemotePadMenu: View {
    @ObservedObject var receiver: MacReceiver
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text(receiver.status)
        Button("Open RemotePad") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Toggle("Allow connections", isOn: Binding(get: { receiver.accepting }, set: receiver.setAccepting))
        if receiver.controller != nil { Button("Disconnect & Pause") { receiver.setAccepting(false) } }
        Divider()
        Button("Quit RemotePad") { NSApp.terminate(nil) }
    }
}
