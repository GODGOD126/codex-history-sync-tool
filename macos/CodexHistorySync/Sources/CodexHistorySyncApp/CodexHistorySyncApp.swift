import AppKit
import SwiftUI
import CodexHistoryCore

@main
struct CodexHistorySyncApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 920, minHeight: 680)
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

private struct ContentView: View {
    @StateObject private var viewModel = AppViewModel()
    @State private var pendingConfirmation: PendingConfirmation?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            statusSummary
            actions
            details
            logView
        }
        .padding(24)
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            await viewModel.refresh()
        }
        .alert("操作失败", isPresented: Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        .confirmationDialog(
            pendingConfirmation?.title ?? "",
            isPresented: Binding(
                get: { pendingConfirmation != nil },
                set: { if !$0 { pendingConfirmation = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let pendingConfirmation {
                Button(pendingConfirmation.primaryTitle, role: pendingConfirmation.role) {
                    Task {
                        await run(pendingConfirmation)
                    }
                }
                Button("取消", role: .cancel) {}
            }
        } message: {
            Text(pendingConfirmation?.message ?? "")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Codex 历史找回助手")
                .font(.system(size: 28, weight: .bold))
            Text("把切换 API / Provider / 登录方式后暂时看不到的本地历史重新挂回当前 Codex 设置。")
                .foregroundStyle(.secondary)
        }
    }

    private var statusSummary: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: viewModel.statusIconName)
                    .font(.title2)
                    .foregroundStyle(viewModel.statusColor)
                    .frame(width: 28)
                Text(viewModel.friendlyStatus)
                    .font(.headline)
                    .foregroundStyle(viewModel.statusColor)
                Spacer()
                if viewModel.isBusy {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: 12),
                GridItem(.flexible(), spacing: 12),
                GridItem(.flexible(), spacing: 12)
            ], spacing: 12) {
                MetricTile(title: "当前 Provider", value: viewModel.status?.currentProvider ?? "未读取")
                MetricTile(title: "当前模型", value: viewModel.status?.currentModel ?? "未读取")
                MetricTile(title: "待修复", value: "\(viewModel.status?.movableThreads ?? 0)")
                MetricTile(title: "数据库线程", value: "\(viewModel.status?.totalThreads ?? 0)")
                MetricTile(title: "会话文件", value: "\(viewModel.status?.sessionFileCount ?? 0)")
                MetricTile(title: "侧边栏索引", value: "\(viewModel.status?.indexedThreads ?? 0)")
            }

            Text(viewModel.status?.codexHome.path ?? defaultCodexHome().path)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button {
                Task { await viewModel.refresh() }
            } label: {
                Label("重新检查", systemImage: "arrow.clockwise")
            }
            .disabled(viewModel.isBusy)

            Button {
                pendingConfirmation = .sync(viewModel.status)
            } label: {
                Label("开始找回历史", systemImage: "wand.and.stars")
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.isBusy || (viewModel.status?.movableThreads ?? 0) <= 0)

            Button {
                Task { await viewModel.createBackup() }
            } label: {
                Label("先做备份", systemImage: "externaldrive.badge.plus")
            }
            .disabled(viewModel.isBusy)

            Button {
                viewModel.openBackupsInFinder()
            } label: {
                Label("打开备份", systemImage: "folder")
            }

            Spacer()

            Button {
                if let backup = viewModel.selectedBackup {
                    pendingConfirmation = .restore(backup)
                }
            } label: {
                Label("恢复选中备份", systemImage: "arrow.uturn.backward")
            }
            .disabled(viewModel.isBusy || viewModel.selectedBackup == nil)

            Button {
                if let backup = viewModel.status?.backups.first {
                    pendingConfirmation = .restoreLatest(backup)
                }
            } label: {
                Label("恢复最新备份", systemImage: "clock.arrow.circlepath")
            }
            .disabled(viewModel.isBusy || (viewModel.status?.backups.isEmpty ?? true))
        }
    }

    private var details: some View {
        HStack(alignment: .top, spacing: 16) {
            GroupBox("历史归属") {
                VStack(alignment: .leading, spacing: 10) {
                    CountRows(
                        title: "数据库",
                        rows: viewModel.status?.providerCounts.map { ($0.provider, $0.count) } ?? [],
                        currentValue: viewModel.status?.currentProvider
                    )
                    Divider()
                    CountRows(
                        title: "会话文件",
                        rows: viewModel.status?.sessionProviderCounts.map { ($0.provider, $0.count) } ?? [],
                        currentValue: viewModel.status?.currentProvider
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
            }

            GroupBox("安全备份") {
                List(selection: $viewModel.selectedBackupID) {
                    ForEach(viewModel.status?.backups ?? []) { backup in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(backup.name)
                                .font(.body)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(backup.modifiedAt.formatted(date: .abbreviated, time: .standard))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .tag(backup.path)
                    }
                }
                .frame(minHeight: 168)
            }
        }
        .frame(minHeight: 220)
    }

    private var logView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("日志")
                .font(.headline)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(viewModel.logLines.enumerated()), id: \.offset) { index, line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(index)
                        }
                    }
                    .padding(10)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .onChange(of: viewModel.logLines.count) { count in
                    guard count > 0 else { return }
                    proxy.scrollTo(count - 1, anchor: .bottom)
                }
            }
        }
        .frame(minHeight: 130)
    }

    private func run(_ confirmation: PendingConfirmation) async {
        let action = confirmation.action
        pendingConfirmation = nil
        switch action {
        case .sync:
            await viewModel.sync()
        case .restore(let backup):
            await viewModel.restore(backup)
        }
    }
}

private struct MetricTile: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 16, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
        .padding(.horizontal, 12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

private struct CountRows: View {
    let title: String
    let rows: [(String, Int)]
    let currentValue: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            if rows.isEmpty {
                Text("无")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(rows, id: \.0) { value, count in
                    HStack {
                        Text(value)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if value == currentValue {
                            Text("当前")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.14))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                        Spacer()
                        Text("\(count)")
                            .foregroundStyle(.secondary)
                    }
                    .font(.subheadline)
                }
            }
        }
    }
}

@MainActor
private final class AppViewModel: ObservableObject {
    @Published var status: CodexStatus?
    @Published var isBusy = false
    @Published var errorMessage: String?
    @Published var logLines: [String] = []
    @Published var selectedBackupID: URL?

    var selectedBackup: BackupInfo? {
        guard let selectedBackupID else {
            return nil
        }
        return status?.backups.first { $0.path == selectedBackupID }
    }

    var friendlyStatus: String {
        guard let status else {
            return isBusy ? "正在读取状态..." : "尚未读取状态"
        }
        if status.movableThreads <= 0 {
            return "一切正常：历史记录已经挂到当前账号/Provider。"
        }
        var parts: [String] = []
        if status.movableDatabaseThreads > 0 {
            parts.append("\(status.movableDatabaseThreads) 条数据库记录待迁移")
        }
        if let modelMovable = status.modelMovableThreads, modelMovable > 0 {
            parts.append("\(modelMovable) 条模型归属待修正")
        }
        if status.movableSessionThreads > 0 {
            parts.append("\(status.movableSessionThreads) 个会话文件待修正")
        }
        if status.missingSessionIndexEntries > 0 {
            parts.append("\(status.missingSessionIndexEntries) 条侧边栏索引待补回")
        }
        return "需要同步：" + parts.joined(separator: "，") + "。"
    }

    var statusIconName: String {
        (status?.movableThreads ?? 0) > 0 ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
    }

    var statusColor: Color {
        (status?.movableThreads ?? 0) > 0 ? .orange : .green
    }

    func refresh() async {
        await runBusy("正在读取状态...") {
            let loaded = try await Task.detached {
                try loadStatus()
            }.value
            self.status = loaded
            self.appendLog("状态已刷新：\(self.friendlyStatus)")
        }
    }

    func createBackup() async {
        await runBusy("正在创建备份...") {
            let backup = try await Task.detached {
                try makeBackup(label: "manual")
            }.value
            self.appendLog("备份已创建：\(backup.path)")
            self.status = try await Task.detached {
                try loadStatus()
            }.value
        }
    }

    func sync() async {
        await runBusy("正在同步历史...") {
            let result = try await Task.detached {
                try syncToCurrentProvider()
            }.value
            self.status = result.status
            self.appendLog("同步完成。数据库更新 \(result.updatedRows) 条，会话文件更新 \(result.updatedSessionFiles) 个。")
            self.appendLog("侧边栏索引已重建 \(result.rewrittenIndexEntries) 条，补回 \(result.missingSessionIndexEntriesBefore) 条。")
            self.appendLog("等待数据库空闲 \(formatDuration(result.lockWaitMilliseconds))，总耗时 \(formatDuration(result.timing.totalMilliseconds))。")
            self.appendLog("备份文件：\(result.backupPath.path)")
        }
    }

    func restore(_ backup: BackupInfo) async {
        let backupPath = backup.path
        await runBusy("正在恢复备份...") {
            let result = try await Task.detached {
                try restoreBackup(backupPath: backupPath)
            }.value
            self.status = result.status
            self.appendLog("恢复完成：\(result.restoredFrom.path)")
            self.appendLog("恢复前安全备份：\(result.safetyBackup.path)")
            self.appendLog("会话元数据恢复 \(result.metadataRestore.sessionFilesRestored) 个文件，索引重建 \(result.rewrittenIndexEntries) 条。")
        }
    }

    func openBackupsInFinder() {
        let url = status?.backupDirectory ?? defaultCodexHome().appendingPathComponent("history_sync_backups", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func runBusy(_ message: String, operation: @escaping @MainActor () async throws -> Void) async {
        guard !isBusy else {
            return
        }
        isBusy = true
        appendLog(message)
        do {
            try await operation()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            appendLog("失败：\(errorMessage ?? "未知错误")")
        }
        isBusy = false
    }

    private func appendLog(_ message: String) {
        let time = Date().formatted(date: .omitted, time: .standard)
        logLines.append("[\(time)] \(message)")
    }
}

private enum PendingAction: Equatable {
    case sync
    case restore(BackupInfo)
}

private struct PendingConfirmation: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let message: String
    let primaryTitle: String
    let role: ButtonRole?
    let action: PendingAction

    static func sync(_ status: CodexStatus?) -> PendingConfirmation {
        PendingConfirmation(
            title: "开始找回历史？",
            message: "将把旧账号/Provider/模型下的本地历史挂回当前设置。Provider: \(status?.currentProvider ?? "未知")，模型: \(status?.currentModel ?? "未读取")。工具会先自动备份。",
            primaryTitle: "开始同步",
            role: nil,
            action: .sync
        )
    }

    static func restore(_ backup: BackupInfo) -> PendingConfirmation {
        PendingConfirmation(
            title: "恢复选中备份？",
            message: "将从 \(backup.name) 恢复数据库、侧边栏索引和会话首行元数据。恢复前会再创建一份安全备份。",
            primaryTitle: "恢复备份",
            role: .destructive,
            action: .restore(backup)
        )
    }

    static func restoreLatest(_ backup: BackupInfo) -> PendingConfirmation {
        PendingConfirmation(
            title: "恢复最新备份？",
            message: "将从最新备份 \(backup.name) 恢复。恢复前会再创建一份安全备份。",
            primaryTitle: "恢复最新备份",
            role: .destructive,
            action: .restore(backup)
        )
    }
}

private func formatDuration(_ milliseconds: Int) -> String {
    let seconds = Double(milliseconds) / 1000.0
    return String(format: "%.1f 秒", seconds)
}
