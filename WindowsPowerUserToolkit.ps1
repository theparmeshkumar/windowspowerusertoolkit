Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

[System.Windows.Forms.Application]::EnableVisualStyles()

$script:AppTitle = "Windows Power User Toolkit"
$script:BackupDir = Join-Path ([Environment]::GetFolderPath("Desktop")) "Windows_Power_User_Backups"
New-Item -ItemType Directory -Path $script:BackupDir -Force | Out-Null

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = [Security.Principal.WindowsPrincipal]::new($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Ensure-Admin {
    if (-not (Test-Admin)) {
        $args = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
        Start-Process powershell.exe -Verb RunAs -ArgumentList $args
        return $false
    }
    return $true
}

function Backup-RegistryKey {
    param([string]$RegistryPath, [string]$Label)
    try {
        $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
        $safe = ($Label -replace '[^a-zA-Z0-9_-]', '_')
        $suffix = [Guid]::NewGuid().ToString("N").Substring(0,8)
        $file = Join-Path $script:BackupDir "${safe}_${stamp}_${suffix}.reg"
        & reg.exe export $RegistryPath $file /y 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $file)) { return $file }
    } catch {}
    return $null
}

function Restart-Explorer {
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 700
    Start-Process explorer.exe
}

function Add-Status {
    param([string]$Text)
    $status.Text = $Text
    $status.Refresh()
}

function Confirm-Action {
    param([string]$Message)
    return ([System.Windows.Forms.MessageBox]::Show(
        $Message, $script:AppTitle,
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    ) -eq [System.Windows.Forms.DialogResult]::Yes)
}

function ConvertTo-RegistryProviderPath {
    param([string]$Path)
    $normalized = $Path -replace '^[^:]+\\Registry::', 'Registry::'
    if ($normalized -notlike "Registry::*") { $normalized = "Registry::$normalized" }
    return $normalized
}

function ConvertTo-RegExePath {
    param([string]$Path)
    return ($Path -replace '^[^:]+\\Registry::', '' -replace '^Registry::', '')
}

function Remove-RegistryKeySafe {
    param([string]$Path)
    if (-not (Ensure-Admin)) { return $false }

    if (Confirm-Action "Remove this context-menu registration?`n`n$Path`n`nA registry backup will be created first.") {
        try {
            $backup = Backup-RegistryKey -RegistryPath (ConvertTo-RegExePath $Path) -Label "Before_Remove"
            if (-not $backup) {
                throw "The registry backup could not be created. The entry was not removed."
            }
            Remove-Item -LiteralPath (ConvertTo-RegistryProviderPath $Path) -Recurse -Force -ErrorAction Stop
            Add-Status "Removed: $Path"
            return $true
        } catch {
            [System.Windows.Forms.MessageBox]::Show("Could not remove:`n$Path`n`n$($_.Exception.Message)","Operation failed",
                [System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        }
    }
    return $false
}

function Set-MenuDelay {
    param([int]$Milliseconds)
    Set-ItemProperty -Path "HKCU:\Control Panel\Desktop" -Name MenuShowDelay -Value ([string]$Milliseconds) -Type String
    [System.Windows.Forms.MessageBox]::Show("MenuShowDelay set to $Milliseconds ms.`nSign out and back in to apply fully.",
        $script:AppTitle,[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
}

function Run-Cmd {
    param([string]$Command, [bool]$Admin=$false)
    if ($Admin -and -not (Ensure-Admin)) { return }
    if ($Admin) {
        Start-Process cmd.exe -Verb RunAs -ArgumentList "/k $Command"
    } else {
        Start-Process cmd.exe -ArgumentList "/k $Command"
    }
}

$script:ScanJob = $null
$script:ScanTimer = $null

function Get-ScanLocations {
    param([string]$Type = "All common locations")
    switch ($Type) {
        "Images" {
            @(
                @{Path="Registry::HKEY_CLASSES_ROOT\SystemFileAssociations\image\shell"; Scope="Image"},
                @{Path="Registry::HKEY_CLASSES_ROOT\SystemFileAssociations\image\shellex\ContextMenuHandlers"; Scope="Image Handler"}
            )
        }
        "Files" {
            @(
                @{Path="Registry::HKEY_CLASSES_ROOT\*\shell"; Scope="All Files"},
                @{Path="Registry::HKEY_CLASSES_ROOT\*\shellex\ContextMenuHandlers"; Scope="All File Handlers"}
            )
        }
        "Folders" {
            @(
                @{Path="Registry::HKEY_CLASSES_ROOT\Directory\shell"; Scope="Folders"},
                @{Path="Registry::HKEY_CLASSES_ROOT\Directory\shellex\ContextMenuHandlers"; Scope="Folder Handlers"}
            )
        }
        "Background" {
            @(
                @{Path="Registry::HKEY_CLASSES_ROOT\Directory\Background\shell"; Scope="Folder Background"},
                @{Path="Registry::HKEY_CLASSES_ROOT\Directory\Background\shellex\ContextMenuHandlers"; Scope="Background Handlers"}
            )
        }
        default {
            @(
                @{Path="Registry::HKEY_CLASSES_ROOT\SystemFileAssociations\image\shell"; Scope="Image"},
                @{Path="Registry::HKEY_CLASSES_ROOT\SystemFileAssociations\image\shellex\ContextMenuHandlers"; Scope="Image Handler"},
                @{Path="Registry::HKEY_CLASSES_ROOT\*\shell"; Scope="All Files"},
                @{Path="Registry::HKEY_CLASSES_ROOT\*\shellex\ContextMenuHandlers"; Scope="All File Handlers"},
                @{Path="Registry::HKEY_CLASSES_ROOT\Directory\shell"; Scope="Folders"},
                @{Path="Registry::HKEY_CLASSES_ROOT\Directory\shellex\ContextMenuHandlers"; Scope="Folder Handlers"},
                @{Path="Registry::HKEY_CLASSES_ROOT\Directory\Background\shell"; Scope="Folder Background"},
                @{Path="Registry::HKEY_CLASSES_ROOT\Directory\Background\shellex\ContextMenuHandlers"; Scope="Background Handlers"}
            )
        }
    }
}

function Start-ContextScan {
    param([string]$Type = "All common locations")

    if ($script:ScanJob -and $script:ScanJob.State -eq "Running") {
        Add-Status "A scan is already running. Please wait..."
        return
    }

    if ($script:ScanJob) {
        Remove-Job $script:ScanJob -Force -ErrorAction SilentlyContinue
        $script:ScanJob = $null
    }
    if ($script:ScanTimer) {
        $script:ScanTimer.Stop()
        $script:ScanTimer.Dispose()
        $script:ScanTimer = $null
    }

    $list.Items.Clear()
    $countLabel.Text = "Scanning..."
    $scanBtn.Enabled = $false
    $removeBtn.Enabled = $false
    Add-Status "Scanning context-menu registrations in the background..."

    $locations = Get-ScanLocations $Type

    $script:ScanJob = Start-Job -ArgumentList (, $locations) -ScriptBlock {
        param($locations)
        $seen = @{}
        foreach ($loc in $locations) {
            try {
                if (-not (Test-Path -LiteralPath $loc.Path)) { continue }
                Get-ChildItem -LiteralPath $loc.Path -ErrorAction SilentlyContinue | ForEach-Object {
                    $path = $_.PSPath
                    if (-not $seen.ContainsKey($path)) {
                        $seen[$path] = $true
                        $name = $_.PSChildName
                        try {
                            $v = (Get-ItemProperty -LiteralPath $path -ErrorAction Stop).'(default)'
                            if ($v) { $name = "$v [$($_.PSChildName)]" }
                        } catch {}
                        [PSCustomObject]@{ Name=$name; Scope=$loc.Scope; Path=$path }
                    }
                }
            } catch {}
        }
    }

    $script:ScanTimer = New-Object System.Windows.Forms.Timer
    $script:ScanTimer.Interval = 250
    $script:ScanTimer.Add_Tick({
        if (-not $script:ScanJob) { return }
        if ($script:ScanJob.State -eq "Completed") {
            try {
                $results = @(Receive-Job $script:ScanJob -ErrorAction SilentlyContinue)
                $list.BeginUpdate()
                $list.Items.Clear()
                foreach ($r in $results) {
                    $item = [System.Windows.Forms.ListViewItem]::new([string]$r.Name)
                    [void]$item.SubItems.Add([string]$r.Scope)
                    [void]$item.SubItems.Add([string]$r.Path)
                    $item.Tag = [string]$r.Path
                    [void]$list.Items.Add($item)
                }
                $list.EndUpdate()
                $countLabel.Text = "$($list.Items.Count) entries found"
                Add-Status "Context-menu scan completed."
            } finally {
                Remove-Job $script:ScanJob -Force -ErrorAction SilentlyContinue
                $script:ScanJob = $null
                $script:ScanTimer.Stop()
                $script:ScanTimer.Dispose()
                $script:ScanTimer = $null
                $scanBtn.Enabled = $true
                $removeBtn.Enabled = $true
            }
        }
        elseif ($script:ScanJob.State -eq "Failed" -or $script:ScanJob.State -eq "Stopped") {
            $countLabel.Text = "Scan failed"
            Add-Status "Scan failed. Try a narrower file type."
            Remove-Job $script:ScanJob -Force -ErrorAction SilentlyContinue
            $script:ScanJob = $null
            $script:ScanTimer.Stop()
            $script:ScanTimer.Dispose()
            $script:ScanTimer = $null
            $scanBtn.Enabled = $true
            $removeBtn.Enabled = $true
        }
    })
    $script:ScanTimer.Start()
}

function Scan-ContextMenus { Start-ContextScan "All common locations" }
function Scan-ByType { param([string]$Type) Start-ContextScan $Type }


function Add-CommonMenuEntry {
    param([string]$Which)
    if (-not (Ensure-Admin)) { return }
    try {
        switch ($Which) {
            "CMD" {
                New-Item "Registry::HKEY_CLASSES_ROOT\Directory\Background\shell\OpenCmdHere\command" -Force | Out-Null
                Set-ItemProperty "Registry::HKEY_CLASSES_ROOT\Directory\Background\shell\OpenCmdHere" -Name "(default)" -Value "Open CMD Here"
                Set-ItemProperty "Registry::HKEY_CLASSES_ROOT\Directory\Background\shell\OpenCmdHere\command" -Name "(default)" -Value 'cmd.exe /s /k pushd "%V"'
            }
            "PowerShell" {
                New-Item "Registry::HKEY_CLASSES_ROOT\Directory\Background\shell\OpenPowerShellHere\command" -Force | Out-Null
                Set-ItemProperty "Registry::HKEY_CLASSES_ROOT\Directory\Background\shell\OpenPowerShellHere" -Name "(default)" -Value "Open PowerShell Here"
                Set-ItemProperty "Registry::HKEY_CLASSES_ROOT\Directory\Background\shell\OpenPowerShellHere\command" -Name "(default)" -Value 'powershell.exe -NoExit -NoProfile -Command "Set-Location -LiteralPath ''%V''"'
            }
            "CopyPath" {
                New-Item "Registry::HKEY_CLASSES_ROOT\*\shell\CopyPath\command" -Force | Out-Null
                Set-ItemProperty "Registry::HKEY_CLASSES_ROOT\*\shell\CopyPath" -Name "(default)" -Value "Copy Path"
                Set-ItemProperty "Registry::HKEY_CLASSES_ROOT\*\shell\CopyPath\command" -Name "(default)" -Value 'powershell.exe -NoProfile -Command "Set-Clipboard -Value ''%1''"'
            }
            "Notepad" {
                New-Item "Registry::HKEY_CLASSES_ROOT\*\shell\OpenWithNotepad\command" -Force | Out-Null
                Set-ItemProperty "Registry::HKEY_CLASSES_ROOT\*\shell\OpenWithNotepad" -Name "(default)" -Value "Open with Notepad"
                Set-ItemProperty "Registry::HKEY_CLASSES_ROOT\*\shell\OpenWithNotepad\command" -Name "(default)" -Value 'notepad.exe "%1"'
            }
        }
        Restart-Explorer
        Add-Status "Added $Which context-menu entry."
    } catch {
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message,"Could not add entry") | Out-Null
    }
}

# Main window
$form = New-Object System.Windows.Forms.Form
$form.Text = $script:AppTitle
$form.Size = [System.Drawing.Size]::new(1000,700)
$form.MinimumSize = [System.Drawing.Size]::new(900,620)
$form.StartPosition = "CenterScreen"
$form.BackColor = [System.Drawing.Color]::FromArgb(245,247,250)

$header = New-Object System.Windows.Forms.Panel
$header.Dock = "Top"
$header.Height = 78
$header.BackColor = [System.Drawing.Color]::FromArgb(31,41,55)
$form.Controls.Add($header)

$title = New-Object System.Windows.Forms.Label
$title.Text = "Windows Power User Toolkit"
$title.ForeColor = [System.Drawing.Color]::White
$title.Font = [System.Drawing.Font]::new("Segoe UI",18,[System.Drawing.FontStyle]::Bold)
$title.Location = [System.Drawing.Point]::new(24,14)
$title.AutoSize = $true
$header.Controls.Add($title)

$subtitle = New-Object System.Windows.Forms.Label
$subtitle.Text = "Maintenance | Performance | Explorer | Context Menu"
$subtitle.ForeColor = [System.Drawing.Color]::FromArgb(210,220,235)
$subtitle.Font = [System.Drawing.Font]::new("Segoe UI",9)
$subtitle.Location = [System.Drawing.Point]::new(26,47)
$subtitle.AutoSize = $true
$header.Controls.Add($subtitle)

$tabs = New-Object System.Windows.Forms.TabControl
$tabs.Dock = "None"
$tabs.Location = [System.Drawing.Point]::new(0,78)
$tabs.Size = [System.Drawing.Size]::new($form.ClientSize.Width, ($form.ClientSize.Height - 104))
$tabs.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor `
               [System.Windows.Forms.AnchorStyles]::Bottom -bor `
               [System.Windows.Forms.AnchorStyles]::Left -bor `
               [System.Windows.Forms.AnchorStyles]::Right
$tabs.Padding = [System.Drawing.Point]::new(15,5)
$form.Controls.Add($tabs)

# Dashboard
$tabDash = New-Object System.Windows.Forms.TabPage
$tabDash.Text = "Dashboard"
$tabDash.AutoScroll = $true
$tabs.TabPages.Add($tabDash)

$cards = @(
    @("Startup", "Manage startup apps", "ms-settings:startupapps"),
    @("Performance", "Diagnostics & reports", "perfmon /rel"),
    @("Explorer", "Restart Explorer", "explorer"),
    @("Visual Effects", "Tune animations", "SystemPropertiesPerformance"),
    @("Storage", "Disk cleanup & health", "dfrgui"),
    @("GPU", "DirectX diagnostics", "dxdiag")
)
$x=24; $y=24
$cardW=285; $cardH=105; $gapX=20; $gapY=18; $col=0
foreach ($c in $cards) {
    $panel=New-Object System.Windows.Forms.Panel
    $panel.Size=[System.Drawing.Size]::new($cardW,$cardH)
    $panel.Location=[System.Drawing.Point]::new($x,$y)
    $panel.BackColor=[System.Drawing.Color]::White
    $panel.BorderStyle="FixedSingle"
    $tabDash.Controls.Add($panel)

    $lab=New-Object System.Windows.Forms.Label
    $lab.Text=$c[0]
    $lab.Font=[System.Drawing.Font]::new("Segoe UI",12,[System.Drawing.FontStyle]::Bold)
    $lab.Location=[System.Drawing.Point]::new(14,12)
    $lab.AutoSize=$true
    $panel.Controls.Add($lab)

    $desc=New-Object System.Windows.Forms.Label
    $desc.Text=$c[1]
    $desc.Location=[System.Drawing.Point]::new(14,40)
    $desc.AutoSize=$true
    $panel.Controls.Add($desc)

    $btn=New-Object System.Windows.Forms.Button
    $btn.Text="Open"
    $btn.Size=[System.Drawing.Size]::new(75,28)
    $btn.Location=[System.Drawing.Point]::new(14,66)
    $command=$c[2]
    $btn.Add_Click({
        if ($command -like "* *" -and $command -notlike "*.msc") { Start-Process $command.Split(" ")[0] -ArgumentList (($command.Split(" "))[1..(($command.Split(" ").Count)-1)] -join " ") }
        else { Start-Process $command }
    }.GetNewClosure())
    $panel.Controls.Add($btn)

    $col++
    if ($col -ge 3) {
        $col=0
        $x=24
        $y += ($cardH + $gapY)
    } else {
        $x += ($cardW + $gapX)
    }
}

$quick = New-Object System.Windows.Forms.GroupBox
$quick.Text="Quick Actions"
$quick.Location=[System.Drawing.Point]::new(24,280)
$quick.Size=[System.Drawing.Size]::new(920,180)
$quick.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$tabDash.Controls.Add($quick)

$dashHint=New-Object System.Windows.Forms.Label
$dashHint.Text="Tip: use Context Menu to scan and remove unwanted Explorer entries safely."
$dashHint.ForeColor=[System.Drawing.Color]::FromArgb(90,100,115)
$dashHint.Location=[System.Drawing.Point]::new(26,478)
$dashHint.AutoSize=$true
$tabDash.Controls.Add($dashHint)

$quickButtons = @(
    @("Restart Explorer","Explorer"),
    @("Context Menu Manager","Context"),
    @("Flush DNS","DNS"),
    @("DISM RestoreHealth","DISM"),
    @("SFC Scan","SFC"),
    @("Check Disk","CHKDSK"),
    @("Malicious Software Removal Tool","MRT")
)
$qx=20;$qy=30
foreach($q in $quickButtons){
    $b=New-Object System.Windows.Forms.Button
    $b.Text=$q[0];$b.Size=[System.Drawing.Size]::new(180,42);$b.Location=[System.Drawing.Point]::new($qx,$qy)
    $action=$q[1]
    $b.Add_Click({
        switch($action){
            "Explorer" { Restart-Explorer; Add-Status "Explorer restarted." }
            "Context" { $tabs.SelectedTab=$tabCM }
            "DNS" { Start-MaintenanceCommand -Command "ipconfig /flushdns" -RequiresAdmin $true }
            "DISM" { Start-MaintenanceCommand -Command "DISM /Online /Cleanup-Image /RestoreHealth" -RequiresAdmin $true }
            "SFC" { Start-MaintenanceCommand -Command "sfc /scannow" -RequiresAdmin $true }
            "CHKDSK" { Start-MaintenanceCommand -Command "chkdsk C: /scan" -RequiresAdmin $true }
            "MRT" { Start-Process -FilePath "$env:SystemRoot\System32\MRT.exe" -Verb RunAs; Add-Status "Microsoft Windows Malicious Software Removal Tool started." }
        }
    }.GetNewClosure())
    $quick.Controls.Add($b)
    $qx += 195
    if($qx -gt 780){$qx=20;$qy+=52}
}


# Temporary Files tab
$tabTemp=New-Object System.Windows.Forms.TabPage
$tabTemp.Text="Temporary Files"
$tabs.TabPages.Add($tabTemp)

$tempHeader=New-Object System.Windows.Forms.Label
$tempHeader.Text="Temporary Files Cleaner"
$tempHeader.Font=[System.Drawing.Font]::new("Segoe UI",14,[System.Drawing.FontStyle]::Bold)
$tempHeader.Location=[System.Drawing.Point]::new(18,16)
$tempHeader.AutoSize=$true
$tabTemp.Controls.Add($tempHeader)

$tempHint=New-Object System.Windows.Forms.Label
$tempHint.Text="These are the 13 individual cleanup categories. Select only what you want to remove. Use the scrollbar or mouse wheel to scroll."
$tempHint.Location=[System.Drawing.Point]::new(20,47)
$tempHint.AutoSize=$true
$tabTemp.Controls.Add($tempHint)

$tempScanBtn=New-Object System.Windows.Forms.Button
$tempScanBtn.Text="Scan Selected Locations"
$tempScanBtn.Size=[System.Drawing.Size]::new(150,32)
$tempScanBtn.Location=[System.Drawing.Point]::new(20,78)
$tempScanBtn.Add_Click({Start-TempScan})
$tabTemp.Controls.Add($tempScanBtn)

$tempCleanBtn=New-Object System.Windows.Forms.Button
$tempCleanBtn.Text="Clean Checked Categories"
$tempCleanBtn.Size=[System.Drawing.Size]::new(145,32)
$tempCleanBtn.Location=[System.Drawing.Point]::new(180,78)
$tempCleanBtn.Add_Click({Start-TempCleanup})
$tabTemp.Controls.Add($tempCleanBtn)

$tempFilesBtn=New-Object System.Windows.Forms.Button
$tempFilesBtn.Text="View Scanned Files"
$tempFilesBtn.Size=[System.Drawing.Size]::new(130,32)
$tempFilesBtn.Location=[System.Drawing.Point]::new(335,78)
$tempFilesBtn.Enabled=$false
$tempFilesBtn.Add_Click({Show-ScannedTempFiles})
$tabTemp.Controls.Add($tempFilesBtn)

$tempStatus=New-Object System.Windows.Forms.Label
$tempStatus.Text="13 cleanup options ready."
$tempStatus.Location=[System.Drawing.Point]::new(480,84)
$tempStatus.AutoSize=$true
$tabTemp.Controls.Add($tempStatus)

$tempGrid=New-Object System.Windows.Forms.Panel
$tempGrid.Location=[System.Drawing.Point]::new(15,120)
$tempGrid.Size=[System.Drawing.Size]::new(910,430)
$tempGrid.Anchor="Top,Bottom,Left,Right"
$tempGrid.AutoScroll=$false
$tempGrid.BorderStyle="FixedSingle"
$tempGrid.TabStop=$true
$tabTemp.Controls.Add($tempGrid)

# Explicit scrollbar. This is deliberately separate from AutoScroll so it is
# always visible and works consistently on normal, non-maximized windows.
$tempVScroll=New-Object System.Windows.Forms.VScrollBar
$tempVScroll.Minimum=0
$tempVScroll.SmallChange=40
$tempVScroll.LargeChange=300
$tempVScroll.Location=[System.Drawing.Point]::new(928,120)
$tempVScroll.Size=[System.Drawing.Size]::new(18,430)
$tempVScroll.Anchor="Top,Bottom,Right"
$tabTemp.Controls.Add($tempVScroll)
$tempVScroll.BringToFront()

$script:TempContentHeight=0
$script:TempBaseY=@{}

function Update-TempScrollBar {
    if(-not $tempGrid -or -not $tempVScroll){return}

    $viewport=[int]$tempGrid.ClientSize.Height
    $content=[int]$script:TempContentHeight
    if($content -lt $viewport){$content=$viewport}

    $tempVScroll.Minimum=0
    $tempVScroll.LargeChange=[Math]::Max(1,$viewport)
    $tempVScroll.SmallChange=40
    $tempVScroll.Maximum=[Math]::Max($viewport,$content)

    $maxValue=[Math]::Max(0,$tempVScroll.Maximum-$tempVScroll.LargeChange+1)
    if($tempVScroll.Value -gt $maxValue){$tempVScroll.Value=$maxValue}
}

function Set-TempScrollPosition {
    param([int]$Value)

    if(-not $tempGrid){return}

    $viewport=[int]$tempGrid.ClientSize.Height
    $content=[int]$script:TempContentHeight
    $maxValue=[Math]::Max(0,$content-$viewport)
    $offset=[Math]::Min([Math]::Max(0,$Value),$maxValue)

    foreach($control in @($tempGrid.Controls)){
        if($control.AccessibleName -and $control.AccessibleName -ne "HEADER"){
            $baseY=0
            if([int]::TryParse($control.AccessibleName,[ref]$baseY)){
                $p=$control.Location
                $control.Location=[System.Drawing.Point]::new($p.X,($baseY-$offset))
            }
        }
    }
}

$tempVScroll.Add_ValueChanged({
    Set-TempScrollPosition -Value $tempVScroll.Value
}.GetNewClosure())

# Mouse wheel over the list, including over child controls.
function Scroll-TempByWheel {
    param([int]$Delta)
    if(-not $tempVScroll){return}
    $step=45
    $newValue=$tempVScroll.Value-([Math]::Sign($Delta)*$step)
    $maxValue=[Math]::Max(0,$tempVScroll.Maximum-$tempVScroll.LargeChange+1)
    if($newValue -lt 0){$newValue=0}
    if($newValue -gt $maxValue){$newValue=$maxValue}
    $tempVScroll.Value=$newValue
}

$wheelHandler={
    param($sender,$e)
    Scroll-TempByWheel -Delta $e.Delta
}.GetNewClosure()

$tempGrid.Add_MouseWheel($wheelHandler)

$tabTemp.Add_Resize({
    $x=[Math]::Max(0,$tabTemp.ClientSize.Width-60)
    $tempVScroll.Location=[System.Drawing.Point]::new($x,120)
    $tempVScroll.Height=[Math]::Max(100,$tabTemp.ClientSize.Height-165)
    $tempGrid.Width=[Math]::Max(400,$tabTemp.ClientSize.Width-75)
    $tempGrid.Height=[Math]::Max(220,$tabTemp.ClientSize.Height-165)
    Update-TempScrollBar
}.GetNewClosure())

# Header row
$headers=@(
    @("Cleanup category",8,220),
    @("Size",235,100),
    @("Access",345,65),
    @("Category",415,120),
    @("Location",545,390)
)
foreach($h in $headers){
    $hl=New-Object System.Windows.Forms.Label
    $hl.Text=$h[0];$hl.Location=[System.Drawing.Point]::new($h[1],5);$hl.Size=[System.Drawing.Size]::new($h[2],24)
    $hl.Font=[System.Drawing.Font]::new("Segoe UI",9,[System.Drawing.FontStyle]::Bold)
    $tempGrid.Controls.Add($hl)
}

$tempNote=New-Object System.Windows.Forms.Label
$tempNote.Text="Prefetch is Optional. Use View Scanned Files after a scan to inspect individual files and choose exactly which files to delete. Locked/in-use files are skipped."
$tempNote.Location=[System.Drawing.Point]::new(20,560)
$tempNote.MaximumSize=[System.Drawing.Size]::new(920,0)
$tempNote.AutoSize=$true
$tempNote.Anchor="Bottom,Left,Right"
$tabTemp.Controls.Add($tempNote)


# Context menu tab
$tabCM=New-Object System.Windows.Forms.TabPage
$tabCM.Text="Context Menu"
$tabs.TabPages.Add($tabCM)

$top=New-Object System.Windows.Forms.Panel
$top.Dock="Top";$top.Height=115
$tabCM.Controls.Add($top)

$lbl=New-Object System.Windows.Forms.Label
$lbl.Text="Context Menu Cleaner"
$lbl.Font=[System.Drawing.Font]::new("Segoe UI",14,[System.Drawing.FontStyle]::Bold)
$lbl.Location=[System.Drawing.Point]::new(15,12);$lbl.AutoSize=$true
$top.Controls.Add($lbl)

$hint=New-Object System.Windows.Forms.Label
$hint.Text="Scan by file type, select unwanted entries, then remove them. A registry backup is created first."
$hint.Location=[System.Drawing.Point]::new(17,42);$hint.AutoSize=$true
$top.Controls.Add($hint)

$typeCombo=New-Object System.Windows.Forms.ComboBox
$typeCombo.DropDownStyle="DropDownList"
[void]$typeCombo.Items.AddRange(@("All common locations","Images","Files","Folders","Background"))
$typeCombo.SelectedIndex=0
$typeCombo.Location=[System.Drawing.Point]::new(17,70)
$typeCombo.Width=190
$top.Controls.Add($typeCombo)

$scanBtn=New-Object System.Windows.Forms.Button
$scanBtn.Text="Scan"
$scanBtn.Location=[System.Drawing.Point]::new(220,69)
$scanBtn.Size=[System.Drawing.Size]::new(80,26)
$scanBtn.Add_Click({
    $selectedType = [string]$typeCombo.SelectedItem
    if($selectedType -eq "All common locations"){Start-ContextScan "All common locations"}
    else {Start-ContextScan $selectedType}
})
$top.Controls.Add($scanBtn)

$removeBtn=New-Object System.Windows.Forms.Button
$removeBtn.Text="Remove Selected"
$removeBtn.Location=[System.Drawing.Point]::new(310,69)
$removeBtn.Size=[System.Drawing.Size]::new(120,26)
$removeBtn.Add_Click({
    if($list.SelectedItems.Count -eq 0){
        [System.Windows.Forms.MessageBox]::Show("Select one or more entries first.","Context Menu") | Out-Null
        return
    }
    if(-not (Ensure-Admin)){return}
    $requestedPaths=@($list.SelectedItems | ForEach-Object { [string]$_.Tag } | Where-Object { $_ })
    if($requestedPaths.Count -eq 0){return}
    if(-not (Confirm-Action "Remove $($requestedPaths.Count) selected context-menu registration(s)?`n`nA separate registry backup will be created for each entry before removal.")){return}

    $paths=@()
    $backupFailures=@()
    foreach($path in $requestedPaths){
        $backup=Backup-RegistryKey -RegistryPath (ConvertTo-RegExePath $path) -Label "ContextMenu_Before_Remove"
        if($backup){$paths+=,$path}else{$backupFailures+=,$path}
    }
    if($backupFailures.Count -gt 0){
        [System.Windows.Forms.MessageBox]::Show(
            "$($backupFailures.Count) entry backup(s) could not be created and will not be removed:`n`n$($backupFailures -join "`n")",
            "Some entries were skipped",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
    }
    if($paths.Count -eq 0){
        Add-Status "No entries were removed because their registry backups could not be created."
        return
    }

    $removeBtn.Enabled=$false
    $scanBtn.Enabled=$false
    Add-Status "Removing selected entries in the background..."

    $job=Start-Job -ArgumentList (, $paths) -ScriptBlock {
        param($paths)
        $removed=0
        $failures=@()
        foreach($path in $paths){
            try{
                $path=$path -replace '^[^:]+\\Registry::','Registry::'
                if($path -notlike "Registry::*"){$path="Registry::$path"}
                if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop;$removed++}
                else{$failures+=,[PSCustomObject]@{Path=$path;Error="The registry entry no longer exists."}}
            }catch{
                $failures+=,[PSCustomObject]@{Path=$path;Error=$_.Exception.Message}
            }
        }
        [PSCustomObject]@{Removed=$removed;Total=$paths.Count;Failures=$failures}
    }
    $timer=New-Object System.Windows.Forms.Timer
    $timer.Interval=250
    $timer.Add_Tick({
        if($job.State -eq "Completed"){
            $result=@(Receive-Job $job -ErrorAction SilentlyContinue | Select-Object -Last 1)
            Remove-Job $job -Force -ErrorAction SilentlyContinue
            $timer.Stop();$timer.Dispose()
            Restart-Explorer
            $removeBtn.Enabled=$true;$scanBtn.Enabled=$true
            if($result.Count -gt 0){
                $summary=$result[0]
                Add-Status "Context-menu removal finished: $($summary.Removed) removed, $($summary.Failures.Count) failed. Explorer refreshed."
                if($summary.Failures.Count -gt 0){
                    $failureText=($summary.Failures | ForEach-Object {"$($_.Path)`n$($_.Error)"}) -join "`n`n"
                    [System.Windows.Forms.MessageBox]::Show(
                        "Removed $($summary.Removed) of $($summary.Total) selected entries. The following entries could not be removed:`n`n$failureText",
                        "Some entries could not be removed",
                        [System.Windows.Forms.MessageBoxButtons]::OK,
                        [System.Windows.Forms.MessageBoxIcon]::Warning
                    ) | Out-Null
                }
            }else{
                Add-Status "Context-menu removal completed, but the worker returned no result. Check the registry entries."
            }
            Start-ContextScan ([string]$typeCombo.SelectedItem)
        }elseif($job.State -eq "Failed" -or $job.State -eq "Stopped"){
            Remove-Job $job -Force -ErrorAction SilentlyContinue
            $timer.Stop();$timer.Dispose()
            $removeBtn.Enabled=$true;$scanBtn.Enabled=$true
            Add-Status "Context-menu removal failed or was stopped."
        }
    }.GetNewClosure())
    $timer.Start()
})
$top.Controls.Add($removeBtn)

$backupBtn=New-Object System.Windows.Forms.Button
$backupBtn.Text="Backup"
$backupBtn.Location=[System.Drawing.Point]::new(440,69)
$backupBtn.Size=[System.Drawing.Size]::new(80,26)
$backupBtn.Add_Click({
    if(-not (Ensure-Admin)){return}
    $files=@()
    foreach($p in @(
        "HKEY_CLASSES_ROOT\*\shell",
        "HKEY_CLASSES_ROOT\*\shellex\ContextMenuHandlers",
        "HKEY_CLASSES_ROOT\Directory\shell",
        "HKEY_CLASSES_ROOT\Directory\shellex\ContextMenuHandlers",
        "HKEY_CLASSES_ROOT\SystemFileAssociations\image\shell",
        "HKEY_CLASSES_ROOT\SystemFileAssociations\image\shellex\ContextMenuHandlers"
    )){
        $f=Backup-RegistryKey $p "ContextMenu_Backup"
        if($f){$files+=$f}
    }
    if($files.Count -gt 0){
        [System.Windows.Forms.MessageBox]::Show("$($files.Count) registry backup(s) created.`n`nSaved to:`n$script:BackupDir","Registry Backup") | Out-Null
    }else{
        [System.Windows.Forms.MessageBox]::Show("No registry backups could be created. Check permissions and the backup folder:`n`n$script:BackupDir","Registry Backup",
            [System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    }
})
$top.Controls.Add($backupBtn)

$countLabel=New-Object System.Windows.Forms.Label
$countLabel.Text="0 entries"
$countLabel.Location=[System.Drawing.Point]::new(535,74)
$countLabel.AutoSize=$true
$top.Controls.Add($countLabel)

$list=New-Object System.Windows.Forms.ListView
$list.Dock="Fill"
$list.View="Details"
$list.FullRowSelect=$true
$list.MultiSelect=$true
$list.GridLines=$true
$list.CheckBoxes=$true
[void]$list.Columns.Add("Menu / Registry Entry",330)
[void]$list.Columns.Add("Scope",130)
[void]$list.Columns.Add("Registry Location",560)
$tabCM.Controls.Add($list)

# Common entries tab
$tabCommon=New-Object System.Windows.Forms.TabPage
$tabCommon.Text="Quick Add / Remove"
$tabs.TabPages.Add($tabCommon)

$commonInfo=New-Object System.Windows.Forms.Label
$commonInfo.Text="Convenience entries. Use the Context Menu tab for discovering and removing third-party entries."
$commonInfo.Location=[System.Drawing.Point]::new(20,20)
$commonInfo.AutoSize=$true
$tabCommon.Controls.Add($commonInfo)

$commonItems=@(
    @("Open CMD Here","CMD"),
    @("Open PowerShell Here","PowerShell"),
    @("Copy Path","CopyPath"),
    @("Open with Notepad","Notepad")
)
$cy=65
foreach($ci in $commonItems){
    $add=New-Object System.Windows.Forms.Button
    $add.Text="Add  $($ci[0])";$add.Size=[System.Drawing.Size]::new(220,38);$add.Location=[System.Drawing.Point]::new(25,$cy)
    $which=$ci[1]
    $add.Add_Click({Add-CommonMenuEntry $which}.GetNewClosure())
    $tabCommon.Controls.Add($add)

    $remove=New-Object System.Windows.Forms.Button
    $remove.Text="Remove";$remove.Size=[System.Drawing.Size]::new(100,38);$remove.Location=[System.Drawing.Point]::new(255,$cy)
    $path = switch($which){
        "CMD" {"HKEY_CLASSES_ROOT\Directory\Background\shell\OpenCmdHere"}
        "PowerShell" {"HKEY_CLASSES_ROOT\Directory\Background\shell\OpenPowerShellHere"}
        "CopyPath" {"HKEY_CLASSES_ROOT\*\shell\CopyPath"}
        "Notepad" {"HKEY_CLASSES_ROOT\*\shell\OpenWithNotepad"}
    }
    $remove.Add_Click({if(Test-Path (ConvertTo-RegistryProviderPath $path)){Remove-RegistryKeySafe $path}else{[System.Windows.Forms.MessageBox]::Show("That entry is not installed.")|Out-Null}}.GetNewClosure())
    $tabCommon.Controls.Add($remove)
    $cy+=55
}


# -----------------------------------------------------------------
# Temporary Files Cleaner
# -----------------------------------------------------------------

$script:TempScanJob = $null
$script:TempScanTimer = $null
$script:TempCleanJob = $null
$script:TempCleanTimer = $null
$script:TempFileResults = @()

function Get-TempTargets {
    @(
        @{Id="UserTemp"; Name="User TEMP"; Path=$env:TEMP; Admin=$false; Safe=$true; Description="Current user's temporary files"},
        @{Id="WindowsTemp"; Name="Windows TEMP"; Path="$env:WINDIR\Temp"; Admin=$true; Safe=$true; Description="Windows system temporary files"},
        @{Id="Prefetch"; Name="Prefetch"; Path="$env:WINDIR\Prefetch"; Admin=$true; Safe=$false; Description="Optional Windows prefetch cache"},
        @{Id="ThumbCache"; Name="Thumbnail Cache"; Path="$env:LOCALAPPDATA\Microsoft\Windows\Explorer"; Admin=$false; Safe=$true; Description="Explorer thumbnail cache"},
        @{Id="D3DCache"; Name="DirectX Shader Cache"; Path="$env:LOCALAPPDATA\D3DSCache"; Admin=$false; Safe=$true; Description="DirectX shader cache"},
        @{Id="NvidiaCache"; Name="NVIDIA Shader Cache"; Path="$env:LOCALAPPDATA\NVIDIA\DXCache"; Admin=$false; Safe=$true; Description="NVIDIA DirectX shader cache"},
        @{Id="NvidiaGLCache"; Name="NVIDIA GL Cache"; Path="$env:LOCALAPPDATA\NVIDIA\GLCache"; Admin=$false; Safe=$true; Description="NVIDIA OpenGL cache"},
        @{Id="AMDCache"; Name="AMD Shader Cache"; Path="$env:LOCALAPPDATA\AMD\DxCache"; Admin=$false; Safe=$true; Description="AMD DirectX shader cache"},
        @{Id="AMDGLCache"; Name="AMD GL Cache"; Path="$env:LOCALAPPDATA\AMD\GLCache"; Admin=$false; Safe=$true; Description="AMD OpenGL cache"},
        @{Id="DeliveryOptimization"; Name="Delivery Optimization Cache"; Path="$env:WINDIR\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache"; Admin=$true; Safe=$true; Description="Windows Update delivery cache"},
        @{Id="WER"; Name="Windows Error Reports"; Path="$env:ProgramData\Microsoft\Windows\WER"; Admin=$true; Safe=$true; Description="Windows Error Reporting files"},
        @{Id="CrashDumps"; Name="Windows Crash Dumps"; Path="$env:LOCALAPPDATA\CrashDumps"; Admin=$false; Safe=$true; Description="User crash dump files"},
        @{Id="FontCache"; Name="Windows Font Cache"; Path="$env:LOCALAPPDATA\Microsoft\Windows\FontCache"; Admin=$false; Safe=$true; Description="Windows font cache"}
    )
}

function Format-Bytes {
    param([Int64]$Bytes)
    if ($Bytes -lt 1KB) { return "$Bytes B" }
    if ($Bytes -lt 1MB) { return ("{0:N1} KB" -f ($Bytes / 1KB)) }
    if ($Bytes -lt 1GB) { return ("{0:N1} MB" -f ($Bytes / 1MB)) }
    return ("{0:N2} GB" -f ($Bytes / 1GB))
}

function Get-TempSize {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return [Int64]0 }
    try {
        $m = Get-ChildItem -LiteralPath $Path -Force -File -Recurse -ErrorAction SilentlyContinue |
             Measure-Object -Property Length -Sum
        if ($m.Sum) { return [Int64]$m.Sum }
    } catch {}
    return [Int64]0
}

function Add-TempGridHeaders {
    $headers=@(
        @("Cleanup category",8,220),
        @("Size",235,100),
        @("Access",345,65),
        @("Category",415,120),
        @("Location",545,390)
    )
    foreach($h in $headers){
        $hl=[System.Windows.Forms.Label]::new()
        $hl.Text=$h[0]
        $hl.Location=[System.Drawing.Point]::new([int]$h[1],5)
        $hl.Size=[System.Drawing.Size]::new([int]$h[2],24)
        $hl.Font=[System.Drawing.Font]::new("Segoe UI",9,[System.Drawing.FontStyle]::Bold)
        $hl.AccessibleName="HEADER"
        $tempGrid.Controls.Add($hl)
        $hl.Add_MouseWheel($wheelHandler)
    }
}

function Populate-TempRows {
    $tempGrid.SuspendLayout()
    $tempGrid.Controls.Clear()
    Add-TempGridHeaders
    foreach($existing in @($tempGrid.Controls)){
        $existing.Add_MouseWheel($wheelHandler)
    }

    $targets = @(Get-TempTargets)
    $rowY = 32

    foreach ($t in $targets) {
        $cb = New-Object System.Windows.Forms.CheckBox
        $cb.Text = [string]$t.Name
        $cb.Tag = $t
        $cb.Checked = $true
        $cb.Font = [System.Drawing.Font]::new("Segoe UI",9,[System.Drawing.FontStyle]::Bold)
        $cb.Location = [System.Drawing.Point]::new(8,$rowY+6)
        $cb.Size = [System.Drawing.Size]::new(220,28)
        $cb.AccessibleName=[string]($rowY+6)
        $tempGrid.Controls.Add($cb)
        $cb.Add_MouseWheel($wheelHandler)

        $size = New-Object System.Windows.Forms.Label
        $size.Text = "Not scanned"
        $size.Location = [System.Drawing.Point]::new(235,$rowY+6)
        $size.Size = [System.Drawing.Size]::new(100,25)
        $size.Tag = $t.Id
        $size.TextAlign = "MiddleLeft"
        $size.AccessibleName=[string]($rowY+6)
        $tempGrid.Controls.Add($size)
        $size.Add_MouseWheel($wheelHandler)

        $access = New-Object System.Windows.Forms.Label
        $access.Text = if ($t.Admin) { "Admin" } else { "User" }
        $access.Location = [System.Drawing.Point]::new(345,$rowY+6)
        $access.Size = [System.Drawing.Size]::new(65,25)
        $access.AccessibleName=[string]($rowY+6)
        $tempGrid.Controls.Add($access)
        $access.Add_MouseWheel($wheelHandler)

        $category = New-Object System.Windows.Forms.Label
        $category.Text = if ($t.Safe) { "Routine cleanup" } else { "OPTIONAL" }
        $category.Location = [System.Drawing.Point]::new(415,$rowY+6)
        $category.Size = [System.Drawing.Size]::new(120,25)
        if (-not $t.Safe) {
            $category.ForeColor = [System.Drawing.Color]::DarkOrange
            $category.Font = [System.Drawing.Font]::new("Segoe UI",9,[System.Drawing.FontStyle]::Bold)
        }
        $category.AccessibleName=[string]($rowY+6)
        $tempGrid.Controls.Add($category)
        $category.Add_MouseWheel($wheelHandler)

        $pathLabel = New-Object System.Windows.Forms.Label
        $pathLabel.Text = [string]$t.Path
        $pathLabel.Location = [System.Drawing.Point]::new(545,$rowY+6)
        $pathLabel.Size = [System.Drawing.Size]::new(390,25)
        $pathLabel.AutoEllipsis = $true
        $pathLabel.TextAlign = "MiddleLeft"
        $pathLabel.AccessibleName=[string]($rowY+6)
        $tempGrid.Controls.Add($pathLabel)
        $pathLabel.Add_MouseWheel($wheelHandler)

        $rowY += 40
    }

    $script:TempContentHeight=($rowY+10)
    Update-TempScrollBar
    $tempVScroll.Value=0
    Set-TempScrollPosition -Value 0
    $tempGrid.ResumeLayout()
    $tempStatus.Text = "13 cleanup options ready. Use the scrollbar or mouse wheel to select/unselect them."
}

function Start-TempScan {
    if ($script:TempScanJob -and $script:TempScanJob.State -eq "Running") {
        Add-Status "Temporary-file scan is already running."
        return
    }

    $selectedTargets=@(
        $tempGrid.Controls |
        Where-Object {$_ -is [System.Windows.Forms.CheckBox] -and $_.Checked} |
        ForEach-Object {$_.Tag}
    )

    if($selectedTargets.Count -eq 0){
        [System.Windows.Forms.MessageBox]::Show(
            "Select at least one temporary-file category before scanning.",
            "Temporary Files"
        ) | Out-Null
        return
    }

    if ($script:TempScanJob) {
        Remove-Job $script:TempScanJob -Force -ErrorAction SilentlyContinue
        $script:TempScanJob = $null
    }

    $script:TempFileResults=@()
    $tempStatus.Text = "Scanning files in $($selectedTargets.Count) selected locations..."
    $tempScanBtn.Enabled = $false
    $tempCleanBtn.Enabled = $false
    $tempFilesBtn.Enabled = $false
    Add-Status "Scanning individual temporary files in the background..."

    $targets = @($selectedTargets)

    $script:TempScanJob = Start-Job -ArgumentList (, $targets) -ScriptBlock {
        param($targets)

        foreach ($t in $targets) {
            $summaryBytes=[Int64]0
            $fileCount=0

            if (Test-Path -LiteralPath $t.Path) {
                try {
                    Get-ChildItem -LiteralPath $t.Path -Force -File -Recurse -ErrorAction SilentlyContinue |
                    ForEach-Object {
                        $fileCount++
                        $len=[Int64]$_.Length
                        $summaryBytes += $len

                        [PSCustomObject]@{
                            RecordType="File"
                            Id=[string]$t.Id
                            Category=[string]$t.Name
                            Path=[string]$_.FullName
                            Name=[string]$_.Name
                            Size=$len
                            LastWriteTime=$_.LastWriteTime
                            Admin=[bool]$t.Admin
                        }
                    }
                } catch {}
            }

            [PSCustomObject]@{
                RecordType="Summary"
                Id=[string]$t.Id
                Category=[string]$t.Name
                Path=[string]$t.Path
                Size=$summaryBytes
                FileCount=$fileCount
                Admin=[bool]$t.Admin
            }
        }
    }

    $script:TempScanTimer=New-Object System.Windows.Forms.Timer
    $script:TempScanTimer.Interval=500
    $script:TempScanTimer.Add_Tick({
        if(-not $script:TempScanJob){return}

        if($script:TempScanJob.State -eq "Completed"){
            try{
                $allResults=@(Receive-Job $script:TempScanJob -ErrorAction SilentlyContinue)
                $script:TempFileResults=@(
                    $allResults | Where-Object {$_.RecordType -eq "File"}
                )
                $summaries=@(
                    $allResults | Where-Object {$_.RecordType -eq "Summary"}
                )

                $map=@{}
                foreach($r in $summaries){
                    $map[[string]$r.Id]=[Int64]$r.Size
                }

                foreach($control in @($tempGrid.Controls)){
                    if($control -is [System.Windows.Forms.Label] -and $control.Tag){
                        $id=[string]$control.Tag
                        if($map.ContainsKey($id)){
                            $control.Text=Format-Bytes $map[$id]
                        }
                    }
                }

                $totalBytes=($summaries | Measure-Object -Property Size -Sum).Sum
                $fileCount=$script:TempFileResults.Count
                $tempStatus.Text="Scan complete — $fileCount files, approximately $(Format-Bytes ([Int64]$totalBytes))."
                $tempFilesBtn.Enabled=($fileCount -gt 0)
                Add-Status "Temporary-file scan completed: $fileCount files found."
            }
            finally{
                Remove-Job $script:TempScanJob -Force -ErrorAction SilentlyContinue
                $script:TempScanJob=$null
                $script:TempScanTimer.Stop()
                $script:TempScanTimer.Dispose()
                $script:TempScanTimer=$null
                $tempScanBtn.Enabled=$true
                $tempCleanBtn.Enabled=$true
            }
        }
        elseif($script:TempScanJob.State -eq "Failed" -or $script:TempScanJob.State -eq "Stopped"){
            $tempStatus.Text="Scan failed. The category options are still available."
            Add-Status "Temporary-file scan failed."
            Remove-Job $script:TempScanJob -Force -ErrorAction SilentlyContinue
            $script:TempScanJob=$null
            $script:TempScanTimer.Stop()
            $script:TempScanTimer.Dispose()
            $script:TempScanTimer=$null
            $tempScanBtn.Enabled=$true
            $tempCleanBtn.Enabled=$true
            $tempFilesBtn.Enabled=$false
        }
    })
    $script:TempScanTimer.Start()
}

function Show-ScannedTempFiles {
    if(-not $script:TempFileResults -or $script:TempFileResults.Count -eq 0){
        [System.Windows.Forms.MessageBox]::Show(
            "No individual files have been scanned yet. Select categories and click Scan Selected Locations.",
            "Scanned Temporary Files"
        ) | Out-Null
        return
    }

    $fileForm=New-Object System.Windows.Forms.Form
    $fileForm.Text="Scanned Temporary Files"
    $fileForm.StartPosition="CenterParent"
    $fileForm.Size=[System.Drawing.Size]::new(1180,720)
    $fileForm.MinimumSize=[System.Drawing.Size]::new(900,500)

    $info=New-Object System.Windows.Forms.Label
    $info.Text="$($script:TempFileResults.Count) files scanned. Select individual files you want to delete. Nothing is selected by default."
    $info.Location=[System.Drawing.Point]::new(15,12)
    $info.AutoSize=$true
    $fileForm.Controls.Add($info)

    $fileList=New-Object System.Windows.Forms.ListView
    $fileList.Location=[System.Drawing.Point]::new(15,42)
    $fileList.Size=[System.Drawing.Size]::new(1135,570)
    $fileList.Anchor="Top,Bottom,Left,Right"
    $fileList.View="Details"
    $fileList.FullRowSelect=$true
    $fileList.GridLines=$true
    $fileList.CheckBoxes=$true
    $fileList.HideSelection=$false
    [void]$fileList.Columns.Add("File",220)
    [void]$fileList.Columns.Add("Size",90)
    [void]$fileList.Columns.Add("Category",175)
    [void]$fileList.Columns.Add("Modified",145)
    [void]$fileList.Columns.Add("Path",480)
    $fileForm.Controls.Add($fileList)

    $selectAll=New-Object System.Windows.Forms.Button
    $selectAll.Text="Select All"
    $selectAll.Size=[System.Drawing.Size]::new(90,30)
    $selectAll.Location=[System.Drawing.Point]::new(15,625)
    $selectAll.Anchor="Bottom,Left"
    $selectAll.Add_Click({
        foreach($item in @($fileList.Items)){$item.Checked=$true}
    })
    $fileForm.Controls.Add($selectAll)

    $selectNone=New-Object System.Windows.Forms.Button
    $selectNone.Text="Select None"
    $selectNone.Size=[System.Drawing.Size]::new(90,30)
    $selectNone.Location=[System.Drawing.Point]::new(112,625)
    $selectNone.Anchor="Bottom,Left"
    $selectNone.Add_Click({
        foreach($item in @($fileList.Items)){$item.Checked=$false}
    })
    $fileForm.Controls.Add($selectNone)

    $delete=New-Object System.Windows.Forms.Button
    $delete.Text="Delete Selected Files"
    $delete.Size=[System.Drawing.Size]::new(145,30)
    $delete.Location=[System.Drawing.Point]::new(209,625)
    $delete.Anchor="Bottom,Left"

    $close=New-Object System.Windows.Forms.Button
    $close.Text="Close"
    $close.Size=[System.Drawing.Size]::new(80,30)
    $close.Location=[System.Drawing.Point]::new(1068,625)
    $close.Anchor="Bottom,Right"
    $close.Add_Click({$fileForm.Close()})
    $fileForm.Controls.Add($close)

    $countLabel=New-Object System.Windows.Forms.Label
    $countLabel.Text="Selected: 0"
    $countLabel.Location=[System.Drawing.Point]::new(365,630)
    $countLabel.AutoSize=$true
    $countLabel.Anchor="Bottom,Left"
    $fileForm.Controls.Add($countLabel)

    $fileList.Add_ItemCheck({
        # ItemCheck fires before the state changes; use BeginInvoke to update after it.
        $fileForm.BeginInvoke([Action]{
            $selected=@($fileList.Items | Where-Object {$_.Checked}).Count
            $countLabel.Text="Selected: $selected"
        }) | Out-Null
    })

    $delete.Add_Click({
        $selectedItems=@($fileList.Items | Where-Object {$_.Checked})
        if($selectedItems.Count -eq 0){
            [System.Windows.Forms.MessageBox]::Show("Select at least one file.","Scanned Temporary Files") | Out-Null
            return
        }

        $selectedFiles=@(
            $selectedItems | ForEach-Object {$_.Tag}
        )

        $answer=[System.Windows.Forms.MessageBox]::Show(
            "Delete $($selectedFiles.Count) selected file(s)?`n`nOnly the exact files shown in this list will be targeted. Locked files will be skipped.",
            "Confirm File Deletion",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )
        if($answer -ne [System.Windows.Forms.DialogResult]::Yes){return}

        $operationId=[Guid]::NewGuid().ToString("N")
        $manifest=Join-Path $env:TEMP "WindowsPowerUser_SelectedTempFiles_$operationId.json"
        $selectedFiles | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $manifest -Encoding UTF8

        $worker=Join-Path $env:TEMP "WindowsPowerUser_SelectedTempFilesWorker_$operationId.ps1"
        $resultPath=Join-Path $env:TEMP "WindowsPowerUser_SelectedTempFilesResult_$operationId.json"
        $workerCode=@'
param([string]$Manifest,[string]$ResultPath)
$items=@(Get-Content -LiteralPath $Manifest -Raw | ConvertFrom-Json)
$deleted=0
$failures=@()
foreach($item in $items){
    try{
        if(Test-Path -LiteralPath $item.Path -PathType Leaf){
            Remove-Item -LiteralPath $item.Path -Force -ErrorAction Stop
            $deleted++
        }else{
            $failures+=,[PSCustomObject]@{Path=[string]$item.Path;Error="The file no longer exists or is not a file."}
        }
    }catch{
        $failures+=,[PSCustomObject]@{Path=[string]$item.Path;Error=$_.Exception.Message}
    }
}
[PSCustomObject]@{Deleted=$deleted;Failures=$failures} |
    ConvertTo-Json -Depth 5 -Compress |
    Set-Content -LiteralPath $ResultPath -Encoding UTF8
'@
        Set-Content -LiteralPath $worker -Value $workerCode -Encoding UTF8

        try{
            $proc=Start-Process -FilePath "powershell.exe" -Verb RunAs -ArgumentList @(
                "-NoProfile","-ExecutionPolicy","Bypass","-File",$worker,"-Manifest",$manifest,"-ResultPath",$resultPath
            ) -PassThru -ErrorAction Stop

            $delete.Enabled=$false
            $selectAll.Enabled=$false
            $selectNone.Enabled=$false
            $close.Enabled=$false
            $info.Text="Deleting selected files... Please wait."

            $poll=New-Object System.Windows.Forms.Timer
            $poll.Interval=500
            $poll.Add_Tick({
                if($proc.HasExited){
                    $poll.Stop()
                    $poll.Dispose()
                    $delete.Enabled=$true
                    $selectAll.Enabled=$true
                    $selectNone.Enabled=$true
                    $close.Enabled=$true

                    if(Test-Path -LiteralPath $resultPath){
                        try{
                            $operationResult=Get-Content -LiteralPath $resultPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                            $failureCount=@($operationResult.Failures).Count
                            $info.Text="Deletion finished: $($operationResult.Deleted) deleted, $failureCount failed. Rescan to refresh the file list."
                            Add-Status "Selected-file deletion finished: $($operationResult.Deleted) deleted, $failureCount failed."
                            if($failureCount -gt 0){
                                $failureText=(@($operationResult.Failures) | ForEach-Object {"$($_.Path)`n$($_.Error)"}) -join "`n`n"
                                [System.Windows.Forms.MessageBox]::Show(
                                    "Some selected files could not be deleted:`n`n$failureText",
                                    "Some files could not be deleted",
                                    [System.Windows.Forms.MessageBoxButtons]::OK,
                                    [System.Windows.Forms.MessageBoxIcon]::Warning
                                ) | Out-Null
                            }
                        }catch{
                            $info.Text="The deletion worker finished, but its result could not be read. Rescan to verify."
                            Add-Status "Could not read selected-file deletion results: $($_.Exception.Message)"
                        }
                    }else{
                        $info.Text="The deletion worker exited without a result (exit code $($proc.ExitCode)). Rescan to verify."
                        Add-Status "Selected-file deletion did not produce a result file."
                    }
                    Remove-Item -LiteralPath $manifest,$worker,$resultPath -Force -ErrorAction SilentlyContinue
                }
            }.GetNewClosure())
            $poll.Start()
        }catch{
            $delete.Enabled=$true
            $selectAll.Enabled=$true
            $selectNone.Enabled=$true
            $close.Enabled=$true
            Remove-Item -LiteralPath $manifest,$worker,$resultPath -Force -ErrorAction SilentlyContinue
            $info.Text="Deletion could not be started: $($_.Exception.Message)"
            Add-Status "Selected-file deletion could not be started: $($_.Exception.Message)"
        }
    })
    $fileForm.Controls.Add($delete)

    $fileList.BeginUpdate()
    foreach($f in $script:TempFileResults){
        $item=New-Object System.Windows.Forms.ListViewItem([string]$f.Name)
        [void]$item.SubItems.Add((Format-Bytes ([Int64]$f.Size)))
        [void]$item.SubItems.Add([string]$f.Category)
        [void]$item.SubItems.Add(([DateTime]$f.LastWriteTime).ToString("yyyy-MM-dd HH:mm:ss"))
        [void]$item.SubItems.Add([string]$f.Path)
        $item.Tag=$f
        # Explicit user choice: nothing checked initially.
        $item.Checked=$false
        [void]$fileList.Items.Add($item)
    }
    $fileList.EndUpdate()

    [void]$fileForm.ShowDialog($form)
    $fileForm.Dispose()
}


function Start-TempCleanup {
    $checked=@(
        $tempGrid.Controls |
        Where-Object {$_ -is [System.Windows.Forms.CheckBox] -and $_.Checked} |
        ForEach-Object {$_.Tag}
    )

    if($checked.Count -eq 0){
        [System.Windows.Forms.MessageBox]::Show("Select at least one cleanup category.","Temporary Files") | Out-Null
        return
    }

    $names=($checked | ForEach-Object {$_.Name}) -join "`n"
    $answer=[System.Windows.Forms.MessageBox]::Show(
        "Clean only these selected categories?`n`n$names`n`nLocked or in-use files will be skipped.",
        "Temporary Files Cleaner",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning)
    if($answer -ne [System.Windows.Forms.DialogResult]::Yes){return}

    $json=(@($checked | ForEach-Object {
        [PSCustomObject]@{Id=$_.Id;Name=$_.Name;Path=$_.Path}
    }) | ConvertTo-Json -Compress)
    $encoded=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))

    $operationId=[Guid]::NewGuid().ToString("N")
    $worker=Join-Path $env:TEMP "WindowsPowerUser_SelectedTempCleaner_$operationId.ps1"
    $resultPath=Join-Path $env:TEMP "WindowsPowerUser_SelectedTempCleanerResult_$operationId.json"
    $workerCode=@'
param([string]$EncodedTargets,[string]$ResultPath)
$targets=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($EncodedTargets)) | ConvertFrom-Json
$deleted=0
$failures=@()
foreach($t in @($targets)){
    if(-not (Test-Path -LiteralPath $t.Path)){continue}
    $files=@()
    $directories=@()
    try{
        switch($t.Id){
            "ThumbCache" {
                $files=@(Get-ChildItem -LiteralPath $t.Path -Filter "thumbcache*.db" -Force -File -ErrorAction Stop)
            }
            "Prefetch" {
                $files=@(Get-ChildItem -LiteralPath $t.Path -Force -File -ErrorAction Stop)
            }
            default {
                $files=@(Get-ChildItem -LiteralPath $t.Path -Force -File -ErrorAction Stop)
                $directories=@(Get-ChildItem -LiteralPath $t.Path -Force -Directory -ErrorAction Stop)
            }
        }
        foreach($file in $files){
            try{
                Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop
                $deleted++
            }catch{
                $failures+=,[PSCustomObject]@{Path=$file.FullName;Error=$_.Exception.Message}
            }
        }
        foreach($directory in @($directories)){
            try{
                Remove-Item -LiteralPath $directory.FullName -Recurse -Force -ErrorAction Stop
                $deleted++
            }catch{
                $failures+=,[PSCustomObject]@{Path=$directory.FullName;Error=$_.Exception.Message}
            }
        }
    }catch{
        $failures+=,[PSCustomObject]@{Path=[string]$t.Path;Error=$_.Exception.Message}
    }
}
[PSCustomObject]@{Deleted=$deleted;Failures=$failures} |
    ConvertTo-Json -Depth 5 -Compress |
    Set-Content -LiteralPath $ResultPath -Encoding UTF8
'@
    Set-Content -LiteralPath $worker -Value $workerCode -Encoding UTF8

    $tempScanBtn.Enabled=$false
    $tempCleanBtn.Enabled=$false
    $tempStatus.Text="Starting selected cleanup..."
    Add-Status "Launching selected temporary-file cleanup..."

    try{
        $cleanProcess=Start-Process -FilePath "powershell.exe" -Verb RunAs -ArgumentList @(
            "-NoProfile","-ExecutionPolicy","Bypass","-File",$worker,"-EncodedTargets",$encoded,"-ResultPath",$resultPath
        ) -PassThru -ErrorAction Stop

        $tempStatus.Text="Selected cleanup is running in the background..."
        $finish=New-Object System.Windows.Forms.Timer
        $finish.Interval=500
        $finish.Add_Tick({
            if($cleanProcess.HasExited){
                $finish.Stop();$finish.Dispose()
                $tempScanBtn.Enabled=$true
                $tempCleanBtn.Enabled=$true
                if(Test-Path -LiteralPath $resultPath){
                    try{
                        $operationResult=Get-Content -LiteralPath $resultPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                        $failureCount=@($operationResult.Failures).Count
                        $tempStatus.Text="Cleanup finished: $($operationResult.Deleted) items deleted, $failureCount failed. Scan again to verify."
                        Add-Status "Selected category cleanup finished: $($operationResult.Deleted) items deleted, $failureCount failed."
                        if($failureCount -gt 0){
                            $failureText=(@($operationResult.Failures) | ForEach-Object {"$($_.Path)`n$($_.Error)"}) -join "`n`n"
                            [System.Windows.Forms.MessageBox]::Show(
                                "Some cleanup items could not be removed:`n`n$failureText",
                                "Cleanup was incomplete",
                                [System.Windows.Forms.MessageBoxButtons]::OK,
                                [System.Windows.Forms.MessageBoxIcon]::Warning
                            ) | Out-Null
                        }
                    }catch{
                        $tempStatus.Text="The cleanup worker finished, but its result could not be read. Scan again to verify."
                        Add-Status "Could not read category cleanup results: $($_.Exception.Message)"
                    }
                }else{
                    $tempStatus.Text="The cleanup worker exited without a result (exit code $($cleanProcess.ExitCode))."
                    Add-Status "Selected category cleanup did not produce a result file."
                }
                Remove-Item -LiteralPath $worker,$resultPath -Force -ErrorAction SilentlyContinue
            }
        }.GetNewClosure())
        $finish.Start()
    }catch{
        Remove-Item -LiteralPath $worker,$resultPath -Force -ErrorAction SilentlyContinue
        $tempScanBtn.Enabled=$true
        $tempCleanBtn.Enabled=$true
        $tempStatus.Text="Cleanup could not be started: $($_.Exception.Message)"
        Add-Status "Selected category cleanup could not be started: $($_.Exception.Message)"
    }
}


# Maintenance tab
$tabMaint=New-Object System.Windows.Forms.TabPage
$tabMaint.Text="Maintenance"
$tabs.TabPages.Add($tabMaint)

function Start-MaintenanceCommand {
    param(
        [string]$Command,
        [bool]$RequiresAdmin = $false
    )

    # Always launch maintenance commands in a separate console process.
    # This prevents the WinForms UI thread from waiting on DISM/SFC/CHKDSK.
    try {
        if ($RequiresAdmin) {
            Start-Process -FilePath $env:ComSpec `
                -Verb RunAs `
                -ArgumentList @("/k", $Command) `
                -WorkingDirectory $env:SystemRoot
        }
        else {
            Start-Process -FilePath $env:ComSpec `
                -ArgumentList @("/k", $Command) `
                -WorkingDirectory $env:SystemRoot
        }
        Add-Status "Started: $Command"
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show(
            "Could not start:`n$Command`n`n$($_.Exception.Message)",
            "Operation could not be started",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }
}

$maintItems=@(
    @("Disk Cleanup","cleanmgr",""),
    @("Optimize Drive C:","defrag C: /O","admin"),
    @("Check Disk C:","chkdsk C: /scan","admin"),
    @("Flush DNS","ipconfig /flushdns","admin"),
    @("DISM RestoreHealth","DISM /Online /Cleanup-Image /RestoreHealth","admin"),
    @("SFC /scannow","sfc /scannow","admin"),
    @("System Diagnostics","perfmon /report",""),
    @("Reliability Monitor","perfmon /rel",""),
    @("System Information","msinfo32",""),
    @("Device Manager","devmgmt.msc",""),
    @("Services","services.msc",""),
    @("Task Scheduler","taskschd.msc",""),
    @("Malicious Software Removal Tool","MRT","admin")
)

$mrtInfo = New-Object System.Windows.Forms.Label
$mrtInfo.Text = "MRT scans for certain prevalent malware. It is not a replacement for Microsoft Defender."
$mrtInfo.Location = [System.Drawing.Point]::new(320,25)
$mrtInfo.MaximumSize = [System.Drawing.Size]::new(520,0)
$mrtInfo.AutoSize = $true
$tabMaint.Controls.Add($mrtInfo)

$my=25
foreach($mi in $maintItems){
    $b=New-Object System.Windows.Forms.Button
    $b.Text=$mi[0]
    $b.Size=[System.Drawing.Size]::new(260,38)
    $b.Location=[System.Drawing.Point]::new(25,$my)

    # Copy loop values into closure-safe variables.
    $buttonCommand = [string]$mi[1]
    $buttonNeedsAdmin = ($mi[2] -eq "admin")

    $b.Add_Click({
        Start-MaintenanceCommand -Command $buttonCommand -RequiresAdmin $buttonNeedsAdmin
    }.GetNewClosure())

    $tabMaint.Controls.Add($b)
    $my+=48
    if($my -gt 500){$my=25}
}

# Status bar
$status=New-Object System.Windows.Forms.Label
$status.Text="Ready."
$status.Dock="Bottom"
$status.Height=26
$status.BorderStyle="Fixed3D"
$status.Padding=[System.Windows.Forms.Padding]::new(8,4,0,0)
$form.Controls.Add($status)

$form.Add_Resize({
    $tabs.Location = [System.Drawing.Point]::new(0,78)
    $tabs.Size = [System.Drawing.Size]::new($form.ClientSize.Width, ($form.ClientSize.Height - 104))
})

$form.Add_FormClosing({
    if($script:ScanTimer){$script:ScanTimer.Stop();$script:ScanTimer.Dispose();$script:ScanTimer=$null}
    if($script:ScanJob){Remove-Job $script:ScanJob -Force -ErrorAction SilentlyContinue;$script:ScanJob=$null}
    if($script:TempScanTimer){$script:TempScanTimer.Stop();$script:TempScanTimer.Dispose();$script:TempScanTimer=$null}
    if($script:TempScanJob){Remove-Job $script:TempScanJob -Force -ErrorAction SilentlyContinue;$script:TempScanJob=$null}
    if($script:TempCleanTimer){$script:TempCleanTimer.Stop();$script:TempCleanTimer.Dispose();$script:TempCleanTimer=$null}
    if($script:TempCleanJob){Remove-Job $script:TempCleanJob -Force -ErrorAction SilentlyContinue;$script:TempCleanJob=$null}
})

$form.Add_Shown({
    $tabs.SelectedTab=$tabDash
    Populate-TempRows
    Add-Status "Ready. Scan selected categories to inspect individual temporary files."
})

[void]$form.ShowDialog()
