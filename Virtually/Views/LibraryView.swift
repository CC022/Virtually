// 资源库窗口:虚拟机列表与新建入口。
//
// 双击 app 时看到的第一个界面。带 -VMPath 启动(`virtually run`)时它会立刻把目标窗口打开并收起自己。

import SwiftUI
import VirtuallyKit

struct LibraryView: View {
    @Environment(AppState.self) private var app
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var wizard = false
    @State private var editing: VMRef?
    @State private var deleting: VMRef?
    @State private var problem: String?

    private let columns = [GridItem(.adaptive(minimum: 220, maximum: 280), spacing: 16)]

    var body: some View {
        ScrollView {
            GlassEffectContainer(spacing: 16) {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(app.library, id: \.url) { bundle in
                        // Button 而不是 onTapGesture:有按下反馈、能进焦点链、VoiceOver 可达
                        Button { open(bundle) } label: {
                            VMCard(bundle: bundle,
                                   running: app.runningPaths.contains(bundle.url.path),
                                   suspended: bundle.settings.snapshotShapes[suspendTag] != nil,
                                   installing: bundle.settings.install != nil,
                                   shot: app.thumbnails[bundle.url.path])
                        }
                        .buttonStyle(.plain)
                        .contextMenu { menu(for: bundle) }
                    }
                }
                .padding(20)
            }
        }
        .frame(minWidth: 520, minHeight: 360)
        .overlay {
            if app.library.isEmpty {
                ContentUnavailableView {
                    Label("还没有虚拟机", systemImage: "pc")
                } description: {
                    Text("点右上角加号新建")
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { wizard = true } label: { Label("新建虚拟机", systemImage: "plus") }
            }
        }
        .sheet(isPresented: $wizard) { NewVMWizard() }
        .sheet(item: $editing) { ref in VMSettingsSheet(ref: ref) }
        .confirmationDialog("删除「\(deleting.map { $0.url.deletingPathExtension().lastPathComponent } ?? "")」?",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("移到废纸篓", role: .destructive) {
                if let ref = deleting {
                    do { try app.delete(ref) } catch { problem = error.localizedDescription }
                }
                deleting = nil
            }
        } message: {
            Text("整个虚拟机包(磁盘、快照、设置)会移到废纸篓,可以从那里恢复。")
        }
        .alert("操作失败", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("好") { problem = nil }
        } message: { Text(problem ?? "") }
        .task {
            // 每次露面都重读一遍:虚拟机可能刚被挂起,徽章和缩略图都变了
            app.refreshLibrary()
            app.loadThumbnails()
            // 命令行指定了目标就直接开它,资源库让位(只做一次)
            if let target = app.takeLaunchTarget() {
                openWindow(id: "vm", value: target)
                dismissWindow(id: "library")
            }
        }
    }

    private func open(_ bundle: VMBundle) {
        openWindow(id: "vm", value: VMRef(path: bundle.url.path))
    }

    @ViewBuilder
    private func menu(for bundle: VMBundle) -> some View {
        let running = app.runningPaths.contains(bundle.url.path)
        Button(running ? "显示窗口" : "启动") { open(bundle) }
        Button("设置…") { editing = VMRef(path: bundle.url.path) }
            .disabled(running)
        Button("在访达中显示") {
            NSWorkspace.shared.activateFileViewerSelecting([bundle.url])
        }
        Divider()
        Button("删除…", role: .destructive) { deleting = VMRef(path: bundle.url.path) }
            .disabled(running)
    }
}

// MARK: - 设置

/// 关机态才能改。改了核数或内存,挂起状态与已有快照都会对不上(指纹变了),这里直说。
/// 磁盘更严:挂起时也不能改(恢复挂起状态会把盘缩回去,见 DiskResize.swift),而且只能扩大。
private struct VMSettingsSheet: View {
    let ref: VMRef
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var cpus = 1
    @State private var memoryGB = 2
    @State private var audio = true
    @State private var network = NetworkMode.none
    @State private var original: VMSettings?
    /// 系统盘现在的大小,读 qcow2 得来(不信配置里的 diskSizeGB)。nil 表示还没读到
    @State private var currentDiskGB: Int?
    @State private var diskGB = 0
    /// 打开时从包里看出来的不能改的原因:安装中、已挂起、读不到大小。正在运行另算,见 diskBlocked
    @State private var diskBlockedByBundle: String?
    @State private var saving = false
    @State private var failure: String?

    /// qcow2 是稀疏的,上限只是防手滑
    private static let maxDiskGB = 1024

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("设置").font(.title2.bold())
            Form {
                TextField("名称", text: $name)
                Stepper("CPU  \(cpus) 核", value: $cpus, in: 1...VMSettings.hostCPUCount)
                Stepper("内存  \(memoryGB) GB", value: $memoryGB,
                        in: 2...max(2, VMSettings.maxMemoryMB / 1024))
                VStack(alignment: .leading, spacing: 4) {
                    let current = currentDiskGB ?? 0
                    // 下限是现在的大小:只能扩大,缩小会切掉 guest 的分区
                    Stepper(currentDiskGB == nil ? "磁盘" : "磁盘  \(diskGB) GB", value: $diskGB,
                            in: current...max(current, Self.maxDiskGB), step: 16)
                        .disabled(diskBlocked != nil || currentDiskGB == nil)
                    if let why = diskBlocked {
                        Text(why).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Toggle("声卡", isOn: $audio)
                Picker("网络", selection: $network) {
                    ForEach(NetworkMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
            }
            .formStyle(.grouped)

            if shapeChanges {
                Label("改了核数、内存或声卡,已挂起的状态和已有快照都会对不上,下次是冷启动。",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            if let current = currentDiskGB, diskGB > current {
                Label("磁盘只能扩大。下次开机后会自动把系统分区扩到占满;恢复扩容前存的快照,磁盘会回到当时的大小。",
                      systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let failure {
                Text(failure).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                if saving { ProgressView().controlSize(.small) }
                Button("取消") { dismiss() }.disabled(saving)
                Button("保存") { save() }.buttonStyle(.borderedProminent)
                    .disabled(original == nil || saving)
            }
        }
        .padding(20)
        .frame(width: 420)
        .task {
            guard let b = try? VMBundle.load(at: ref.url) else { failure = "读不到配置"; return }
            original = b.settings
            name = b.settings.name
            cpus = b.settings.cpuCount
            memoryGB = b.settings.memoryMB / 1024
            audio = b.settings.audioEnabled
            network = b.settings.network
            diskBlockedByBundle = b.diskResizeBlockedReason
            do {
                let gb = VMBundle.wholeGB(try await app.diskSize(ref))
                diskGB = gb            // 先给值再给下限,Stepper 不会看到越界的中间态
                currentDiskGB = gb
            } catch {
                diskBlockedByBundle = "读不到磁盘大小:\(error.localizedDescription)"
            }
        }
    }

    /// 面板开着的时候虚拟机也可能被开起来(命令行、恢复的窗口),所以运行态实时看
    private var diskBlocked: String? {
        if app.runningPaths.contains(ref.path) { return "虚拟机正在运行,关机后才能改磁盘大小" }
        return diskBlockedByBundle
    }

    private var shapeChanges: Bool {
        guard let o = original else { return false }
        return o.cpuCount != cpus || o.memoryMB != memoryGB * 1024 || o.audioEnabled != audio
    }

    private func save() {
        guard var s = original else { return }
        s.name = name
        s.cpuCount = cpus
        s.memoryMB = memoryGB * 1024
        s.audioEnabled = audio
        s.network = network
        saving = true
        failure = nil
        Task {
            defer { saving = false }
            do {
                // 先扩盘:失败就停在面板上,别的设置一项都不动
                if let current = currentDiskGB, diskGB > current {
                    try await app.resizeDisk(ref, toGB: diskGB)
                    currentDiskGB = diskGB     // 下面要是失败了再点保存,不会再扩一次
                }
                _ = try app.updateSettings(ref, s)
                dismiss()
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}

private struct VMCard: View {
    let bundle: VMBundle
    let running: Bool
    /// 上次是按红叉离开的,状态还留着 —— 点开就接着上次
    let suspended: Bool
    /// 还没装完,打开会带着安装介质接着装
    let installing: Bool
    /// 上次离开时的画面。几台虚拟机排在一起,光看名字分不出谁是谁。
    let shot: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(.black.opacity(0.85))
                if let shot {
                    Image(nsImage: shot)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "pc")
                        .font(.system(size: 34))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            .frame(height: 110)
            .clipShape(RoundedRectangle(cornerRadius: 10))

            HStack(spacing: 6) {
                Circle()
                    .fill(running ? .green : .secondary.opacity(0.4))
                    .frame(width: 7, height: 7)
                Text(bundle.settings.name).font(.headline).lineLimit(1)
            }
            HStack(spacing: 5) {
                if installing {
                    Image(systemName: "arrow.down.circle.fill")
                    Text("安装中")
                } else if !running && suspended {
                    Image(systemName: "pause.circle.fill")
                    Text("已挂起")
                }
                Text("\(bundle.settings.os.displayName) · \(bundle.settings.cpuCount) 核 · "
                     + "\(bundle.settings.memoryMB / 1024) GB 内存")
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }
}

// MARK: - 新建向导

private struct NewVMWizard: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow

    /// 装哪个系统。所有差异都从这里分出去:要不要驱动盘、磁盘下限、默认名、变体列表。
    @State private var os = GuestOS.windows
    @State private var name = GuestOS.windows.defaultVMName
    @State private var isoURL: URL?
    /// 镜像认出来是哪个系统。与上面那个下拉不一致就拦住 —— 猜错会格掉一块盘。
    @State private var detectedOS: GuestOS?
    /// 驱动 ISO。默认位置有就自动填上;没有必须选,否则装出来的机器黑屏没网
    @State private var virtioURL: URL? = VMInstaller.defaultVirtioISO
    @State private var variants: [InstallVariant] = []
    @State private var variantID: String?
    @State private var inspecting = false
    @State private var cpus = VMSettings.defaultCPUCount
    @State private var memoryGB = VMSettings.defaultMemoryMB / 1024
    @State private var diskGB = 64
    @State private var username = "vm"
    @State private var password = "vm"
    /// 正在选哪张镜像。**一个 View 上只能挂一个 fileImporter**,第二个会把第一个顶掉 ——
    /// 之前 Windows ISO 和 virtio ISO 各挂一个,结果「安装镜像 → 选择」点了没反应。
    /// 目标与「面板开没开」必须是两个状态:面板关闭时 isPresented 的 setter 先跑,
    /// 要是目标也存在同一个变量里,回调看到的就是 nil,选了等于没选。
    enum Picking { case windows, virtio }
    @State private var picking: Picking = .windows
    @State private var showPicker = false
    @State private var notes: [String] = []

    /// 非 nil 表示正在建包/构建介质,界面切到进度态
    @State private var phase: VMInstaller.Phase?
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("新建虚拟机").font(.title2.bold())

            if let phase {
                progressView(phase)
            } else {
                form
            }

            if let failure {
                Text(failure).font(.caption).foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("取消") { dismiss() }.disabled(phase != nil)
                Button("创建并安装") { create() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canCreate)
            }
        }
        .padding(20)
        .frame(width: 460)
        .fileImporter(isPresented: $showPicker, allowedContentTypes: [.diskImage, .data]) { result in
            guard case .success(let url) = result else { return }
            switch picking {
            case .windows: pick(url)
            case .virtio:  virtioURL = url
            }
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 12) {
            Form {
                Picker("系统", selection: $os) {
                    ForEach(GuestOS.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .onChange(of: os) { old, new in
                    // 名字还是上个系统的默认名就跟着换;用户改过就不动
                    if name == old.defaultVMName { name = new.defaultVMName }
                    if diskGB < new.minDiskGB { diskGB = new.minDiskGB }
                    // 变体列表是按系统解析的,换了系统要重读
                    variants = []; variantID = nil
                    if let iso = isoURL { pick(iso) }
                }

                TextField("名称", text: $name)

                LabeledContent("安装镜像") {
                    HStack {
                        Text(isoURL?.lastPathComponent ?? "未选择")
                            .foregroundStyle(isoURL == nil ? .secondary : .primary)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer()
                        if inspecting { ProgressView().controlSize(.small) }
                        Button("选择…") { picking = .windows; showPicker = true }
                    }
                }

                // Linux 内核自带 virtio 驱动,这一行只对 Windows 有意义
                if os.needsDriverISO {
                    LabeledContent("virtio 驱动") {
                        HStack {
                            Text(virtioURL?.lastPathComponent ?? "未选择 virtio-win.iso")
                                .foregroundStyle(virtioURL == nil ? .secondary : .primary)
                                .lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button("选择…") { picking = .virtio; showPicker = true }
                        }
                    }
                    .help("显卡、网卡与 agent 通道的驱动都在这张 ISO 上,缺了装出来是黑屏")
                }

                if !variants.isEmpty {
                    Picker("版本", selection: $variantID) {
                        ForEach(variants) { v in
                            Text(v.name).tag(Optional(v.id))
                        }
                    }
                }

                TextField("用户名", text: $username)
                TextField("密码", text: $password)

                Stepper("CPU  \(cpus) 核", value: $cpus, in: 1...VMSettings.hostCPUCount)
                Stepper("内存  \(memoryGB) GB", value: $memoryGB,
                        in: 2...max(2, VMSettings.maxMemoryMB / 1024))
                Stepper("磁盘  \(diskGB) GB", value: $diskGB,
                        in: os.minDiskGB...512, step: 16)
            }
            .formStyle(.grouped)

            // clamp() 会把越界值拉回来并给出中文说明,直接显示给用户
            ForEach(notes, id: \.self) { n in
                Text(n).font(.caption).foregroundStyle(.orange)
            }

            if let detectedOS, detectedOS != os {
                Label("这张镜像看起来是 \(detectedOS.displayName),请检查上面的「系统」",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }

            Text("全自动安装,\(os == .windows ? "约 10 分钟" : "约 12 分钟")。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// 缺镜像、缺驱动盘(只 Windows 要)、名字空、正在忙、镜像与所选系统不符 —— 都不让点
    private var canCreate: Bool {
        guard isoURL != nil, !name.isEmpty, !username.isEmpty, phase == nil, !inspecting else { return false }
        if os.needsDriverISO && virtioURL == nil { return false }
        if let detectedOS, detectedOS != os { return false }
        return true
    }

    private func progressView(_ phase: VMInstaller.Phase) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ProgressView(value: phase.fraction)
            Text(phase.message).font(.callout)
            Text("介质建好后会自动打开虚拟机窗口开始安装,全程约 10 分钟。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
    }

    private func pick(_ url: URL) {
        isoURL = url
        variants = []; variantID = nil; failure = nil; detectedOS = nil
        inspecting = true
        Task {
            defer { inspecting = false }
            // 先认系统 —— 与下拉不一致就别急着解析变体,那会报一堆没意义的错
            detectedOS = await app.detectISO(url)
            if let detectedOS, detectedOS != os { return }
            do {
                let found = try await app.inspectISO(url, os: os)
                variants = found
                // Windows 的索引必须来自实测解析(中文 ARM64 ISO 只有 3 个版本,Pro 是 3 不是 6);
                // Ubuntu 优先 minimal
                variantID = VMInstaller.pickVariant(found, os: os, preferred: nil)?.id
            } catch {
                failure = error.localizedDescription
            }
        }
    }

    private func create() {
        var settings = VMSettings.default(for: os)
        settings.network = Preferences.defaultNetwork
        settings.name = VMSettings.sanitizedName(name)
        settings.cpuCount = cpus
        settings.memoryMB = memoryGB * 1024
        settings.diskSizeGB = diskGB
        // clamp 直接采用修正后的值并把说明显示出来。以前一有说明就 return,
        // 而每次点击都重新构造再 clamp,说明永远在,按钮永远点不成。
        notes = settings.clamp()
        guard let iso = isoURL, let variant = variantID else { return }

        var unattend = UnattendOptions(editionIndex: Int(variant) ?? 1)
        unattend.username = username
        unattend.password = password
        var ubuntu = UbuntuInstallOptions()
        ubuntu.username = username
        ubuntu.password = password

        failure = nil
        phase = .creatingBundle
        Task {
            do {
                let ref = try await app.createAndInstall(
                    settings: settings, iso: iso, virtioISO: virtioURL, variantID: variant,
                    unattend: unattend, ubuntu: ubuntu,
                    progress: { phase = $0 })
                dismiss()
                openWindow(id: "vm", value: ref)
            } catch {
                phase = nil
                failure = error.localizedDescription
            }
        }
    }
}
