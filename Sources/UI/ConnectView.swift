import SwiftUI
import VisionKit

struct ConnectView: View {
    @EnvironmentObject var model: AppModel
    var first = false
    @State private var url = ""
    @State private var token = ""
    @State private var busy = false
    @State private var error: String?
    @State private var scanning = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) { Star().fill(Theme.red).frame(width: 16, height: 16); Theme.label("Photoshopper3000") }
                        Theme.meta("Connect to the Photoshopper server on your network. It advertises itself; or scan the QR code from the tray menu, or type the address.")
                    }.listRowSeparator(.hidden)
                }
                Section("On this network") {
                    if model.discovered.isEmpty { Theme.meta("Looking…") }
                    ForEach(model.discovered) { s in
                        Button { Task { await go(s.url) } } label: {
                            VStack(alignment: .leading) { Text(s.name); Theme.meta(s.url) }
                        }
                    }
                }
                Section("Manually") {
                    TextField("http://192.168.x.x:8765", text: $url)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Token (only if the server requires one)", text: $token)
                    Button("Connect") { Task { await go(url) } }.disabled(url.isEmpty || busy)
                    if DataScannerViewController.isSupported {
                        Button("Scan QR code") { scanning = true }
                    }
                }
                if let error { Section { Text(error).foregroundStyle(Theme.red) } }
            }
            .navigationTitle(first ? "Connect" : "Server")
            .onAppear { model.startDiscovery(); url = model.serverURL; token = model.token }
            .onDisappear { model.stopDiscovery() }
            .sheet(isPresented: $scanning) {
                QRScanner { code in
                    scanning = false
                    Task {
                        busy = true
                        if await model.connect(qr: code) { error = nil; await model.sync(reason: "manual") }
                        else { error = "That QR code is not a Photoshopper pairing code." }
                        busy = false
                    }
                }
            }
        }
    }

    private func go(_ u: String) async {
        busy = true
        defer { busy = false }
        if await model.connect(url: u, token: token.isEmpty ? nil : token) {
            error = nil
            await model.sync(reason: "manual")
        } else {
            error = "Could not reach \(u)."
        }
    }
}

struct QRScanner: UIViewControllerRepresentable {
    let onCode: (String) -> Void
    func makeUIViewController(context: Context) -> DataScannerViewController {
        let vc = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], isHighlightingEnabled: true)
        vc.delegate = context.coordinator
        try? vc.startScanning()
        return vc
    }
    func updateUIViewController(_ vc: DataScannerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onCode: (String) -> Void
        var done = false
        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }
        func dataScanner(_ s: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !done else { return }
            for case let .barcode(b) in items { if let v = b.payloadStringValue { done = true; onCode(v); return } }
        }
    }
}
