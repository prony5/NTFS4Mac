import SwiftUI

struct DeviceRow: View {
    let device: NTFSDevice
    var isOperating = false
    let onMount: () -> Void
    let onRestore: () -> Void
    let onEject: () -> Void
    let onOpenInFinder: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            // Status icon
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)

            // Device info
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(device.displayName)
                        .font(.headline)
                    Text(device.filesystemType.displayName)
                        .font(.system(.caption2, design: .monospaced))
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.secondary.opacity(0.15)))
                }
                HStack(spacing: 12) {
                    Text(device.id)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text(device.size)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            // Status badge
            Text(statusBadge)
                .font(.system(.caption, design: .monospaced))
                .fontWeight(.semibold)
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(statusColor))

            // Open in Finder (only when accessible)
            if device.isMounted && device.isAccessible {
                Button(action: onOpenInFinder) {
                    Image(systemName: "folder")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Open in Finder")
            }

            // Action buttons
            if device.needsMountAction {
                Button(device.filesystemType.mountButtonLabel) { onMount() }
                    .buttonStyle(.borderedProminent)
                    .tint(.accentColor)
                    .controlSize(.small)
                    .disabled(isOperating)
            }

            if device.isMounted {
                Button(action: onEject) {
                    Label("Eject", systemImage: "eject.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isOperating)
                .help("Unmount and safely disconnect this drive")
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private var statusColor: Color {
        if !device.isMounted { return .gray }
        return device.isReadWrite ? .green : .orange
    }

    private var statusBadge: String {
        if device.isReadWrite { return "RW" }
        if device.isMounted { return "RO" }
        return "--"
    }
}
