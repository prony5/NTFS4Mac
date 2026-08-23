import SwiftUI

struct DeviceListView: View {
    @Environment(DeviceService.self) private var deviceService
    @Environment(MountService.self) private var mountService
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var isOperating = false

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                Text("External Devices")
                    .font(.title2)
                    .fontWeight(.bold)
                Spacer()
                Button(action: { Task { await deviceService.refresh() } }) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .disabled(deviceService.isRefreshing)
            }
            .padding()

            Divider()

            if deviceService.isRefreshing && deviceService.devices.isEmpty {
                Spacer()
                ProgressView("Scanning devices...")
                Spacer()
            } else if deviceService.devices.isEmpty {
                Spacer()
                ContentUnavailableView {
                    Label("No Devices Found", systemImage: "externaldrive.badge.xmark")
                } description: {
                    Text("Connect an external NTFS or ext4 drive to get started")
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(deviceService.devices) { device in
                            DeviceRow(
                                device: device,
                                isOperating: isOperating,
                                onMount: { operate(.mount(device)) },
                                onRestore: { operate(.restore(device)) },
                                onEject: { operate(.eject(device)) },
                                onOpenInFinder: { openInFinder(device) }
                            )
                        }
                    }
                    .padding()
                }
            }

            // Status bar
            Divider()
            HStack {
                let rwCount = deviceService.devices.filter(\.isReadWrite).count
                let roCount = deviceService.devices.filter { $0.isMounted && !$0.isReadWrite }.count
                Text("\(deviceService.devices.count) device(s) found")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if rwCount > 0 {
                    Circle().fill(.green).frame(width: 6, height: 6)
                    Text("\(rwCount) RW").font(.caption).foregroundStyle(.secondary)
                }
                if roCount > 0 {
                    Circle().fill(.orange).frame(width: 6, height: 6)
                    Text("\(roCount) RO").font(.caption).foregroundStyle(.secondary)
                }
                if !mountService.isNTFS3GAvailable {
                    Text("ntfs-3g not found").font(.caption).foregroundStyle(.red)
                }
                if !mountService.isExt4FuseAvailable {
                    Text("ext4fuse not found").font(.caption).foregroundStyle(.red)
                }
                Spacer()
                Text("v\(AppInfo.version)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
        }
        .frame(minWidth: 560, minHeight: 320)
        .alert("Error", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "Unknown error")
        }
    }

    private enum Operation {
        case mount(NTFSDevice)
        case restore(NTFSDevice)
        case eject(NTFSDevice)
    }

    private func openInFinder(_ device: NTFSDevice) {
        guard let mountPoint = device.mountPoint else { return }

        guard device.isAccessible else {
            errorMessage = """
            Volume is not accessible. Unmount and mount again to fix permissions.
            If the problem persists, run in Terminal:
            sudo umount -f \(mountPoint)
            """
            showError = true
            return
        }

        let url = URL(fileURLWithPath: mountPoint, isDirectory: true)
        NSWorkspace.shared.open(url)
    }

    private func operate(_ op: Operation) {
        guard !isOperating else { return }
        isOperating = true
        Task {
            defer { isOperating = false }
            do {
                switch op {
                case .mount(let d):
                    try await mountService.mount(device: d)
                case .restore(let d):
                    try await mountService.restore(device: d)
                case .eject(let d):
                    try await mountService.eject(device: d)
                }
                try await Task.sleep(nanoseconds: 500_000_000)
                await deviceService.refresh()
            } catch {
                errorMessage = error.localizedDescription
                showError = true
            }
        }
    }
}
