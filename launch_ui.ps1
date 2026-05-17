param(
  [switch]$InstallShortcutOnly,
  [switch]$SmokeTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$script:UiScriptPath = $MyInvocation.MyCommand.Path
$script:ToolRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:BackendPath = Join-Path $script:ToolRoot 'sync_backend.py'
$script:ShortcutName = 'Codex 对话同步工具.lnk'
$script:IconLocation = 'C:\Windows\System32\imageres.dll,15'
$script:BackupMap = @{}
$script:LatestState = $null
$script:DoctorReady = $false
$script:SyncPreviewReady = $false
$script:RestorePreviewReady = $false
$script:RestorePreviewBackup = $null
$script:ColorWindow = [System.Drawing.Color]::FromArgb(246, 245, 242)
$script:ColorPanel = [System.Drawing.Color]::FromArgb(255, 255, 255)
$script:ColorBorder = [System.Drawing.Color]::FromArgb(226, 222, 214)
$script:ColorText = [System.Drawing.Color]::FromArgb(21, 21, 21)
$script:ColorMuted = [System.Drawing.Color]::FromArgb(111, 106, 96)
$script:ColorPrimary = [System.Drawing.Color]::FromArgb(37, 88, 212)
$script:ColorPrimaryDark = [System.Drawing.Color]::FromArgb(29, 73, 182)
$script:ColorAccent = [System.Drawing.Color]::FromArgb(17, 17, 17)
$script:ColorAccentDark = [System.Drawing.Color]::FromArgb(8, 8, 8)
$script:ColorGold = [System.Drawing.Color]::FromArgb(232, 219, 196)
$script:ColorSoftBlue = [System.Drawing.Color]::FromArgb(232, 238, 255)
$script:ColorSoftPeach = [System.Drawing.Color]::FromArgb(239, 242, 255)
$script:ColorDanger = [System.Drawing.Color]::FromArgb(175, 61, 61)

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

function Format-ModelCounts {
  param($Counts)

  if (-not $Counts -or $Counts.Count -eq 0) {
    return '无'
  }

  return (($Counts | ForEach-Object { "$($_.model)=$($_.count)" }) -join ', ')
}

function Format-Duration {
  param($Milliseconds)

  if ($null -eq $Milliseconds) {
    return '0 秒'
  }

  $seconds = [Math]::Round(([double]$Milliseconds / 1000), 1)
  return "$seconds 秒"
}

function Test-JsonProperty {
  param(
    $Object,
    [string]$Name
  )

  if ($null -eq $Object) {
    return $false
  }
  return $null -ne $Object.PSObject.Properties[$Name]
}

function Get-JsonPropertyValue {
  param(
    $Object,
    [string]$Name,
    $Default = $null
  )

  if (Test-JsonProperty $Object $Name) {
    return $Object.PSObject.Properties[$Name].Value
  }
  return $Default
}

function Test-BackupVerificationPassed {
  param($Preview)

  $verification = Get-JsonPropertyValue $Preview 'verification' $null
  return [bool](Get-JsonPropertyValue $verification 'verified' $false)
}

function Get-ScopeArgs {
  if ($scopeCheckBox -and $scopeCheckBox.Checked) {
    $cwd = $scopeTextBox.Text.Trim()
    if (-not $cwd) {
      throw '已启用按项目目录过滤，但项目目录为空。'
    }
    return @('--cwd', $cwd)
  }
  return @()
}

function Format-RestorePreviewSummary {
  param($Preview)

  $verification = Get-JsonPropertyValue $Preview 'verification' $null
  $comparison = Get-JsonPropertyValue $Preview 'comparison' $null
  $verified = Test-BackupVerificationPassed $Preview
  $manifestExists = [bool](Get-JsonPropertyValue $verification 'manifest_exists' $false)
  $verificationText = if ($verified) {
    '通过'
  } elseif (-not $manifestExists) {
    '失败（缺少 manifest）'
  } else {
    '失败'
  }
  $ownershipText = if (
    [bool](Get-JsonPropertyValue $comparison 'provider_counts_will_change' $false) -or
    [bool](Get-JsonPropertyValue $comparison 'model_counts_will_change' $false)
  ) {
    '会变化'
  } else {
    '无变化'
  }
  $manifestText = if (Get-JsonPropertyValue $Preview 'manifest' $null) { '有清单' } else { '无清单' }

  return "恢复预览：`r`n" +
    "当前线程数：$(Get-JsonPropertyValue $Preview 'current_thread_count' '未知')`r`n" +
    "备份线程数：$(Get-JsonPropertyValue $Preview 'backup_thread_count' '未知')`r`n" +
    "线程数差异：$(Get-JsonPropertyValue $comparison 'thread_count_delta' '未知')`r`n" +
    "Provider/Model 归属：$ownershipText`r`n" +
    "会话元数据：$(Get-JsonPropertyValue $Preview 'session_meta_items' 0)`r`n" +
    "可恢复会话文件：$(Get-JsonPropertyValue $Preview 'restorable_session_files' 0)`r`n" +
    "缺失文件：$(Get-JsonPropertyValue $Preview 'missing_session_files' 0)`r`n" +
    "目录外路径已跳过：$(Get-JsonPropertyValue $Preview 'skipped_outside_codex_home' 0)`r`n" +
    "清单：$manifestText`r`n" +
    "备份校验：$verificationText"
}

function Format-PreviewSummary {
  param($Preview)

  return "预览结果：范围内 $($Preview.scoped_threads) 条线程。`r`n" +
    "将更新数据库记录：$($Preview.would_update_database_threads)`r`n" +
    "将更新会话文件：$($Preview.would_update_session_files)`r`n" +
    "将补回侧边栏索引：$($Preview.would_add_session_index_entries)`r`n" +
    "目标：$($Preview.current_provider) / $($Preview.current_model)"
}

function Set-Busy {
  param(
    [bool]$Busy,
    [string]$Message = ''
  )

  foreach ($button in @($refreshButton, $previewButton, $syncButton, $backupButton, $restorePreviewButton, $restoreButton, $restoreLatestButton, $manifestButton, $shortcutButton)) {
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
  if ($null -ne $Status.model_movable_threads -and [int]$Status.model_movable_threads -gt 0) {
    $parts += "$($Status.model_movable_threads) 条模型归属待修正"
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
  $args = @('--json', 'status') + (Get-ScopeArgs)
  $status = Invoke-Backend $args
  Apply-State $status
  Append-Log "状态已刷新：$(Get-FriendlyStatus $status)"
}

function Refresh-Doctor {
  try {
    $doctor = Invoke-Backend @('--json', 'doctor')
    $script:DoctorReady = [bool]$doctor.ok
    if ($script:DoctorReady) {
      $doctorLabel.Text = '环境检查: 就绪'
      $doctorLabel.ForeColor = [System.Drawing.Color]::FromArgb(39, 126, 87)
      Append-Log '环境检查通过。'
    } else {
      $failed = @($doctor.checks | Where-Object { $_.required -and -not $_.ok } | ForEach-Object { $_.name })
      $doctorLabel.Text = "环境检查: 需要处理 $($failed -join ', ')"
      $doctorLabel.ForeColor = $script:ColorDanger
      Append-Log "环境检查未通过: $($failed -join ', ')"
    }
  } catch {
    $script:DoctorReady = $false
    $doctorLabel.Text = "环境检查: $($_.Exception.Message)"
    $doctorLabel.ForeColor = $script:ColorDanger
    Append-Log "环境检查失败: $($_.Exception.Message)"
  }
}

function Reset-SyncPreview {
  $script:SyncPreviewReady = $false
}

function Reset-RestorePreview {
  $script:RestorePreviewReady = $false
  $script:RestorePreviewBackup = $null
}

function Apply-State {
  param($Status)

  $script:LatestState = $Status

  $providerLabel.Text = "当前账号/Provider: $($Status.current_provider)"
  $modelLabel.Text = if ($Status.current_model) { "当前模型: $($Status.current_model)    待修正: $($Status.model_movable_threads)" } else { '当前模型: 未读取到' }
  $scopeText = if ($Status.cwd_filter) { "当前范围: $($Status.scoped_threads) / $($Status.total_threads)" } else { "当前范围: 全部 $($Status.total_threads)" }
  $summaryLabel.Text = "$scopeText    会话文件: $($Status.session_file_count)    侧边栏索引: $($Status.indexed_threads)"
  $repairLabel.Text = "待修复: $($Status.movable_threads)    数据库: $($Status.movable_database_threads)    模型: $($Status.model_movable_threads)    会话文件: $($Status.movable_session_threads)    索引: $($Status.missing_session_index_entries)"
  $pathLabel.Text = "数据位置: $($Status.codex_home)"
  $statusLabel.Text = Get-FriendlyStatus $Status
  if ($sideQueueLabel) {
    $sideQueueLabel.Text = [string]$Status.movable_threads
  }
  if ([int]$Status.movable_threads -le 0) {
    $statusLabel.ForeColor = [System.Drawing.Color]::FromArgb(39, 126, 87)
    Set-StatusBadge 'CLEAR' ([System.Drawing.Color]::FromArgb(222, 247, 235)) ([System.Drawing.Color]::FromArgb(39, 126, 87))
  } elseif ([int]$Status.movable_database_threads -gt 0 -or [int]$Status.missing_session_index_entries -gt 0) {
    $statusLabel.ForeColor = $script:ColorPrimary
    Set-StatusBadge 'MISSION' $script:ColorSoftPeach $script:ColorPrimaryDark
  } else {
    $statusLabel.ForeColor = [System.Drawing.Color]::FromArgb(151, 105, 38)
    Set-StatusBadge 'WAITING' ([System.Drawing.Color]::FromArgb(255, 246, 218)) ([System.Drawing.Color]::FromArgb(151, 105, 38))
  }

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
    $manifestBadge = if ($backup.manifest_exists) { ' [清单]' } else { '' }
    $label = "$($backup.modified_at)    $($backup.name)$manifestBadge"
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

function Set-ButtonStyle {
  param(
    [System.Windows.Forms.Button]$Button,
    [string]$Kind = 'Secondary'
  )

  $Button.FlatStyle = 'Flat'
  $Button.FlatAppearance.BorderSize = 1
  $Button.UseVisualStyleBackColor = $false
  $Button.Cursor = [System.Windows.Forms.Cursors]::Hand

  if ($Kind -eq 'Primary') {
    $Button.BackColor = $script:ColorPrimary
    $Button.ForeColor = [System.Drawing.Color]::White
    $Button.FlatAppearance.BorderColor = $script:ColorPrimaryDark
  } elseif ($Kind -eq 'Accent') {
    $Button.BackColor = $script:ColorText
    $Button.ForeColor = [System.Drawing.Color]::White
    $Button.FlatAppearance.BorderColor = $script:ColorText
  } elseif ($Kind -eq 'Danger') {
    $Button.BackColor = [System.Drawing.Color]::White
    $Button.ForeColor = $script:ColorDanger
    $Button.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(226, 194, 194)
  } else {
    $Button.BackColor = [System.Drawing.Color]::White
    $Button.ForeColor = $script:ColorText
    $Button.FlatAppearance.BorderColor = $script:ColorBorder
  }
}

function Set-GroupStyle {
  param([System.Windows.Forms.GroupBox]$Group)
  $Group.BackColor = $script:ColorPanel
  $Group.ForeColor = $script:ColorText
}

function New-SidebarLabel {
  param(
    [string]$Text,
    [int]$Top,
    [bool]$Active = $false
  )

  $label = New-Object System.Windows.Forms.Label
  $label.Text = $Text
  $label.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9, [System.Drawing.FontStyle]::Bold)
  $label.TextAlign = 'MiddleLeft'
  $label.Location = New-Object System.Drawing.Point(18, $Top)
  $label.Size = New-Object System.Drawing.Size(180, 32)
  $label.Padding = New-Object System.Windows.Forms.Padding(12, 0, 0, 0)
  $label.BackColor = if ($Active) { [System.Drawing.Color]::FromArgb(35, 35, 35) } else { $script:ColorAccent }
  $label.ForeColor = if ($Active) { [System.Drawing.Color]::White } else { [System.Drawing.Color]::FromArgb(178, 178, 178) }
  $label.Cursor = [System.Windows.Forms.Cursors]::Hand
  return $label
}

function Set-SidebarActive {
  param([System.Windows.Forms.Label]$ActiveLabel)

  foreach ($label in @($navOverview, $navPreview, $navBackup, $navRestore, $navLog)) {
    if ($label) {
      $label.BackColor = $script:ColorAccent
      $label.ForeColor = [System.Drawing.Color]::FromArgb(178, 178, 178)
    }
  }

  if ($ActiveLabel) {
    $ActiveLabel.BackColor = [System.Drawing.Color]::FromArgb(35, 35, 35)
    $ActiveLabel.ForeColor = [System.Drawing.Color]::White
  }
}

function Invoke-ButtonClick {
  param([System.Windows.Forms.Button]$Button)

  if ($Button -and $Button.Enabled) {
    $Button.PerformClick()
  }
}

function Set-StatusBadge {
  param(
    [string]$Text,
    [System.Drawing.Color]$BackColor,
    [System.Drawing.Color]$ForeColor
  )

  $statusBadgeLabel.Text = $Text
  $statusBadgeLabel.BackColor = $BackColor
  $statusBadgeLabel.ForeColor = $ForeColor
}

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Codex History Sync'
$form.StartPosition = 'CenterScreen'
$form.Size = New-Object System.Drawing.Size(1060, 780)
$form.MinimumSize = New-Object System.Drawing.Size(1060, 780)
$form.BackColor = $script:ColorWindow
$form.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)

$sidebarPanel = New-Object System.Windows.Forms.Panel
$sidebarPanel.BackColor = $script:ColorAccent
$sidebarPanel.Location = New-Object System.Drawing.Point(0, 0)
$sidebarPanel.Size = New-Object System.Drawing.Size(220, 780)
$form.Controls.Add($sidebarPanel)

$brandMark = New-Object System.Windows.Forms.Label
$brandMark.Text = 'CH'
$brandMark.Font = New-Object System.Drawing.Font('Segoe UI', 12, [System.Drawing.FontStyle]::Bold)
$brandMark.TextAlign = 'MiddleCenter'
$brandMark.BackColor = [System.Drawing.Color]::White
$brandMark.ForeColor = $script:ColorText
$brandMark.Location = New-Object System.Drawing.Point(22, 24)
$brandMark.Size = New-Object System.Drawing.Size(42, 42)
$sidebarPanel.Controls.Add($brandMark)

$headerLabel = New-Object System.Windows.Forms.Label
$headerLabel.Text = 'Codex History'
$headerLabel.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 13, [System.Drawing.FontStyle]::Bold)
$headerLabel.ForeColor = [System.Drawing.Color]::White
$headerLabel.AutoSize = $true
$headerLabel.Location = New-Object System.Drawing.Point(74, 24)
$sidebarPanel.Controls.Add($headerLabel)

$introLabel = New-Object System.Windows.Forms.Label
$introLabel.Text = '本地恢复工作台'
$introLabel.ForeColor = [System.Drawing.Color]::FromArgb(174, 174, 174)
$introLabel.AutoSize = $true
$introLabel.Location = New-Object System.Drawing.Point(76, 48)
$sidebarPanel.Controls.Add($introLabel)

$sidebarDivider = New-Object System.Windows.Forms.Panel
$sidebarDivider.BackColor = [System.Drawing.Color]::FromArgb(42, 42, 42)
$sidebarDivider.Location = New-Object System.Drawing.Point(20, 88)
$sidebarDivider.Size = New-Object System.Drawing.Size(180, 1)
$sidebarPanel.Controls.Add($sidebarDivider)

$navOverview = New-SidebarLabel '总览' 112 $true
$navPreview = New-SidebarLabel '预览' 150
$navBackup = New-SidebarLabel '备份' 188
$navRestore = New-SidebarLabel '恢复' 226
$navLog = New-SidebarLabel '日志' 264
$sidebarPanel.Controls.Add($navOverview)
$sidebarPanel.Controls.Add($navPreview)
$sidebarPanel.Controls.Add($navBackup)
$sidebarPanel.Controls.Add($navRestore)
$sidebarPanel.Controls.Add($navLog)

$sideStatusTitle = New-Object System.Windows.Forms.Label
$sideStatusTitle.Text = '当前队列'
$sideStatusTitle.ForeColor = [System.Drawing.Color]::FromArgb(145, 145, 145)
$sideStatusTitle.AutoSize = $true
$sideStatusTitle.Location = New-Object System.Drawing.Point(30, 604)
$sidebarPanel.Controls.Add($sideStatusTitle)

$sideQueueLabel = New-Object System.Windows.Forms.Label
$sideQueueLabel.Text = '读取中'
$sideQueueLabel.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 18, [System.Drawing.FontStyle]::Bold)
$sideQueueLabel.ForeColor = [System.Drawing.Color]::White
$sideQueueLabel.AutoSize = $true
$sideQueueLabel.Location = New-Object System.Drawing.Point(28, 628)
$sidebarPanel.Controls.Add($sideQueueLabel)

$sideHintLabel = New-Object System.Windows.Forms.Label
$sideHintLabel.Text = '左侧入口可直接触发对应操作。写入前会自动备份。'
$sideHintLabel.ForeColor = [System.Drawing.Color]::FromArgb(160, 160, 160)
$sideHintLabel.Location = New-Object System.Drawing.Point(30, 672)
$sideHintLabel.Size = New-Object System.Drawing.Size(164, 44)
$sidebarPanel.Controls.Add($sideHintLabel)

$pageTitleLabel = New-Object System.Windows.Forms.Label
$pageTitleLabel.Text = '同步控制台'
$pageTitleLabel.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 18, [System.Drawing.FontStyle]::Bold)
$pageTitleLabel.ForeColor = $script:ColorText
$pageTitleLabel.AutoSize = $true
$pageTitleLabel.Location = New-Object System.Drawing.Point(244, 24)
$form.Controls.Add($pageTitleLabel)

$pageSubtitleLabel = New-Object System.Windows.Forms.Label
$pageSubtitleLabel.Text = '检查本地 Codex 历史归属，安全迁移 Provider、模型、会话索引。'
$pageSubtitleLabel.ForeColor = $script:ColorMuted
$pageSubtitleLabel.AutoSize = $true
$pageSubtitleLabel.Location = New-Object System.Drawing.Point(246, 58)
$form.Controls.Add($pageSubtitleLabel)

$statusPanel = New-Object System.Windows.Forms.Panel
$statusPanel.BackColor = $script:ColorPanel
$statusPanel.BorderStyle = 'FixedSingle'
$statusPanel.Location = New-Object System.Drawing.Point(244, 92)
$statusPanel.Size = New-Object System.Drawing.Size(784, 170)
$form.Controls.Add($statusPanel)

$statusAccent = New-Object System.Windows.Forms.Panel
$statusAccent.BackColor = $script:ColorPrimary
$statusAccent.Location = New-Object System.Drawing.Point(0, 0)
$statusAccent.Size = New-Object System.Drawing.Size(784, 3)
$statusPanel.Controls.Add($statusAccent)

$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Text = '正在读取状态...'
$statusLabel.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 11, [System.Drawing.FontStyle]::Bold)
$statusLabel.ForeColor = $script:ColorPrimary
$statusLabel.AutoSize = $true
$statusLabel.MaximumSize = New-Object System.Drawing.Size(620, 0)
$statusLabel.Location = New-Object System.Drawing.Point(18, 16)
$statusPanel.Controls.Add($statusLabel)

$statusBadgeLabel = New-Object System.Windows.Forms.Label
$statusBadgeLabel.Text = 'LOADING'
$statusBadgeLabel.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9, [System.Drawing.FontStyle]::Bold)
$statusBadgeLabel.TextAlign = 'MiddleCenter'
$statusBadgeLabel.BackColor = $script:ColorSoftBlue
$statusBadgeLabel.ForeColor = $script:ColorAccentDark
$statusBadgeLabel.Location = New-Object System.Drawing.Point(650, 14)
$statusBadgeLabel.Size = New-Object System.Drawing.Size(110, 26)
$statusPanel.Controls.Add($statusBadgeLabel)

$progressBar = New-Object System.Windows.Forms.ProgressBar
$progressBar.Location = New-Object System.Drawing.Point(20, 50)
$progressBar.Size = New-Object System.Drawing.Size(740, 8)
$progressBar.Visible = $false
$statusPanel.Controls.Add($progressBar)

$providerLabel = New-Object System.Windows.Forms.Label
$providerLabel.Text = '当前账号/Provider:'
$providerLabel.AutoSize = $true
$providerLabel.ForeColor = $script:ColorText
$providerLabel.Location = New-Object System.Drawing.Point(20, 72)
$statusPanel.Controls.Add($providerLabel)

$modelLabel = New-Object System.Windows.Forms.Label
$modelLabel.Text = '当前模型:'
$modelLabel.AutoSize = $true
$modelLabel.ForeColor = $script:ColorText
$modelLabel.Location = New-Object System.Drawing.Point(20, 96)
$statusPanel.Controls.Add($modelLabel)

$summaryLabel = New-Object System.Windows.Forms.Label
$summaryLabel.Text = '历史线程:'
$summaryLabel.AutoSize = $true
$summaryLabel.ForeColor = $script:ColorText
$summaryLabel.Location = New-Object System.Drawing.Point(20, 120)
$statusPanel.Controls.Add($summaryLabel)

$repairLabel = New-Object System.Windows.Forms.Label
$repairLabel.Text = '待修复:'
$repairLabel.AutoSize = $true
$repairLabel.ForeColor = $script:ColorText
$repairLabel.Location = New-Object System.Drawing.Point(20, 144)
$statusPanel.Controls.Add($repairLabel)

$pathLabel = New-Object System.Windows.Forms.Label
$pathLabel.Text = '数据位置:'
$pathLabel.AutoSize = $true
$pathLabel.ForeColor = $script:ColorMuted
$pathLabel.Location = New-Object System.Drawing.Point(360, 72)
$pathLabel.MaximumSize = New-Object System.Drawing.Size(400, 0)
$statusPanel.Controls.Add($pathLabel)

$doctorLabel = New-Object System.Windows.Forms.Label
$doctorLabel.Text = '环境检查: 等待读取'
$doctorLabel.AutoSize = $true
$doctorLabel.ForeColor = $script:ColorMuted
$doctorLabel.Location = New-Object System.Drawing.Point(360, 120)
$doctorLabel.MaximumSize = New-Object System.Drawing.Size(400, 0)
$statusPanel.Controls.Add($doctorLabel)

$scopeBox = New-Object System.Windows.Forms.GroupBox
$scopeBox.Text = '同步范围'
$scopeBox.Location = New-Object System.Drawing.Point(244, 278)
$scopeBox.Size = New-Object System.Drawing.Size(784, 58)
Set-GroupStyle $scopeBox
$form.Controls.Add($scopeBox)

$scopeCheckBox = New-Object System.Windows.Forms.CheckBox
$scopeCheckBox.Text = '只处理这个项目目录'
$scopeCheckBox.AutoSize = $true
$scopeCheckBox.ForeColor = $script:ColorText
$scopeCheckBox.BackColor = $script:ColorPanel
$scopeCheckBox.Location = New-Object System.Drawing.Point(14, 24)
$scopeBox.Controls.Add($scopeCheckBox)

$scopeTextBox = New-Object System.Windows.Forms.TextBox
$scopeTextBox.Text = (Get-Location).Path
$scopeTextBox.BorderStyle = 'FixedSingle'
$scopeTextBox.BackColor = [System.Drawing.Color]::FromArgb(250, 249, 247)
$scopeTextBox.ForeColor = $script:ColorText
$scopeTextBox.Location = New-Object System.Drawing.Point(160, 22)
$scopeTextBox.Size = New-Object System.Drawing.Size(594, 23)
$scopeBox.Controls.Add($scopeTextBox)

$refreshButton = New-Object System.Windows.Forms.Button
$refreshButton.Text = '重新检查'
$refreshButton.Size = New-Object System.Drawing.Size(104, 36)
$refreshButton.Location = New-Object System.Drawing.Point(244, 352)
Set-ButtonStyle $refreshButton
$form.Controls.Add($refreshButton)

$previewButton = New-Object System.Windows.Forms.Button
$previewButton.Text = '预览影响'
$previewButton.Size = New-Object System.Drawing.Size(104, 36)
$previewButton.Location = New-Object System.Drawing.Point(360, 352)
Set-ButtonStyle $previewButton
$form.Controls.Add($previewButton)

$syncButton = New-Object System.Windows.Forms.Button
$syncButton.Text = '立即同步'
$syncButton.Size = New-Object System.Drawing.Size(130, 36)
$syncButton.Location = New-Object System.Drawing.Point(476, 352)
Set-ButtonStyle $syncButton 'Primary'
$form.Controls.Add($syncButton)

$backupButton = New-Object System.Windows.Forms.Button
$backupButton.Text = '创建备份'
$backupButton.Size = New-Object System.Drawing.Size(104, 36)
$backupButton.Location = New-Object System.Drawing.Point(618, 352)
Set-ButtonStyle $backupButton
$form.Controls.Add($backupButton)

$openBackupsButton = New-Object System.Windows.Forms.Button
$openBackupsButton.Text = '打开备份'
$openBackupsButton.Size = New-Object System.Drawing.Size(104, 36)
$openBackupsButton.Location = New-Object System.Drawing.Point(734, 352)
Set-ButtonStyle $openBackupsButton
$form.Controls.Add($openBackupsButton)

$shortcutButton = New-Object System.Windows.Forms.Button
$shortcutButton.Text = '桌面入口'
$shortcutButton.Size = New-Object System.Drawing.Size(104, 36)
$shortcutButton.Location = New-Object System.Drawing.Point(850, 352)
Set-ButtonStyle $shortcutButton
$form.Controls.Add($shortcutButton)

$providersBox = New-Object System.Windows.Forms.GroupBox
$providersBox.Text = '历史归属'
$providersBox.Location = New-Object System.Drawing.Point(244, 410)
$providersBox.Size = New-Object System.Drawing.Size(376, 170)
Set-GroupStyle $providersBox
$form.Controls.Add($providersBox)

$providersView = New-Object System.Windows.Forms.ListView
$providersView.View = 'Details'
$providersView.FullRowSelect = $true
$providersView.GridLines = $false
$providersView.BorderStyle = 'FixedSingle'
$providersView.BackColor = [System.Drawing.Color]::FromArgb(250, 249, 247)
$providersView.ForeColor = $script:ColorText
$providersView.Location = New-Object System.Drawing.Point(12, 26)
$providersView.Size = New-Object System.Drawing.Size(352, 132)
[void]$providersView.Columns.Add('账号/Provider', 130)
[void]$providersView.Columns.Add('数量', 60)
[void]$providersView.Columns.Add('位置', 82)
[void]$providersView.Columns.Add('状态', 56)
$providersBox.Controls.Add($providersView)

$backupsBox = New-Object System.Windows.Forms.GroupBox
$backupsBox.Text = '安全备份'
$backupsBox.Location = New-Object System.Drawing.Point(640, 410)
$backupsBox.Size = New-Object System.Drawing.Size(388, 170)
Set-GroupStyle $backupsBox
$form.Controls.Add($backupsBox)

$backupList = New-Object System.Windows.Forms.ListBox
$backupList.Location = New-Object System.Drawing.Point(12, 24)
$backupList.Size = New-Object System.Drawing.Size(364, 94)
$backupList.BorderStyle = 'FixedSingle'
$backupList.BackColor = [System.Drawing.Color]::FromArgb(250, 249, 247)
$backupList.ForeColor = $script:ColorText
$backupsBox.Controls.Add($backupList)
$backupList.Add_SelectedIndexChanged({
  Reset-RestorePreview
})

$restorePreviewButton = New-Object System.Windows.Forms.Button
$restorePreviewButton.Text = '预览恢复'
$restorePreviewButton.Size = New-Object System.Drawing.Size(84, 32)
$restorePreviewButton.Location = New-Object System.Drawing.Point(12, 126)
Set-ButtonStyle $restorePreviewButton
$backupsBox.Controls.Add($restorePreviewButton)

$restoreButton = New-Object System.Windows.Forms.Button
$restoreButton.Text = '恢复选中'
$restoreButton.Size = New-Object System.Drawing.Size(84, 32)
$restoreButton.Location = New-Object System.Drawing.Point(104, 126)
Set-ButtonStyle $restoreButton 'Danger'
$backupsBox.Controls.Add($restoreButton)

$restoreLatestButton = New-Object System.Windows.Forms.Button
$restoreLatestButton.Text = '恢复最新'
$restoreLatestButton.Size = New-Object System.Drawing.Size(84, 32)
$restoreLatestButton.Location = New-Object System.Drawing.Point(196, 126)
Set-ButtonStyle $restoreLatestButton 'Danger'
$backupsBox.Controls.Add($restoreLatestButton)

$manifestButton = New-Object System.Windows.Forms.Button
$manifestButton.Text = '查看清单'
$manifestButton.Size = New-Object System.Drawing.Size(84, 32)
$manifestButton.Location = New-Object System.Drawing.Point(292, 126)
Set-ButtonStyle $manifestButton
$backupsBox.Controls.Add($manifestButton)

$logBox = New-Object System.Windows.Forms.TextBox
$logBox.Multiline = $true
$logBox.ScrollBars = 'Vertical'
$logBox.ReadOnly = $true
$logBox.Location = New-Object System.Drawing.Point(244, 600)
$logBox.Size = New-Object System.Drawing.Size(784, 120)
$logBox.BorderStyle = 'FixedSingle'
$logBox.BackColor = [System.Drawing.Color]::FromArgb(17, 17, 17)
$logBox.ForeColor = [System.Drawing.Color]::FromArgb(220, 216, 207)
$logBox.Font = New-Object System.Drawing.Font('Consolas', 9)
$form.Controls.Add($logBox)

$navOverview.Add_Click({
  Set-SidebarActive $navOverview
  Invoke-ButtonClick $refreshButton
})

$navPreview.Add_Click({
  Set-SidebarActive $navPreview
  Invoke-ButtonClick $previewButton
})

$navBackup.Add_Click({
  Set-SidebarActive $navBackup
  Invoke-ButtonClick $backupButton
})

$navRestore.Add_Click({
  Set-SidebarActive $navRestore
  Invoke-ButtonClick $restorePreviewButton
})

$navLog.Add_Click({
  Set-SidebarActive $navLog
  $logBox.Focus()
  $logBox.SelectionStart = $logBox.TextLength
  $logBox.ScrollToCaret()
})

$refreshButton.Add_Click({
  try {
    Refresh-State
  } catch {
    [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '刷新失败', 'OK', 'Error') | Out-Null
    Append-Log "刷新失败: $($_.Exception.Message)"
  }
})

$scopeCheckBox.Add_CheckedChanged({
  try {
    Reset-SyncPreview
    Refresh-State
  } catch {
    Append-Log "范围刷新失败: $($_.Exception.Message)"
  }
})

$previewButton.Add_Click({
  try {
    if (-not $script:DoctorReady) {
      Refresh-Doctor
    }
    Set-Busy -Busy $true -Message '正在预览同步影响...'
    $args = @('--json', 'sync', '--dry-run') + (Get-ScopeArgs)
    $preview = Invoke-Backend $args
    $message = Format-PreviewSummary $preview
    Append-Log ($message -replace "`r`n", '；')
    Apply-State $preview.status
    $script:SyncPreviewReady = $true
    [System.Windows.Forms.MessageBox]::Show($message, '同步预览', 'OK', 'Information') | Out-Null
  } catch {
    [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '预览失败', 'OK', 'Error') | Out-Null
    Append-Log "预览失败: $($_.Exception.Message)"
  } finally {
    Set-Busy -Busy $false
  }
})

$syncButton.Add_Click({
  try {
    if (-not $script:DoctorReady) {
      Refresh-Doctor
    }
    if (-not $script:DoctorReady) {
      [System.Windows.Forms.MessageBox]::Show('环境检查未通过，暂不执行写入操作。请先查看日志里的检查结果。', '环境未就绪', 'OK', 'Warning') | Out-Null
      Append-Log '同步已阻止：环境检查未通过。'
      return
    }
    if (-not $script:SyncPreviewReady) {
      [System.Windows.Forms.MessageBox]::Show('请先点击“预览影响”，确认结果后再执行同步。', '需要先预览', 'OK', 'Information') | Out-Null
      Append-Log '同步已阻止：需要先预览影响。'
      return
    }
    if (-not $script:LatestState) {
      Refresh-State
    }
    if ([int]$script:LatestState.movable_threads -le 0) {
      [System.Windows.Forms.MessageBox]::Show('当前已经整理好了，不需要再同步。', '无需同步', 'OK', 'Information') | Out-Null
      Append-Log '同步跳过：当前已经没有需要修复的历史。'
      return
    }
    $scopeLine = if ($scopeCheckBox.Checked) { "`r`n范围: $($scopeTextBox.Text.Trim())" } else { "`r`n范围: 全部历史" }
    $message = "将把旧账号/Provider/模型下的本地历史挂回当前设置：`r`nProvider: $($script:LatestState.current_provider)`r`n模型: $($script:LatestState.current_model)$scopeLine`r`n`r`n本次预计处理：$($script:LatestState.movable_threads) 项`r`n包含数据库记录、会话文件和侧边栏索引。`r`n`r`n工具会先自动备份。Codex 正在运行也可以，但如果它正在写入历史，可能会等待几秒。"
    if (-not (Confirm-Action -Message $message -Title '开始找回历史？')) {
      Append-Log '用户取消了同步。'
      return
    }

    Set-Busy -Busy $true -Message '正在同步历史，Codex 忙的时候会自动等一会儿...'
    $syncArgs = @('--json', 'sync') + (Get-ScopeArgs)
    $result = Invoke-Backend $syncArgs
    Append-Log "同步完成。数据库更新 $($result.updated_rows) 条，会话文件更新 $($result.updated_session_files) 个。"
    if ($result.skipped_session_file_count -gt 0) {
      Append-Log "有 $($result.skipped_session_file_count) 个正在使用的会话文件已跳过，稍后可再次同步。"
      foreach ($item in $result.skipped_session_files) {
        Append-Log "跳过文件: $($item.path)"
      }
    }
    Append-Log "等待数据库空闲: $(Format-Duration $result.lock_wait_ms)，总耗时: $(Format-Duration $result.timing.total_ms)。"
    Append-Log "数据库同步前: $(Format-Counts $result.before_counts)"
    Append-Log "数据库同步后: $(Format-Counts $result.after_counts)"
    Append-Log "模型同步前: $(Format-ModelCounts $result.before_model_counts)"
    Append-Log "模型同步后: $(Format-ModelCounts $result.after_model_counts)"
    Append-Log "会话文件同步前: $(Format-Counts $result.session_before_counts)"
    Append-Log "会话文件同步后: $(Format-Counts $result.session_after_counts)"
    Append-Log "侧边栏索引已重建: $($result.rewritten_index_entries) 条，补回 $($result.missing_session_index_entries_before) 条。"
    Append-Log "备份文件: $($result.backup_path)"
    if ($result.cwd_filter) {
      Append-Log "同步范围: $($result.cwd_filter)"
    }
    Apply-State $result.status
    Reset-SyncPreview
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
    if (-not $script:DoctorReady) {
      Refresh-Doctor
    }
    if (-not $script:DoctorReady) {
      [System.Windows.Forms.MessageBox]::Show('环境检查未通过，暂不创建备份。', '环境未就绪', 'OK', 'Warning') | Out-Null
      Append-Log '备份已阻止：环境检查未通过。'
      return
    }
    Set-Busy -Busy $true -Message '正在创建安全备份...'
    $result = Invoke-Backend @('--json', 'backup')
    Append-Log "手动备份完成: $($result.backup_path)"
    if ($result.manifest_path) {
      Append-Log "备份清单: $($result.manifest_path)"
    }
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

function Get-SelectedBackupPath {
  if ($backupList.SelectedItem -eq $null) {
    throw '请先在右侧选一个备份。'
  }
  $selectedLabel = [string]$backupList.SelectedItem
  $backupPath = $script:BackupMap[$selectedLabel]
  if (-not $backupPath) {
    throw '无法解析选中的备份路径。'
  }
  return $backupPath
}

$restorePreviewButton.Add_Click({
  try {
    $backupPath = Get-SelectedBackupPath
    Reset-RestorePreview
    Set-Busy -Busy $true -Message '正在预览备份恢复...'
    $result = Invoke-Backend @('--json', 'restore', '--dry-run', '--backup', $backupPath)
    $message = Format-RestorePreviewSummary $result
    Append-Log ($message -replace "`r`n", '；')
    $script:RestorePreviewReady = Test-BackupVerificationPassed $result
    $script:RestorePreviewBackup = $backupPath
    if (-not $script:RestorePreviewReady) {
      Append-Log '恢复已阻止：备份校验未通过。请使用新版本重新创建备份后再恢复。'
    }
    $icon = if ($script:RestorePreviewReady) { 'Information' } else { 'Warning' }
    [System.Windows.Forms.MessageBox]::Show($message, '恢复预览', 'OK', $icon) | Out-Null
  } catch {
    [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '预览恢复失败', 'OK', 'Error') | Out-Null
    Append-Log "预览恢复失败: $($_.Exception.Message)"
  } finally {
    Set-Busy -Busy $false
  }
})

$manifestButton.Add_Click({
  try {
    $backupPath = Get-SelectedBackupPath
    $manifestPath = "$backupPath.manifest.json"
    if (-not (Test-Path -LiteralPath $manifestPath)) {
      [System.Windows.Forms.MessageBox]::Show('这个备份没有清单。新版本创建的备份才会带 manifest。', '没有清单', 'OK', 'Information') | Out-Null
      return
    }
    Start-Process notepad.exe $manifestPath
    Append-Log "已打开备份清单: $manifestPath"
  } catch {
    [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '打开清单失败', 'OK', 'Error') | Out-Null
    Append-Log "打开清单失败: $($_.Exception.Message)"
  }
})

$restoreButton.Add_Click({
  try {
    $backupPath = Get-SelectedBackupPath
    if (-not $script:RestorePreviewReady -or $script:RestorePreviewBackup -ne $backupPath) {
      [System.Windows.Forms.MessageBox]::Show('请先预览当前选中的备份，再执行恢复。', '需要先预览', 'OK', 'Information') | Out-Null
      Append-Log '恢复已阻止：需要先预览当前选中的备份。'
      return
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
    Reset-RestorePreview
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
    Set-Busy -Busy $true -Message '正在预览最新备份...'
    $preview = Invoke-Backend @('--json', 'restore', '--dry-run')
    Set-Busy -Busy $false
    $previewMessage = Format-RestorePreviewSummary $preview
    Append-Log ("最新备份$($previewMessage)" -replace "`r`n", '；')
    if (-not (Test-BackupVerificationPassed $preview)) {
      [System.Windows.Forms.MessageBox]::Show('最新备份校验未通过，已阻止恢复。请使用新版本重新创建备份后再恢复。', '备份校验失败', 'OK', 'Warning') | Out-Null
      Append-Log '恢复最新备份已阻止：备份校验未通过。'
      return
    }
    $confirmMessage = "$previewMessage`r`n`r`n将恢复这个备份：`r`n$($preview.restored_from)`r`n`r`n恢复前会再做一次当前状态备份。"
    if (-not (Confirm-Action -Message $confirmMessage -Title '确认恢复最新备份？')) {
      Append-Log '用户取消了恢复最新备份。'
      return
    }

    Set-Busy -Busy $true -Message '正在恢复最新备份...'
    $result = Invoke-Backend @('--json', 'restore', '--backup', $preview.restored_from)
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
  Refresh-Doctor
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
