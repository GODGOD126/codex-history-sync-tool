import AppKit
import Foundation

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private let summaryLabel = NSTextField(labelWithString: "正在读取本地状态...")
    private let pathLabel = NSTextField(labelWithString: "")
    private let detailsView = NSTextView()
    private let backupPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let progress = NSProgressIndicator()
    private let statusLabel = NSTextField(labelWithString: "就绪")
    private var actionButtons: [NSButton] = []
    private var backups: [[String: Any]] = []
    private var backendPath = ""

    func applicationDidFinishLaunching(_ notification: Notification) {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let baseDirectory = executable.deletingLastPathComponent()
        backendPath = baseDirectory.appendingPathComponent("sync_backend.py").path
        if !FileManager.default.fileExists(atPath: backendPath) {
            backendPath = FileManager.default.currentDirectoryPath + "/sync_backend.py"
        }

        buildWindow()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        refreshStatus()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func buildWindow() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 610),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Codex 历史同步工具"
        window.center()
        window.minSize = NSSize(width: 680, height: 520)

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 12
        root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 20),
            root.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -20),
            root.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 20),
            root.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -18),
        ])

        let title = NSTextField(labelWithString: "Codex 历史同步工具")
        title.font = .systemFont(ofSize: 24, weight: .semibold)
        root.addArrangedSubview(title)

        let intro = NSTextField(wrappingLabelWithString: "将本地旧 provider / model 下的对话同步到当前 Codex 配置。所有写入操作都会先创建备份。")
        intro.textColor = .secondaryLabelColor
        root.addArrangedSubview(intro)

        summaryLabel.font = .systemFont(ofSize: 14, weight: .medium)
        summaryLabel.maximumNumberOfLines = 4
        root.addArrangedSubview(summaryLabel)

        pathLabel.textColor = .secondaryLabelColor
        pathLabel.lineBreakMode = .byTruncatingMiddle
        root.addArrangedSubview(pathLabel)

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 8
        let refresh = makeButton("刷新", action: #selector(refreshPressed))
        let sync = makeButton("同步到当前配置", action: #selector(syncPressed))
        sync.keyEquivalent = "\r"
        let backup = makeButton("创建备份", action: #selector(backupPressed))
        let restore = makeButton("恢复所选备份", action: #selector(restorePressed))
        let openFolder = makeButton("打开备份目录", action: #selector(openBackupFolder))
        actionButtons = [refresh, sync, backup, restore]
        [refresh, sync, backup, restore, openFolder].forEach { buttons.addArrangedSubview($0) }
        root.addArrangedSubview(buttons)

        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.translatesAutoresizingMaskIntoConstraints = false
        split.heightAnchor.constraint(greaterThanOrEqualToConstant: 280).isActive = true

        let detailsScroll = NSScrollView()
        detailsScroll.borderType = .bezelBorder
        detailsScroll.hasVerticalScroller = true
        detailsScroll.drawsBackground = true
        detailsScroll.backgroundColor = .textBackgroundColor
        detailsView.frame = detailsScroll.contentView.bounds
        detailsView.isEditable = false
        detailsView.isSelectable = true
        detailsView.isVerticallyResizable = true
        detailsView.isHorizontallyResizable = false
        detailsView.autoresizingMask = [.width]
        detailsView.minSize = NSSize(width: 0, height: 0)
        detailsView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        detailsView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        detailsView.textColor = .labelColor
        detailsView.backgroundColor = .textBackgroundColor
        detailsView.textContainerInset = NSSize(width: 10, height: 10)
        detailsView.textContainer?.containerSize = NSSize(
            width: detailsScroll.contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )
        detailsView.textContainer?.widthTracksTextView = true
        detailsScroll.documentView = detailsView
        split.addArrangedSubview(detailsScroll)

        let backupBox = NSBox()
        backupBox.title = "备份"
        backupBox.contentViewMargins = NSSize(width: 12, height: 12)
        backupPopup.translatesAutoresizingMaskIntoConstraints = false
        backupBox.contentView?.addSubview(backupPopup)
        NSLayoutConstraint.activate([
            backupPopup.leadingAnchor.constraint(equalTo: backupBox.contentView!.leadingAnchor),
            backupPopup.trailingAnchor.constraint(equalTo: backupBox.contentView!.trailingAnchor),
            backupPopup.topAnchor.constraint(equalTo: backupBox.contentView!.topAnchor, constant: 6),
        ])
        backupBox.widthAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true
        split.addArrangedSubview(backupBox)
        root.addArrangedSubview(split)
        split.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true

        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        let footer = NSStackView(views: [progress, statusLabel])
        footer.orientation = .horizontal
        footer.spacing = 8
        statusLabel.textColor = .secondaryLabelColor
        root.addArrangedSubview(footer)
    }

    private func makeButton(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        return button
    }

    private func setBusy(_ busy: Bool, message: String) {
        actionButtons.forEach { $0.isEnabled = !busy }
        busy ? progress.startAnimation(nil) : progress.stopAnimation(nil)
        statusLabel.stringValue = message
    }

    private func runBackend(_ arguments: [String], message: String, completion: @escaping ([String: Any]) -> Void) {
        setBusy(true, message: message)
        let backend = backendPath
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let process = Process()
                let output = Pipe()
                let errors = Pipe()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
                process.arguments = [backend, "--json"] + arguments
                process.standardOutput = output
                process.standardError = errors
                try process.run()
                process.waitUntilExit()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                let errorData = errors.fileHandleForReading.readDataToEndOfFile()
                guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    let text = String(data: errorData.isEmpty ? data : errorData, encoding: .utf8) ?? "未知错误"
                    throw NSError(domain: "CodexHistorySync", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
                }
                if payload["ok"] as? Bool != true {
                    throw NSError(domain: "CodexHistorySync", code: 2, userInfo: [NSLocalizedDescriptionKey: payload["error"] as? String ?? "操作失败"])
                }
                DispatchQueue.main.async {
                    self.setBusy(false, message: "操作完成")
                    completion(payload)
                }
            } catch {
                DispatchQueue.main.async {
                    self.setBusy(false, message: "失败：\(error.localizedDescription)")
                    self.showAlert(title: "操作失败", message: error.localizedDescription)
                }
            }
        }
    }

    @objc private func refreshPressed() { refreshStatus() }

    private func refreshStatus() {
        runBackend(["status"], message: "正在读取本地状态...") { payload in
            let provider = payload["current_provider"] as? String ?? "未设置"
            let model = payload["current_model"] as? String ?? "未设置"
            let total = payload["total_threads"] as? Int ?? 0
            let movable = payload["movable_threads"] as? Int ?? 0
            self.summaryLabel.stringValue = "当前 provider：\(provider)\n当前 model：\(model)\n历史线程：\(total) 个；需要整理：\(movable) 个"
            self.pathLabel.stringValue = "数据库：\(payload["db_path"] as? String ?? "")"

            var lines = ["Provider："]
            for row in payload["provider_counts"] as? [[String: Any]] ?? [] {
                lines.append("  \(row["provider"] ?? "")：\(row["count"] ?? 0)")
            }
            lines.append("\nModel：")
            for row in payload["model_counts"] as? [[String: Any]] ?? [] {
                lines.append("  \(row["model"] ?? "")：\(row["count"] ?? 0)")
            }
            lines.append("\n会话文件：\(payload["session_file_count"] ?? 0)")
            lines.append("缺失索引：\(payload["missing_session_index_entries"] ?? 0)")
            self.detailsView.string = lines.joined(separator: "\n")

            self.backups = payload["backups"] as? [[String: Any]] ?? []
            self.backupPopup.removeAllItems()
            if self.backups.isEmpty {
                self.backupPopup.addItem(withTitle: "暂无备份")
                self.backupPopup.isEnabled = false
            } else {
                self.backupPopup.addItems(withTitles: self.backups.compactMap { $0["name"] as? String })
                self.backupPopup.isEnabled = true
            }
            self.statusLabel.stringValue = "状态已刷新"
        }
    }

    @objc private func syncPressed() {
        guard confirm(title: "确认同步", message: "即将把本地历史同步到当前 provider / model。工具会先自动备份。是否继续？") else { return }
        runBackend(["sync"], message: "正在备份并同步...") { payload in
            let rows = payload["updated_rows"] ?? 0
            let files = payload["updated_session_files"] ?? 0
            self.showAlert(title: "同步完成", message: "数据库更新 \(rows) 条，会话文件更新 \(files) 个。\n如果侧边栏没有立即刷新，请重新打开 Codex。")
            self.refreshStatus()
        }
    }

    @objc private func backupPressed() {
        runBackend(["backup"], message: "正在创建备份...") { payload in
            self.showAlert(title: "备份完成", message: payload["backup_path"] as? String ?? "备份已创建")
            self.refreshStatus()
        }
    }

    @objc private func restorePressed() {
        guard !backups.isEmpty, backupPopup.indexOfSelectedItem >= 0 else {
            showAlert(title: "没有备份", message: "当前没有可恢复的备份。")
            return
        }
        guard confirm(title: "确认恢复", message: "恢复会覆盖当前本地历史状态，并先创建安全备份。是否继续？") else { return }
        let backup = backups[backupPopup.indexOfSelectedItem]["path"] as? String ?? ""
        runBackend(["restore", "--backup", backup], message: "正在创建安全备份并恢复...") { payload in
            self.showAlert(title: "恢复完成", message: "已从以下备份恢复：\n\(payload["restored_from"] ?? "")")
            self.refreshStatus()
        }
    }

    @objc private func openBackupFolder() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let folder = home.appendingPathComponent(".codex/history_sync_backups")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    private func confirm(title: String, message: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "继续")
        alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        alert.runModal()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
