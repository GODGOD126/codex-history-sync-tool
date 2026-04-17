param(
  [switch]$InstallShortcutOnly,
  [switch]$SmokeTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$script:UiScriptPath = $MyInvocation.MyCommand.Path
$script:ToolRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:BackendPath = Join-Path $script:ToolRoot 'sync_backend.py'
$script:ShortcutName = 'Codex 对话同步工具.lnk'
$script:IconLocation = 'C:\Windows\System32\imageres.dll,15'
$script:BackupMap = @{}
$script:LatestState = $null

function Invoke-Backend {
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$Arguments
  )

  if (-not (Test-Path -LiteralPath $script:BackendPath)) {
    throw "缺少后端脚本: $script:BackendPath"
  }

  $output = & py -3 $script:BackendPath @Arguments 2>&1
  $exitCode = $LASTEXITCODE
  $text = (($output | ForEach-Object { "$_" }) -join [Environment]::NewLine).Trim()
  if (-not $text) {
    throw '后端没有返回任何内容。'
  }

  try {
    $json = $text | ConvertFrom-Json
  } catch {
    throw "后端 JSON 解析失败。`r`n原始错误: $($_.Exception.Message)`r`n返回内容:`r`n$text"
  }

  if ($exitCode -ne 0 -or -not $json.ok) {
    if ($json.error) {
      throw [string]$json.error
    }
    throw "后端执行失败。`r`n$text"
  }

  return $json
}

function New-DesktopShortcut {
  $desktopPath = [Environment]::GetFolderPath('Desktop')
  $shortcutPath = Join-Path $desktopPath $script:ShortcutName
  $targetPath = Join-Path $PSHOME 'powershell.exe'
  $arguments = "-NoProfile -ExecutionPolicy Bypass -Sta -WindowStyle Hidden -File `"$script:UiScriptPath`""

  $shell = New-Object -ComObject WScript.Shell
  $shortcut = $shell.CreateShortcut($shortcutPath)
  $shortcut.TargetPath = $targetPath
  $shortcut.Arguments = $arguments
  $shortcut.WorkingDirectory = $script:ToolRoot
  $shortcut.IconLocation = $script:IconLocation
  $shortcut.Description = 'Codex history sync UI'
  $shortcut.Save()

  return $shortcutPath
}

if ($InstallShortcutOnly) {
  $createdShortcut = New-DesktopShortcut
  Write-Output "桌面快捷方式已创建: $createdShortcut"
  exit 0
}

function Append-Log {
  param([string]$Message)

  $timestamp = Get-Date -Format 'HH:mm:ss'
  $logBox.AppendText("[$timestamp] $Message`r`n")
  $logBox.SelectionStart = $logBox.TextLength
  $logBox.ScrollToCaret()
}

function Format-Counts {
  param($Counts)

  if (-not $Counts -or $Counts.Count -eq 0) {
    return '无'
  }

  return (($Counts | ForEach-Object { "$($_.provider)=$($_.count)" }) -join ', ')
}

function Format-Duration {
  param($Milliseconds)

  if ($null -eq $Milliseconds) {
    return '0 秒'
  }

  $seconds = [Math]::Round(([double]$Milliseconds / 1000), 1)
  return "$seconds 秒"
}

function Set-Busy {
  param(
    [bool]$Busy,
    [string]$Message = ''
  )

  foreach ($button in @($refreshButton, $syncButton, $backupButton, $restoreButton, $restoreLatestButton, $shortcutButton)) {
    if ($button) {
      $button.Enabled = -not $Busy
    }
  }
  if ($openBackupsButton) {
    $openBackupsButton.Enabled = $true
  }

  if ($Busy) {
    $statusLabel.Text = $Message
    $progressBar.Style = 'Marquee'
    $progressBar.Visible = $true
  } else {
    $progressBar.Style = 'Blocks'
    $progressBar.Visible = $false
    if ($script:LatestState) {
      $statusLabel.Text = Get-FriendlyStatus $script:LatestState
    } else {
      $statusLabel.Text = '准备就绪'
    }
  }
}

function Get-FriendlyStatus {
  param($Status)

  if ([int]$Status.movable_threads -le 0) {
    return '一切正常：历史记录已经挂到当前账号/Provider。'
  }

  $parts = @()
  if ([int]$Status.movable_database_threads -gt 0) {
    $parts += "$($Status.movable_database_threads) 条数据库记录待迁移"
  }
  if ([int]$Status.movable_session_threads -gt 0) {
    $parts += "$($Status.movable_session_threads) 个会话文件待修正"
  }
  if ([int]$Status.missing_session_index_entries -gt 0) {
    $parts += "$($Status.missing_session_index_entries) 条侧边栏索引待补回"
  }
  return "需要同步：" + ($parts -join '，') + '。'
}

function Refresh-State {
  $status = Invoke-Backend @('--json', 'status')
  Apply-State $status
  Append-Log "状态已刷新：$(Get-FriendlyStatus $status)"
}

function Apply-State {
  param($Status)

  $script:LatestState = $Status

  $providerLabel.Text = "当前账号/Provider: $($Status.current_provider)"
  $modelLabel.Text = if ($Status.current_model) { "当前模型: $($Status.current_model)" } else { '当前模型: 未读取到' }
  $summaryLabel.Text = "历史线程: $($Status.total_threads)    会话文件: $($Status.session_file_count)    侧边栏索引: $($Status.indexed_threads)"
  $repairLabel.Text = "待修复: $($Status.movable_threads)    数据库: $($Status.movable_database_threads)    会话文件: $($Status.movable_session_threads)    索引: $($Status.missing_session_index_entries)"
  $pathLabel.Text = "数据位置: $($Status.codex_home)"
  $statusLabel.Text = Get-FriendlyStatus $Status

  $providersView.Items.Clear()
  foreach ($row in $Status.provider_counts) {
    $isCurrent = if ($row.provider -eq $Status.current_provider) { '当前' } else { '' }
    $item = New-Object System.Windows.Forms.ListViewItem([string]$row.provider)
    [void]$item.SubItems.Add([string]$row.count)
    [void]$item.SubItems.Add('数据库')
    [void]$item.SubItems.Add($isCurrent)
    [void]$providersView.Items.Add($item)
  }
  foreach ($row in $Status.session_provider_counts) {
    $isCurrent = if ($row.provider -eq $Status.current_provider) { '当前' } else { '' }
    $item = New-Object System.Windows.Forms.ListViewItem([string]$row.provider)
    [void]$item.SubItems.Add([string]$row.count)
    [void]$item.SubItems.Add('会话文件')
    [void]$item.SubItems.Add($isCurrent)
    [void]$providersView.Items.Add($item)
  }

  $backupList.Items.Clear()
  $script:BackupMap = @{}
  foreach ($backup in $Status.backups) {
    $label = "$($backup.modified_at)    $($backup.name)"
    $script:BackupMap[$label] = $backup.path
    [void]$backupList.Items.Add($label)
  }
}

function Confirm-Action {
  param(
    [string]$Message,
    [string]$Title = '确认操作'
  )

  $choice = [System.Windows.Forms.MessageBox]::Show(
    $Message,
    $Title,
    [System.Windows.Forms.MessageBoxButtons]::OKCancel,
    [System.Windows.Forms.MessageBoxIcon]::Question
  )

  return $choice -eq [System.Windows.Forms.DialogResult]::OK
}

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Codex 历史找回助手'
$form.StartPosition = 'CenterScreen'
$form.Size = New-Object System.Drawing.Size(920, 700)
$form.MinimumSize = New-Object System.Drawing.Size(920, 700)
$form.BackColor = [System.Drawing.Color]::FromArgb(246, 248, 251)
$form.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)

$headerLabel = New-Object System.Windows.Forms.Label
$headerLabel.Text = 'Codex 历史找回助手'
$headerLabel.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 18, [System.Drawing.FontStyle]::Bold)
$headerLabel.AutoSize = $true
$headerLabel.Location = New-Object System.Drawing.Point(24, 18)
$form.Controls.Add($headerLabel)

$introLabel = New-Object System.Windows.Forms.Label
$introLabel.Text = '用于把“换了 API / Provider / 登录方式后看不见的本地历史”重新挂回当前 Codex。Codex 开着也可以试，工具会等待数据库空闲。'
$introLabel.ForeColor = [System.Drawing.Color]::FromArgb(77, 89, 105)
$introLabel.AutoSize = $true
$introLabel.MaximumSize = New-Object System.Drawing.Size(850, 0)
$introLabel.Location = New-Object System.Drawing.Point(26, 54)
$form.Controls.Add($introLabel)

$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Text = '正在读取状态...'
$statusLabel.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10, [System.Drawing.FontStyle]::Bold)
$statusLabel.ForeColor = [System.Drawing.Color]::FromArgb(28, 84, 160)
$statusLabel.AutoSize = $true
$statusLabel.MaximumSize = New-Object System.Drawing.Size(850, 0)
$statusLabel.Location = New-Object System.Drawing.Point(26, 92)
$form.Controls.Add($statusLabel)

$progressBar = New-Object System.Windows.Forms.ProgressBar
$progressBar.Location = New-Object System.Drawing.Point(28, 124)
$progressBar.Size = New-Object System.Drawing.Size(840, 8)
$progressBar.Visible = $false
$form.Controls.Add($progressBar)

$providerLabel = New-Object System.Windows.Forms.Label
$providerLabel.Text = '当前账号/Provider:'
$providerLabel.AutoSize = $true
$providerLabel.Location = New-Object System.Drawing.Point(28, 150)
$form.Controls.Add($providerLabel)

$modelLabel = New-Object System.Windows.Forms.Label
$modelLabel.Text = '当前模型:'
$modelLabel.AutoSize = $true
$modelLabel.Location = New-Object System.Drawing.Point(28, 174)
$form.Controls.Add($modelLabel)

$summaryLabel = New-Object System.Windows.Forms.Label
$summaryLabel.Text = '历史线程:'
$summaryLabel.AutoSize = $true
$summaryLabel.Location = New-Object System.Drawing.Point(28, 198)
$form.Controls.Add($summaryLabel)

$repairLabel = New-Object System.Windows.Forms.Label
$repairLabel.Text = '待修复:'
$repairLabel.AutoSize = $true
$repairLabel.Location = New-Object System.Drawing.Point(28, 222)
$form.Controls.Add($repairLabel)

$pathLabel = New-Object System.Windows.Forms.Label
$pathLabel.Text = '数据位置:'
$pathLabel.AutoSize = $true
$pathLabel.Location = New-Object System.Drawing.Point(28, 246)
$pathLabel.MaximumSize = New-Object System.Drawing.Size(840, 0)
$form.Controls.Add($pathLabel)

$refreshButton = New-Object System.Windows.Forms.Button
$refreshButton.Text = '重新检查'
$refreshButton.Size = New-Object System.Drawing.Size(110, 36)
$refreshButton.Location = New-Object System.Drawing.Point(28, 286)
$form.Controls.Add($refreshButton)

$syncButton = New-Object System.Windows.Forms.Button
$syncButton.Text = '开始找回历史'
$syncButton.Size = New-Object System.Drawing.Size(150, 36)
$syncButton.Location = New-Object System.Drawing.Point(150, 286)
$syncButton.BackColor = [System.Drawing.Color]::FromArgb(32, 91, 177)
$syncButton.ForeColor = [System.Drawing.Color]::White
$syncButton.FlatStyle = 'Flat'
$form.Controls.Add($syncButton)

$backupButton = New-Object System.Windows.Forms.Button
$backupButton.Text = '先做备份'
$backupButton.Size = New-Object System.Drawing.Size(110, 36)
$backupButton.Location = New-Object System.Drawing.Point(316, 286)
$form.Controls.Add($backupButton)

$openBackupsButton = New-Object System.Windows.Forms.Button
$openBackupsButton.Text = '打开备份'
$openBackupsButton.Size = New-Object System.Drawing.Size(110, 36)
$openBackupsButton.Location = New-Object System.Drawing.Point(438, 286)
$form.Controls.Add($openBackupsButton)

$shortcutButton = New-Object System.Windows.Forms.Button
$shortcutButton.Text = '更新桌面入口'
$shortcutButton.Size = New-Object System.Drawing.Size(130, 36)
$shortcutButton.Location = New-Object System.Drawing.Point(560, 286)
$form.Controls.Add($shortcutButton)

$providersBox = New-Object System.Windows.Forms.GroupBox
$providersBox.Text = '历史归属'
$providersBox.Location = New-Object System.Drawing.Point(28, 342)
$providersBox.Size = New-Object System.Drawing.Size(400, 170)
$form.Controls.Add($providersBox)

$providersView = New-Object System.Windows.Forms.ListView
$providersView.View = 'Details'
$providersView.FullRowSelect = $true
$providersView.GridLines = $true
$providersView.Location = New-Object System.Drawing.Point(12, 26)
$providersView.Size = New-Object System.Drawing.Size(376, 132)
[void]$providersView.Columns.Add('账号/Provider', 150)
[void]$providersView.Columns.Add('数量', 70)
[void]$providersView.Columns.Add('位置', 90)
[void]$providersView.Columns.Add('状态', 60)
$providersBox.Controls.Add($providersView)

$backupsBox = New-Object System.Windows.Forms.GroupBox
$backupsBox.Text = '安全备份'
$backupsBox.Location = New-Object System.Drawing.Point(450, 342)
$backupsBox.Size = New-Object System.Drawing.Size(418, 170)
$form.Controls.Add($backupsBox)

$backupList = New-Object System.Windows.Forms.ListBox
$backupList.Location = New-Object System.Drawing.Point(12, 24)
$backupList.Size = New-Object System.Drawing.Size(394, 94)
$backupsBox.Controls.Add($backupList)

$restoreButton = New-Object System.Windows.Forms.Button
$restoreButton.Text = '恢复选中备份'
$restoreButton.Size = New-Object System.Drawing.Size(122, 32)
$restoreButton.Location = New-Object System.Drawing.Point(12, 126)
$backupsBox.Controls.Add($restoreButton)

$restoreLatestButton = New-Object System.Windows.Forms.Button
$restoreLatestButton.Text = '恢复最新备份'
$restoreLatestButton.Size = New-Object System.Drawing.Size(122, 32)
$restoreLatestButton.Location = New-Object System.Drawing.Point(146, 126)
$backupsBox.Controls.Add($restoreLatestButton)

$logBox = New-Object System.Windows.Forms.TextBox
$logBox.Multiline = $true
$logBox.ScrollBars = 'Vertical'
$logBox.ReadOnly = $true
$logBox.Location = New-Object System.Drawing.Point(28, 530)
$logBox.Size = New-Object System.Drawing.Size(840, 120)
$logBox.BackColor = [System.Drawing.Color]::White
$form.Controls.Add($logBox)

$refreshButton.Add_Click({
  try {
    Refresh-State
  } catch {
    [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '刷新失败', 'OK', 'Error') | Out-Null
    Append-Log "刷新失败: $($_.Exception.Message)"
  }
})

$syncButton.Add_Click({
  try {
    if (-not $script:LatestState) {
      Refresh-State
    }
    if ([int]$script:LatestState.movable_threads -le 0) {
      [System.Windows.Forms.MessageBox]::Show('当前已经整理好了，不需要再同步。', '无需同步', 'OK', 'Information') | Out-Null
      Append-Log '同步跳过：当前已经没有需要修复的历史。'
      return
    }
    $message = "将把旧账号/Provider 下的本地历史挂回当前账号：`r`n$($script:LatestState.current_provider)`r`n`r`n本次预计处理：$($script:LatestState.movable_threads) 项`r`n包含数据库记录、会话文件和侧边栏索引。`r`n`r`n工具会先自动备份。Codex 正在运行也可以，但如果它正在写入历史，可能会等待几秒。"
    if (-not (Confirm-Action -Message $message -Title '开始找回历史？')) {
      Append-Log '用户取消了同步。'
      return
    }

    Set-Busy -Busy $true -Message '正在同步历史，Codex 忙的时候会自动等一会儿...'
    $result = Invoke-Backend @('--json', 'sync')
    Append-Log "同步完成。数据库更新 $($result.updated_rows) 条，会话文件更新 $($result.updated_session_files) 个。"
    Append-Log "等待数据库空闲: $(Format-Duration $result.lock_wait_ms)，总耗时: $(Format-Duration $result.timing.total_ms)。"
    Append-Log "数据库同步前: $(Format-Counts $result.before_counts)"
    Append-Log "数据库同步后: $(Format-Counts $result.after_counts)"
    Append-Log "会话文件同步前: $(Format-Counts $result.session_before_counts)"
    Append-Log "会话文件同步后: $(Format-Counts $result.session_after_counts)"
    Append-Log "侧边栏索引已重建: $($result.rewritten_index_entries) 条，补回 $($result.missing_session_index_entries_before) 条。"
    Append-Log "备份文件: $($result.backup_path)"
    Apply-State $result.status
    [System.Windows.Forms.MessageBox]::Show('同步完成。如果侧边栏没有马上刷新，重新打开 Codex 即可。', '同步完成', 'OK', 'Information') | Out-Null
  } catch {
    [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '同步失败', 'OK', 'Error') | Out-Null
    Append-Log "同步失败: $($_.Exception.Message)"
  } finally {
    Set-Busy -Busy $false
  }
})

$backupButton.Add_Click({
  try {
    Set-Busy -Busy $true -Message '正在创建安全备份...'
    $result = Invoke-Backend @('--json', 'backup')
    Append-Log "手动备份完成: $($result.backup_path)"
    Append-Log "备份耗时: $(Format-Duration $result.timing.total_ms)"
    Refresh-State
  } catch {
    [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '备份失败', 'OK', 'Error') | Out-Null
    Append-Log "备份失败: $($_.Exception.Message)"
  } finally {
    Set-Busy -Busy $false
  }
})

$openBackupsButton.Add_Click({
  try {
    if (-not $script:LatestState) {
      Refresh-State
    }
    $folder = $script:LatestState.backup_dir
    if (-not (Test-Path -LiteralPath $folder)) {
      New-Item -ItemType Directory -Force -Path $folder | Out-Null
    }
    Start-Process explorer.exe $folder
    Append-Log "已打开备份目录: $folder"
  } catch {
    [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '打开目录失败', 'OK', 'Error') | Out-Null
    Append-Log "打开备份目录失败: $($_.Exception.Message)"
  }
})

$shortcutButton.Add_Click({
  try {
    $path = New-DesktopShortcut
    Append-Log "桌面入口已更新: $path"
    [System.Windows.Forms.MessageBox]::Show("桌面入口已更新：`r`n$path", '完成', 'OK', 'Information') | Out-Null
  } catch {
    [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '创建入口失败', 'OK', 'Error') | Out-Null
    Append-Log "创建入口失败: $($_.Exception.Message)"
  }
})

$restoreButton.Add_Click({
  try {
    if ($backupList.SelectedItem -eq $null) {
      [System.Windows.Forms.MessageBox]::Show('请先在右侧选一个备份。', '未选择备份', 'OK', 'Warning') | Out-Null
      return
    }
    $selectedLabel = [string]$backupList.SelectedItem
    $backupPath = $script:BackupMap[$selectedLabel]
    if (-not $backupPath) {
      throw '无法解析选中的备份路径。'
    }

    $message = "将恢复这个备份：`r`n$backupPath`r`n`r`n恢复前会再自动做一份当前状态备份，方便反悔。"
    if (-not (Confirm-Action -Message $message -Title '确认恢复？')) {
      Append-Log '用户取消了恢复。'
      return
    }

    Set-Busy -Busy $true -Message '正在恢复备份...'
    $result = Invoke-Backend @('--json', 'restore', '--backup', $backupPath)
    Append-Log "恢复完成。来源备份: $($result.restored_from)"
    Append-Log "恢复前安全备份: $($result.safety_backup)"
    Append-Log "恢复耗时: $(Format-Duration $result.timing.total_ms)"
    Apply-State $result.status
    [System.Windows.Forms.MessageBox]::Show('恢复完成。建议重新打开 Codex 再看历史列表。', '恢复完成', 'OK', 'Information') | Out-Null
  } catch {
    [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '恢复失败', 'OK', 'Error') | Out-Null
    Append-Log "恢复失败: $($_.Exception.Message)"
  } finally {
    Set-Busy -Busy $false
  }
})

$restoreLatestButton.Add_Click({
  try {
    if (-not (Confirm-Action -Message '将恢复最新备份，并在恢复前再做一次当前状态备份。' -Title '确认恢复最新备份？')) {
      Append-Log '用户取消了恢复最新备份。'
      return
    }

    Set-Busy -Busy $true -Message '正在恢复最新备份...'
    $result = Invoke-Backend @('--json', 'restore')
    Append-Log "已恢复最新备份: $($result.restored_from)"
    Append-Log "恢复前安全备份: $($result.safety_backup)"
    Append-Log "恢复耗时: $(Format-Duration $result.timing.total_ms)"
    Apply-State $result.status
    [System.Windows.Forms.MessageBox]::Show('恢复完成。建议重新打开 Codex 再看历史列表。', '恢复完成', 'OK', 'Information') | Out-Null
  } catch {
    [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '恢复失败', 'OK', 'Error') | Out-Null
    Append-Log "恢复失败: $($_.Exception.Message)"
  } finally {
    Set-Busy -Busy $false
  }
})

try {
  $createdShortcut = New-DesktopShortcut
  Append-Log "桌面入口已准备好: $createdShortcut"
} catch {
  Append-Log "初始化桌面入口失败: $($_.Exception.Message)"
}

try {
  Refresh-State
} catch {
  Append-Log "初始化状态失败: $($_.Exception.Message)"
  [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '启动失败', 'OK', 'Error') | Out-Null
}

if ($SmokeTest) {
  Write-Output 'Smoke test OK'
  exit 0
}

[void]$form.ShowDialog()
