import SwiftUI
import RecoverDCore
import RecoverDEngine

/// Device selection + scan-mode choice + "Start Scan". Also surfaces the in-memory guarantee.
///
/// Lists all discovered whole disks grouped into "External / Removable" (recovery targets) and
/// "Internal" (boot disk etc., shown but guarded with a warning). Each row shows the connection
/// type icon, volume name, hardware identity, capacity, and an expandable partition list.
struct DevicePickerView: View {
    @Bindable var session: RecoverySessionViewModel
    @State private var isStarting = false

    private var externalDevices: [DeviceInfo] {
        session.devices.filter { $0.isLikelyExternalRecoveryTarget }
    }
    private var internalDevices: [DeviceInfo] {
        session.devices.filter { !$0.isLikelyExternalRecoveryTarget }
    }

    var body: some View {
        VStack(spacing: 0) {
            deviceList
            Divider()
            configurationPanel
        }
    }

    private var deviceList: some View {
        List(selection: $session.selectedDevice) {
            Section {
                if externalDevices.isEmpty {
                    Text("No external devices found. Connect a USB drive, SD card, or external SSD/HDD — or use Open image… to scan a .dmg/.img file.")
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                } else {
                    ForEach(externalDevices) { device in
                        DeviceRow(device: device).tag(device)
                    }
                }
            } header: {
                Label("External / Removable Drives", systemImage: "externaldrive.badge.plus")
            }

            if !internalDevices.isEmpty {
                Section {
                    ForEach(internalDevices) { device in
                        DeviceRow(device: device, isInternal: true).tag(device)
                    }
                } header: {
                    Label("Internal Drives", systemImage: "internaldrive")
                } footer: {
                    Text("Scanning the internal boot disk is not recommended. RecoverD targets external media.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.inset)
    }

    private var configurationPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 16) {
                scanModePicker
                selectedDeviceSummary
                Spacer()
            }

            HStack {
                if let device = session.selectedDevice, device.isLikelyExternalRecoveryTarget {
                    Button("Start Scan") {
                        isStarting = true
                        Task {
                            await session.startScanOnSelectedDevice()
                            isStarting = false
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(session.selectedDevice == nil)
                    .help("Begin scanning the selected external drive. Results stay in memory until you explicitly export.")
                } else if session.selectedDevice != nil {
                    Label("Select an external drive to scan", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Spacer()
                } else {
                    Label("No device selected", systemImage: "circle.dashed")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                if isStarting { ProgressView().controlSize(.small) }
            }

            inMemoryNotice
        }
        .padding()
        .background(.thinMaterial)
    }

    private var scanModePicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Scan mode").font(.caption).foregroundStyle(.secondary)
            Picker("Scan mode", selection: $session.scanMode) {
                ForEach(ScanMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .help("Quick Scan: parses the file system for deleted entries (fast). Deep / Carving Scan: also scans raw blocks for file signatures (slow, works on reformatted/corrupted drives).")

            // Carve-scope options (only meaningful for a deep/carving scan).
            if session.scanMode == .deep {
                Toggle("Try harder (best-guess formats)", isOn: $session.tryHarderCarve)
                    .toggleStyle(.checkbox)
                    .help("Also carve formats we can't size exactly (GIF, ZIP, MP3, FLAC, Ogg, MPEG). Recovery of these is more of a best guess.")
                Toggle("Include camera RAW", isOn: $session.includeRAWCarve)
                    .toggleStyle(.checkbox)
                    .help("Carve TIFF and camera RAW (CR2/CR3/NEF/ARW/ORF/RW2/RAF/X3F). RAW often recovers but may not be usable, and adds a lot of large files.")
            }
        }
    }

    @ViewBuilder
    private var selectedDeviceSummary: some View {
        if let device = session.selectedDevice {
            VStack(alignment: .leading, spacing: 2) {
                Text(device.displayName).font(.callout).lineLimit(1)
                HStack(spacing: 8) {
                    Label(device.connection.displayName, systemImage: device.connection.systemImage)
                    if let bus = device.busProtocol {
                        Text("· \(bus)")
                    }
                    Text("· /dev/r\(device.bsdName)")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        } else {
            EmptyView()
        }
    }

    private var inMemoryNotice: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "lock.shield")
                .foregroundStyle(.green)
            Text("Results stay in memory until you explicitly export. Nothing from the source is written to your Mac during scanning or previewing.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// A rich device row: connection-type icon, display name, volume name, BSD node, capacity bar,
/// and an expandable list of partitions.
private struct DeviceRow: View {
    let device: DeviceInfo
    var isInternal: Bool = false
    @State private var partitionsExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Image(systemName: device.connection.systemImage)
                    .font(.title3)
                    .foregroundStyle(iconColor)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text(device.displayName)
                        .font(.body)
                        .lineLimit(1)

                    HStack(spacing: 8) {
                        Text("/dev/r\(device.bsdName)")
                        if let vol = device.volumeName, !vol.isEmpty {
                            Text("· \(vol)")
                        }
                        if !device.detectedFileSystems.isEmpty {
                            Text("· \(device.detectedFileSystems.joined(separator: ", "))")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    if let vendor = device.vendorName, let model = device.modelName,
                       !vendor.isEmpty || !model.isEmpty {
                        Text([vendor, model].compactMap { $0.isEmpty ? nil : $0 }.joined(separator: " "))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text(device.formattedSize)
                        .font(.caption)
                        .monospacedDigit()
                    if isInternal {
                        Label("Internal", systemImage: "internaldrive")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    } else if device.isRemovable {
                        Label("Removable", systemImage: "eject")
                            .font(.caption2)
                            .foregroundStyle(.blue)
                    }
                }
            }

            if !device.partitions.isEmpty {
                DisclosureGroup("Partitions (\(device.partitions.count))", isExpanded: $partitionsExpanded) {
                    ForEach(device.partitions) { partition in
                        PartitionRow(partition: partition, depth: 0)
                    }
                }
                .font(.caption)
                .padding(.leading, 34)
            }
        }
        .padding(.vertical, 4)
    }

    private var iconColor: Color {
        if isInternal { return .orange }
        switch device.connection {
        case .usb: return .blue
        case .sdCard: return .teal
        case .thunderbolt: return .purple
        case .fireWire: return .gray
        case .imageFile: return .indigo
        case .network: return .green
        case .internalDisk: return .orange
        case .unknown: return .secondary
        }
    }
}

/// A partition row that recursively nests subpartitions (e.g. APFS volumes inside a container
/// partition). `depth` controls indentation level.
private struct PartitionRow: View {
    let partition: PartitionInfo
    let depth: Int
    @State private var subpartitionsExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Image(systemName: partition.hasSubpartitions ? "cylinder.split.1x2" : "externaldrive.fill")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(partition.volumeName ?? partition.bsdName)
                    HStack(spacing: 6) {
                        Text("/dev/r\(partition.bsdName)")
                        if !partition.detectedFileSystems.isEmpty {
                            Text("· \(partition.detectedFileSystems.joined(separator: ", "))")
                        }
                        if let mp = partition.mountPoint {
                            Text("· mounted at \(mp.path)")
                        }
                    }
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Text(partition.formattedSize)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)

            if partition.hasSubpartitions {
                DisclosureGroup(
                    "Volumes (\(partition.subpartitions.count))",
                    isExpanded: $subpartitionsExpanded
                ) {
                    ForEach(partition.subpartitions) { sub in
                        PartitionRow(partition: sub, depth: depth + 1)
                    }
                }
                .padding(.leading, 20)
            }
        }
        .padding(.leading, CGFloat(depth) * 20)
    }
}
