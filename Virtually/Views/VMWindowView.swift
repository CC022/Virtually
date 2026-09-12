// 虚拟机窗口。
//
// 控件用常驻工具栏。此前试过「鼠标碰顶部才浮出的玻璃胶囊」,实际用下来体验不好。
//
// 文案克制:只说用户需要据以决策的信息。设备为什么抢不到、快照要多久,
// 这些解释放在 tooltip 里或干脆不说 —— 抢不到就把开关灰掉,进度条自己会转。
//
// 进行中状态与结果活在 VMSession 里,不在这些 View 里:popover 一关 View 就销毁,
// 而保存快照要几十秒,结果回来时就没人接了。

import SwiftUI
import VirtuallyKit

struct VMWindowView: View {
    let ref: VMRef
    @Environment(AppState.self) private var app
    @State private var session: VMSession?
    @State private var panel: Panel?
    @State private var confirmPowerOff = false

    enum Panel: String, Identifiable {
        case network, usb, snapshots, files
        var id: String { rawValue }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let session, let failure = session.launchFailure {
                // QEMU 自己退了。窗口留着,把日志尾部摆出来,用户才知道去修什么。
                ContentUnavailableView {
                    Label("虚拟机意外退出", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(failure).font(.system(.caption, design: .monospaced))
                        .multilineTextAlignment(.leading)
                }
            } else if let session {
                GuestViewRepresentable(session: session)
                    .focusedSceneValue(\.vmSession, session)   // 「虚拟机」菜单作用于这台
            } else if let why = app.launchErrors[ref.path] {
                // 开不起来就要说清楚。以前这里是一个永远转不完的圈。
                ContentUnavailableView {
                    Label("开不了机", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(why)
                }
            } else {
                ProgressView().controlSize(.large)
            }
        }
        .overlay(alignment: .top) { statusOverlay }
        // 文件直接拖到画面上 = 传进 guest
        .dropDestination(for: URL.self) { urls, _ in
            guard let session, !urls.isEmpty else { return false }
            session.sendFiles(urls)
            return true
        }
        .toolbar { toolbarContent }
        .navigationTitle(session?.bundle.settings.name ?? "虚拟机")
        .task { session = app.session(for: ref) }
    }

    /// 进度与错误都压在画面上方,面板关掉也还在 —— 长任务的结果必须能被看到
    @ViewBuilder
    private var statusOverlay: some View {
        if let session {
            if let busy = session.statusText {
                StatusPill(text: busy, busy: true)
            } else if let err = session.lastError {
                StatusPill(text: err, busy: false, dismiss: { session.clearError() })
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            // 关机是不可逆的,不能一按就生效 —— 展开菜单让用户选
            Menu {
                Button("关机") { session?.requestShutdown() }
                Button("强制断电", role: .destructive) { confirmPowerOff = true }
            } label: {
                Label("电源", systemImage: "power")
            }
            .help("电源")
            .buttonStyle(.borderless)
            .confirmationDialog("强制断电?", isPresented: $confirmPowerOff) {
                Button("强制断电", role: .destructive) { session?.forcePowerOff() }
            } message: {
                Text("相当于拔掉电源线,虚拟机里没保存的东西都会丢。")
            }

            panelButton(.network, "网络", "network")
            panelButton(.usb, "USB 设备", "cable.connector")
            panelButton(.files, "传文件", "arrow.up.document")
            panelButton(.snapshots, "快照", "clock.arrow.trianglehead.counterclockwise.rotate.90")
        }
        .sharedBackgroundVisibility(.hidden)
    }

    private func panelButton(_ which: Panel, _ title: String, _ symbol: String) -> some View {
        Button { panel = (panel == which) ? nil : which } label: {
            Label(title, systemImage: symbol)
        }
        .help(title)
        .buttonStyle(.borderless)
        .popover(isPresented: Binding(
            get: { panel == which },
            set: { if !$0 && panel == which { panel = nil } }
        ), arrowEdge: .bottom) {
            if let session {
                Group {
                    switch which {
                    case .network:   NetworkPanel(session: session)
                    case .usb:       USBPanel(session: session)
                    case .snapshots: SnapshotPanel(session: session)
                    case .files:     FileTransferPanel(session: session)
                    }
                }
                .padding(14)
                .frame(width: 300)
            }
        }
    }
}

private struct StatusPill: View {
    let text: String
    let busy: Bool
    var dismiss: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 7) {
            if busy { ProgressView().controlSize(.small) }
            Text(text).font(.callout).textSelection(.enabled)
            if let dismiss {
                Button(action: dismiss) { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("关闭")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: .capsule)
        .foregroundStyle(busy ? Color.primary : Color.orange)
        .padding(.top, 8)
    }
}

// MARK: - 网络

private struct NetworkPanel: View {
    let session: VMSession

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("网络").font(.headline)
            // 直接绑到会话:切换失败时选项跟着模型回弹,不会停在一个没生效的状态上
            Picker("", selection: Binding(get: { session.networkMode },
                                          set: { session.applyNetwork($0) })) {
                ForEach(NetworkMode.allCases, id: \.self) { m in
                    Text(m.displayName).tag(m)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .disabled(session.isBusy)
        }
    }
}

// MARK: - USB

private struct USBPanel: View {
    let session: VMSession
    @State private var devices: [USBDevice] = []
    @State private var loading = true
    /// 插拔时自动刷新。面板活着它就活着。
    @State private var watcher = USBWatcher()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("USB 设备").font(.headline)
                Spacer()
                if loading { ProgressView().controlSize(.small) }
                Button { Task { await refresh() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
            }

            if devices.isEmpty && !loading {
                Text("没有设备").font(.caption).foregroundStyle(.secondary)
            }

            // 抢不到的设备直接灰掉开关,原因放 tooltip —— 不占版面。
            // 开关状态来自会话(`attachedUSB`),面板关掉再开也对得上。
            ForEach(devices, id: \.key) { d in
                Toggle(d.name, isOn: binding(for: d))
                    .toggleStyle(.switch)
                    .lineLimit(1)
                    .disabled(d.blockedReason != nil || session.isBusy)
                    .help(d.blockedReason ?? d.idString)
            }
        }
        .task {
            watcher.onChange = { Task { await refresh() } }
            await refresh()
        }
    }

    private func binding(for d: USBDevice) -> Binding<Bool> {
        Binding(
            get: { session.isAttached(d) },
            set: { on in on ? session.attachUSB(d) : session.detachUSB(d) })
    }

    /// IOKit 枚举很快,但仍不放在主线程上 —— 它要遍历整个 IORegistry
    private func refresh() async {
        loading = true
        devices = await Task.detached { USBEnumerator.devices() }.value
        loading = false
    }
}

// MARK: - 快照

private struct SnapshotPanel: View {
    let session: VMSession
    @State private var newName = ""
    @State private var pendingDelete: String?

    private var nameProblem: String? {
        newName.isEmpty ? nil : VMSession.snapshotNameProblem(newName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("快照").font(.headline)

            if session.snapshots.isEmpty {
                Text("还没有快照").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(session.snapshots) { r in
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(r.id).lineLimit(1)
                        Text("\(r.date)  ·  \(r.size)")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { session.restoreSnapshot(r.id) } label: {
                        Image(systemName: "arrow.counterclockwise")
                    }
                    .buttonStyle(.borderless)
                    .disabled(!session.canRestore(r.id))
                    .help(session.canRestore(r.id) ? "恢复到这一刻"
                          : "这条快照是在不同的设备配置下存的,恢复不了")
                    Button(role: .destructive) { pendingDelete = r.id } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("删除")
                }
                .disabled(session.isBusy)
            }

            Divider()
            HStack {
                TextField("名称", text: $newName).textFieldStyle(.roundedBorder)
                Button("保存") {
                    session.saveSnapshot(named: newName)
                    newName = ""
                }
                .disabled(newName.isEmpty || nameProblem != nil || session.isBusy)
            }
            if let nameProblem {
                Text(nameProblem).font(.caption2).foregroundStyle(.orange)
            }
        }
        .task { session.refreshSnapshots() }
        // 删快照是几个 GB 说没就没,而且撤不回来
        .confirmationDialog("删除快照「\(pendingDelete ?? "")」?",
                            isPresented: Binding(get: { pendingDelete != nil },
                                                 set: { if !$0 { pendingDelete = nil } })) {
            Button("删除", role: .destructive) {
                if let tag = pendingDelete { session.deleteSnapshot(tag) }
                pendingDelete = nil
            }
        }
    }
}

// MARK: - 传文件

private struct FileTransferPanel: View {
    let session: VMSession
    @State private var picking = false
    @State private var leftovers: [URL] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("传文件").font(.headline)

            if let t = session.transfer {
                Label(t.attached ? "传输盘在 guest 上(可移动磁盘)" : "传输盘已弹出",
                      systemImage: "externaldrive.fill")
                    .font(.callout)
                if !t.files.isEmpty {
                    Text(t.files.joined(separator: "、")).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }
                Text("在虚拟机里把要传回来的文件放到这个盘上,再点取回。")
                    .font(.caption2).foregroundStyle(.secondary)
                Button("取回并弹出") { session.retrieveTransferDisk() }
                    .disabled(session.isBusy)
            } else {
                // 拖放区
                VStack(spacing: 6) {
                    Image(systemName: "arrow.down.doc").font(.title2)
                    Text("把文件拖到这里,或拖到画面上").font(.caption)
                    Button("选择文件…") { picking = true }.controlSize(.small)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 14)
                .background(.quaternary, in: .rect(cornerRadius: 8))
                .dropDestination(for: URL.self) { urls, _ in
                    guard !urls.isEmpty else { return false }
                    session.sendFiles(urls); return true
                }
                Text("虚拟机里会出现一个 U 盘。取回时复制到「下载」并弹出。")
                    .font(.caption2).foregroundStyle(.secondary)

                ForEach(leftovers, id: \.self) { img in
                    HStack {
                        Text("上次没取回:\(img.lastPathComponent)").font(.caption).lineLimit(1)
                        Spacer()
                        Button("取回") { session.retrieveLeftover(img) }.controlSize(.small)
                    }
                }
            }
        }
        .disabled(session.isBusy)
        .fileImporter(isPresented: $picking, allowedContentTypes: [.item], allowsMultipleSelection: true) { r in
            if case .success(let urls) = r, !urls.isEmpty { session.sendFiles(urls) }
        }
        .task { leftovers = session.findLeftoverTransferDisks() }
        .onChange(of: session.transfer) { _, _ in leftovers = session.findLeftoverTransferDisks() }
    }
}
