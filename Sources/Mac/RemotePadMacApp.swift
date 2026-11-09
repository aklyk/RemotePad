import SwiftUI

@main
struct RemotePadMacApp: App {
    @StateObject private var receiver = MacReceiver()
    var body: some Scene {
        WindowGroup("RemotePad for Mac") {
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
                        Text("Approve only the iPhone you are pairing now.").foregroundStyle(.secondary)
                        HStack {
                            Button("Decline") { receiver.answer(false) }
                            Button("Allow Connection") { receiver.answer(true) }.buttonStyle(.borderedProminent).tint(.mint)
                        }
                    }
                }
                if let name = receiver.controller {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack { Text("Controlled by \(name)"); Spacer(); Button("Disconnect") { receiver.disconnect() } }
                        Label("\(receiver.lastAction) · \(receiver.receivedCommands) commands", systemImage: "waveform.path")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Toggle("Allow new connections", isOn: Binding(get: { receiver.accepting }, set: receiver.setAccepting))
                Text("Keep this app open. Connect your iPhone to the same Wi-Fi, open RemotePad, and select this Mac. Each connection requires your approval.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .padding(32).frame(width: 500).tint(.mint)
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in receiver.disconnect() }
        }.windowResizability(.contentSize)
    }
}
