# =====================================================================
#  MTK AutoRepair  -  diagnose and recover MediaTek Android phones
#  Handles: booted (ADB), fastboot, BROM/preloader (mtkclient), no device,
#  power-loop / USB descriptor failures.
#  NOTE: no tool can guarantee a fix for every fault (dead eMMC, dead PMIC,
#  locked auth, wrong firmware). This script tries the safest fix first,
#  backs up before writing, and never overwrites IMEI/calibration partitions.
# =====================================================================
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$Stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$SessionDir = Join-Path $Root ("session_" + $Stamp)
$BackupDir = Join-Path $SessionDir 'backup'
$StageDir = Join-Path $SessionDir 'stage'
New-Item -ItemType Directory -Force -Path $SessionDir, $BackupDir | Out-Null
$LogFile = Join-Path $SessionDir 'session.log'
$ConfigFile = Join-Path $Root 'config.json'

$script:Python = $null
$script:PyPre = @()
$script:MtkEntry = $null
$script:MtkDir = $null
$script:Adb = $null
$script:Fastboot = $null
$script:FwDir = $null
$script:FwIndex = @{}
$script:FwMap = @{}
$script:FwPaths = ''
$script:FwPlatform = $null
$script:DiagOnly = $false
$script:MtkInfo = $null
$script:Gpt = @()
$script:MtkExtra = @()

# Never overwritten automatically (IMEI, calibration, security, user data)
$ProtectedParts = @('nvram','nvdata','nvcfg','proinfo','persist','protect1','protect2','seccfg','expdb','para','otp','frp','efuse','sec1','sec_ro','boot0','boot1','gpt','pgpt','sgpt','preloader','userdata','metadata')
# Backed up before any write
$CriticalParts = @('nvram','nvdata','nvcfg','proinfo','persist','protect1','protect2','seccfg','expdb','para','otp','sec1','sec_ro')
# Boot chain: the usual cause of bootloops / stuck-in-BROM after a bad flash
$BootChain = @('boot','recovery','vbmeta','vbmeta_system','vbmeta_vendor','dtbo','lk','lk2','logo','tee1','tee2','scp1','scp2','sspm_1','sspm_2','spmfw')
$Combos = @('Hold Vol Up + Vol Down','Hold Vol Down only','Hold Vol Up only','Hold Power + Vol Down','Hold all three buttons','Hold NO buttons (preloader mode)')

# ------------------------------------------------------------ UI helpers
function Write-Log {
    param([string]$Msg, [string]$Color = 'Gray')
    $line = '[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $Msg
    Write-Host $line -ForegroundColor $Color
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
}
function Write-Head([string]$Text) {
    Write-Host ''
    Write-Host ('=' * 72) -ForegroundColor Cyan
    Write-Host (' ' + $Text) -ForegroundColor Cyan
    Write-Host ('=' * 72) -ForegroundColor Cyan
    Add-Content -Path $LogFile -Value ("`r`n== " + $Text) -Encoding UTF8
}
function Confirm-Typed([string]$Message, [string]$Word = 'YES') {
    Write-Host ''
    Write-Host $Message -ForegroundColor Yellow
    $a = Read-Host ("Type {0} to continue, anything else to skip" -f $Word)
    return ($a.Trim() -ceq $Word)
}
function Confirm-YN([string]$Message) {
    $a = Read-Host ("{0} [Y/N]" -f $Message)
    return ($a.Trim().ToUpper() -eq 'Y')
}
function Read-Default([string]$Prompt, [string]$Default) {
    if ($Default) { $a = Read-Host ("{0} [Enter = {1}]" -f $Prompt, $Default) } else { $a = Read-Host $Prompt }
    $a = $a.Trim().Trim('"')
    if ($a -eq '') { return $Default }
    return $a
}
function Strip-Ansi([string]$s) {
    if (-not $s) { return '' }
    return [regex]::Replace($s, "\x1B\[[0-9;]*[A-Za-z]", '')
}

# ------------------------------------------------------------ process runner
function Join-Args([string[]]$a) {
    $parts = @()
    foreach ($x in $a) {
        if ($x -eq '' -or $x -match '[\s"]') { $parts += ('"' + ($x -replace '"', '\"') + '"') } else { $parts += $x }
    }
    return ($parts -join ' ')
}
function Show-New([string]$Path, [long]$Pos) {
    try {
        $fs = New-Object IO.FileStream($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        if ($fs.Length -gt $Pos) {
            [void]$fs.Seek($Pos, [IO.SeekOrigin]::Begin)
            $buf = New-Object byte[] ($fs.Length - $Pos)
            $n = $fs.Read($buf, 0, $buf.Length)
            $txt = [Text.Encoding]::UTF8.GetString($buf, 0, $n)
            Write-Host (Strip-Ansi $txt) -NoNewline
            $Pos += $n
        }
        $fs.Close()
    } catch {}
    return $Pos
}
function Invoke-Proc {
    param([string]$Exe, [string[]]$ArgList, [string]$WorkDir, [int]$TimeoutSec = 0, [switch]$Live)
    $o = [IO.Path]::GetTempFileName()
    $e = [IO.Path]::GetTempFileName()
    $env:PYTHONUNBUFFERED = '1'
    $env:PYTHONIOENCODING = 'utf-8'
    $sp = @{ FilePath = $Exe; ArgumentList = (Join-Args $ArgList); RedirectStandardOutput = $o; RedirectStandardError = $e; NoNewWindow = $true; PassThru = $true }
    if ($WorkDir) { $sp.WorkingDirectory = $WorkDir }
    $timedOut = $false
    $p = $null
    try { $p = Start-Process @sp } catch {
        Write-Log ("Could not start " + $Exe + ": " + $_.Exception.Message) 'Red'
        return [pscustomobject]@{ Code = -1; Text = ''; TimedOut = $false }
    }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $po = 0; $pe = 0
    while (-not $p.HasExited) {
        if ($Live) { $po = Show-New $o $po; $pe = Show-New $e $pe }
        if ($TimeoutSec -gt 0 -and $sw.Elapsed.TotalSeconds -gt $TimeoutSec) {
            $timedOut = $true
            & taskkill /PID $p.Id /T /F 2>&1 | Out-Null
            break
        }
        Start-Sleep -Milliseconds 400
    }
    $p.WaitForExit()
    if ($Live) { $po = Show-New $o $po; $pe = Show-New $e $pe; Write-Host '' }
    $text = [string](Get-Content -LiteralPath $o -Raw -ErrorAction SilentlyContinue) + "`n" + [string](Get-Content -LiteralPath $e -Raw -ErrorAction SilentlyContinue)
    Remove-Item -LiteralPath $o, $e -Force -ErrorAction SilentlyContinue
    $code = $p.ExitCode
    if ($timedOut) { $code = 124 }
    return [pscustomobject]@{ Code = $code; Text = (Strip-Ansi $text); TimedOut = $timedOut }
}

# ------------------------------------------------------------ mtkclient parsing
$script:MtkRules = @(
    @{ Pat = 'Couldn''t get device configuration'; Msg = 'USB driver/libusb problem, or the phone keeps resetting its USB port (power loop). Install UsbDk 64-bit + the MediaTek serial driver, use a rear USB 2.0 port.' },
    @{ Pat = 'Handshake failed'; Msg = 'Handshake failed: timing or driver. Start the tool first, then connect, and try another button combination.' },
    @{ Pat = 'USBError\(19'; Msg = 'Device vanished mid-command (cable, port or power loop).' },
    @{ Pat = 'USBError\(5'; Msg = 'USB I/O error: unstable connection. Use a short data cable on a rear USB 2.0 port.' },
    @{ Pat = 'Please disconnect, start mtkclient and reconnect'; Msg = 'The tool wants a clean reconnect: unplug, start the tool, plug in again.' },
    @{ Pat = 'No module named'; Msg = 'A Python dependency is missing: run pip install -r requirements.txt in the mtkclient folder.' },
    @{ Pat = 'STATUS_BROM_CMD|STATUS_SEC|0xC006'; Msg = 'BROM/security status error: authentication or download-agent problem.' },
    @{ Pat = 'Access is denied|Permission denied'; Msg = 'Permission problem: run the launcher as Administrator.' }
)
function Get-MtkInfo([string]$t) {
    $i = [ordered]@{ Detected = $false; Brom = $false; Protected = $false; Chip = ''; HwCode = ''; Sbc = ''; Sla = ''; Daa = ''; Problems = @(); Partitions = @() }
    if ($t -match 'Device detected') { $i.Detected = $true }
    if ($t -match 'BROM mode detected|Device is in BROM') { $i.Brom = $true }
    if ($t -match 'Device is protected') { $i.Protected = $true }
    if ($t -match 'CPU:\s*([^\r\n]+)') { $i.Chip = $matches[1].Trim(); $i.Detected = $true }
    if ($t -match 'HW code:\s*(0x[0-9a-fA-F]+)') { $i.HwCode = $matches[1] }
    if ($t -match 'SBC enabled:\s*(\w+)') { $i.Sbc = $matches[1] }
    if ($t -match 'SLA enabled:\s*(\w+)') { $i.Sla = $matches[1] }
    if ($t -match 'DAA enabled:\s*(\w+)') { $i.Daa = $matches[1] }
    foreach ($r in $script:MtkRules) { if ($t -match $r.Pat) { $i.Problems += $r.Msg } }
    if (-not $i.Detected -and $t -match 'Waiting for PreLoader VCOM') { $i.Problems += 'No MediaTek device reached the tool while it was waiting.' }
    foreach ($ln in ($t -split "`r?`n")) {
        if ($ln -match '^\s*([A-Za-z0-9_\.\-]+):\s*Offset:?\s*0x([0-9a-fA-F]+),\s*Length:?\s*0x([0-9a-fA-F]+)') {
            $i.Partitions += [pscustomobject]@{ Name = $matches[1]; Offset = [Convert]::ToUInt64($matches[2], 16); Length = [Convert]::ToUInt64($matches[3], 16) }
        }
    }
    return [pscustomobject]$i
}
function Invoke-Mtk {
    param([string[]]$MtkArgs, [int]$TimeoutSec = 0, [switch]$Quiet)
    $extra = @()
    if ($script:MtkExtra -and $MtkArgs -notcontains '-h') { $extra = @($script:MtkExtra) }
    $a = @() + $script:PyPre + @($script:MtkEntry) + $MtkArgs + $extra
    Write-Log ('mtk ' + ($MtkArgs -join ' ')) 'DarkGray'
    if ($Quiet) { $r = Invoke-Proc -Exe $script:Python -ArgList $a -WorkDir $script:MtkDir -TimeoutSec $TimeoutSec }
    else { $r = Invoke-Proc -Exe $script:Python -ArgList $a -WorkDir $script:MtkDir -TimeoutSec $TimeoutSec -Live }
    Add-Content -Path $LogFile -Value $r.Text -Encoding UTF8
    $info = Get-MtkInfo $r.Text
    return [pscustomobject]@{ Code = $r.Code; Text = $r.Text; TimedOut = $r.TimedOut; Info = $info }
}
function Show-MtkProblems($info) {
    foreach ($p in @($info.Problems)) { Write-Log ('  Problem: ' + $p) 'Yellow' }
}

# ------------------------------------------------------------ setup
function Load-Config {
    $c = [pscustomobject]@{ mtk = ''; adb = ''; fastboot = ''; fw = '' }
    if (Test-Path -LiteralPath $ConfigFile) {
        try { $j = Get-Content -LiteralPath $ConfigFile -Raw | ConvertFrom-Json; foreach ($k in 'mtk', 'adb', 'fastboot', 'fw') { if ($j.$k) { $c.$k = [string]$j.$k } } } catch {}
    }
    return $c
}
function Save-Config($c) { try { $c | ConvertTo-Json | Set-Content -LiteralPath $ConfigFile -Encoding UTF8 } catch {} }

function Find-MtkEntry([string]$Dir) {
    foreach ($n in 'mtk.py', 'mtk') {
        $f = Join-Path $Dir $n
        if (Test-Path -LiteralPath $f -PathType Leaf) { return $f }
    }
    $hit = Get-ChildItem -LiteralPath $Dir -Recurse -Depth 2 -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'mtk.py' -or $_.Name -eq 'mtk' } | Select-Object -First 1
    if ($hit) { return $hit.FullName }
    return $null
}
function Resolve-Tool([string]$InputPath, [string]$Exe) {
    if ($InputPath) {
        if (Test-Path -LiteralPath $InputPath -PathType Container) {
            $c = Join-Path $InputPath $Exe
            if (Test-Path -LiteralPath $c -PathType Leaf) { return $c }
            $hit = Get-ChildItem -LiteralPath $InputPath -Recurse -Depth 3 -File -Filter $Exe -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($hit) { return $hit.FullName }
        } elseif (Test-Path -LiteralPath $InputPath -PathType Leaf) { return $InputPath }
    }
    $cmd = Get-Command $Exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}
function Initialize-Python {
    $cands = @(
        [pscustomobject]@{ Name = 'python'; Pre = @() },
        [pscustomobject]@{ Name = 'py'; Pre = @('-3') }
    )
    foreach ($c in $cands) {
        $cmd = Get-Command $c.Name -ErrorAction SilentlyContinue
        if ($cmd) {
            $r = Invoke-Proc -Exe $cmd.Source -ArgList (@() + $c.Pre + @('--version')) -TimeoutSec 20
            if ($r.Code -eq 0 -and $r.Text -match 'Python 3\.\d+') { $script:Python = $cmd.Source; $script:PyPre = $c.Pre; return $true }
        }
    }
    return $false
}
function Test-MtkRuns {
    $r = Invoke-Mtk -MtkArgs @('-h') -TimeoutSec 90 -Quiet
    if ($r.Text -match 'No module named') {
        Write-Log 'mtkclient is missing Python dependencies.' 'Yellow'
        if (Confirm-YN 'Install them now (pip install -r requirements.txt)?') {
            $req = Join-Path $script:MtkDir 'requirements.txt'
            if (Test-Path -LiteralPath $req) {
                [void](Invoke-Proc -Exe $script:Python -ArgList (@() + $script:PyPre + @('-m', 'pip', 'install', '-r', $req)) -WorkDir $script:MtkDir -Live)
                $r = Invoke-Mtk -MtkArgs @('-h') -TimeoutSec 90 -Quiet
            } else { Write-Log 'requirements.txt not found in the mtkclient folder.' 'Red' }
        }
    }
    return ($r.Text -match 'usage|printgpt')
}
function Test-UsbDk {
    if (Test-Path 'C:\Program Files\UsbDk Runtime Library') { return $true }
    if (Get-Service -Name 'UsbDk' -ErrorAction SilentlyContinue) { return $true }
    return $false
}

function Initialize-Paths {
    Write-Head 'Tool and firmware locations'
    $cfg = Load-Config
    $mtkIn = Read-Default 'Path to the mtkclient folder (contains mtk.py)' $cfg.mtk
    $adbIn = Read-Default 'Path to adb (folder or adb.exe; Enter = search PATH)' $cfg.adb
    $fbIn = Read-Default 'Path to fastboot (folder or fastboot.exe; Enter = search PATH)' $cfg.fastboot
    $fwIn = Read-Default 'Path to the firmware folder (every subfolder is searched)' $cfg.fw

    $script:MtkEntry = $null
    if ($mtkIn -and (Test-Path -LiteralPath $mtkIn -PathType Container)) { $script:MtkEntry = Find-MtkEntry $mtkIn }
    if (-not $script:MtkEntry) { Write-Log 'mtkclient not found at the path given.' 'Yellow'; $script:MtkEntry = Request-ManualMtk }
    if ($script:MtkEntry) { $script:MtkDir = Split-Path -Parent $script:MtkEntry; Write-Log ('mtkclient : ' + $script:MtkEntry) 'Green' }
    else { Write-Log 'mtkclient : NOT FOUND (BROM/preloader repair will be unavailable)' 'Red' }

    $script:Adb = Resolve-Tool $adbIn 'adb.exe'
    if (-not $script:Adb) { Write-Log 'adb was not found automatically.' 'Yellow'; $script:Adb = Request-ManualTool 'adb' 'adb.exe' }
    if ($script:Adb) { Write-Log ('adb       : ' + $script:Adb) 'Green' } else { Write-Log 'adb       : NOT FOUND' 'Red' }
    $script:Fastboot = Resolve-Tool $fbIn 'fastboot.exe'
    if (-not $script:Fastboot) { Write-Log 'fastboot was not found automatically.' 'Yellow'; $script:Fastboot = Request-ManualTool 'fastboot' 'fastboot.exe' }
    if ($script:Fastboot) { Write-Log ('fastboot  : ' + $script:Fastboot) 'Green' } else { Write-Log 'fastboot  : NOT FOUND' 'Red' }

    if ($script:Adb) {
        $v = Invoke-Proc -Exe $script:Adb -ArgList @('version') -TimeoutSec 15
        $first = ($v.Text -split "`r?`n" | Where-Object { $_ -match 'Android Debug Bridge version|Version' } | Select-Object -First 2) -join ' | '
        if ($first) { Write-Log ('adb version: ' + $first) 'DarkGray' }
    }

    if ($script:MtkEntry) {
        if (-not (Initialize-Python) -and -not (Request-ManualPython)) { Write-Log 'Python 3 not found. Install it from python.org (tick "Add to PATH"), then rerun.' 'Red'; $script:MtkEntry = $null }
        else {
            Write-Log ('python    : ' + $script:Python) 'Green'
            if (-not (Test-MtkRuns)) { Write-Log 'mtkclient did not start correctly; see the log for details.' 'Yellow' }
            if (-not (Test-UsbDk)) { Write-Log 'UsbDk does not appear to be installed (mtkclient needs it on Windows).' 'Yellow' }
        }
    }
    Save-Config ([pscustomobject]@{ mtk = $mtkIn; adb = $adbIn; fastboot = $fbIn; fw = $fwIn })
    if ($fwIn -and (Test-Path -LiteralPath $fwIn -PathType Container)) { Initialize-Firmware $fwIn }
    else { Write-Log 'Firmware folder not set or not found.' 'Yellow' }
    if (@($script:FwIndex.Keys).Count -eq 0 -and $script:FwMap.Count -eq 0) { Request-ManualFirmware }
    Save-Config ([pscustomobject]@{
            mtk = $(if ($script:MtkDir) { $script:MtkDir } else { $mtkIn })
            adb = $(if ($script:Adb) { $script:Adb } else { $adbIn })
            fastboot = $(if ($script:Fastboot) { $script:Fastboot } else { $fbIn })
            fw = $(if ($script:FwDir) { $script:FwDir } else { $fwIn }) })
}

# ------------------------------------------------------------ firmware scan
function Test-Sparse([string]$Path) {
    try {
        $fs = [IO.File]::OpenRead($Path)
        $b = New-Object byte[] 4
        [void]$fs.Read($b, 0, 4)
        $fs.Close()
        return ($b[0] -eq 0x3A -and $b[1] -eq 0xFF -and $b[2] -eq 0x26 -and $b[3] -eq 0xED)
    } catch { return $false }
}
function Initialize-Firmware([string]$Dir) {
    $script:FwDir = $Dir
    $script:FwIndex = @{}
    $script:FwMap = @{}
    $script:FwPlatform = $null
    Write-Log ('Scanning firmware folder (all subfolders): ' + $Dir)
    $all = @(Get-ChildItem -LiteralPath $Dir -Recurse -File -ErrorAction SilentlyContinue | Where-Object {
            $_.FullName -notmatch '\\session_\d{8}_\d{6}\\' -and
            -not ($script:MtkDir -and $_.FullName.StartsWith($script:MtkDir, [StringComparison]::OrdinalIgnoreCase))
        })
    $imgs = @($all | Where-Object { $_.Extension -in '.img', '.bin', '.mbn' })
    if ($imgs.Count -eq 0) {
        $arch = @($all | Where-Object { $_.Extension -in '.zip', '.tgz', '.gz', '.tar', '.iso', '.7z', '.rar' })
        if ($arch.Count -gt 0) {
            Write-Log ('No .img/.bin files found, but found archives: ' + (($arch | Select-Object -First 5 | ForEach-Object { $_.Name }) -join ', ')) 'Yellow'
            $ex = @($arch | Where-Object { $_.Extension -in '.zip', '.tgz', '.gz', '.tar' } | Select-Object -First 1)
            if ($ex.Count -gt 0 -and (Get-Command tar.exe -ErrorAction SilentlyContinue) -and (Confirm-YN ('Extract ' + $ex[0].Name + ' with tar.exe now?'))) {
                $dest = Join-Path $ex[0].DirectoryName ('_extracted_' + $ex[0].BaseName)
                New-Item -ItemType Directory -Force -Path $dest | Out-Null
                [void](Invoke-Proc -Exe 'tar.exe' -ArgList @('-xf', $ex[0].FullName, '-C', $dest) -Live)
                $all = @(Get-ChildItem -LiteralPath $Dir -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.FullName -notmatch '\\session_\d{8}_\d{6}\\' })
                $imgs = @($all | Where-Object { $_.Extension -in '.img', '.bin', '.mbn' })
            } else { Write-Log '.iso/.7z/.rar are not extracted automatically. Extract them with 7-Zip into the firmware folder and rescan.' 'Yellow' }
        }
    }
    $rank = @{ '.img' = 0; '.bin' = 1; '.mbn' = 2 }
    foreach ($f in ($imgs | Sort-Object @{ Expression = { $rank[$_.Extension] } }, @{ Expression = { $_.FullName.Length } })) {
        $k = $f.BaseName.ToLower()
        if (-not $script:FwIndex.ContainsKey($k)) { $script:FwIndex[$k] = $f }
    }
    $script:FwPaths = (($all | ForEach-Object { $_.FullName }) -join "`n").ToLower()
    $sc = $all | Where-Object { $_.Name -match 'scatter' -and $_.Extension -in '.txt', '.xml' } | Select-Object -First 1
    if ($sc) {
        $txt = Get-Content -LiteralPath $sc.FullName -Raw -ErrorAction SilentlyContinue
        if ($txt -match 'project:\s*(\w+)') { $script:FwPaths += ("`n" + $matches[1].ToLower()) }
        if ($txt -match 'platform:\s*(\w+)') { $script:FwPlatform = $matches[1] }
        elseif ($txt -match 'platform="?(MT\w+)') { $script:FwPlatform = $matches[1] }
        $byName = @{}
        foreach ($f in $imgs) { if (-not $byName.ContainsKey($f.Name.ToLower())) { $byName[$f.Name.ToLower()] = $f } }
        foreach ($m in [regex]::Matches($txt, 'partition_name:\s*(\S+)[\s\S]*?file_name:\s*(\S+)')) {
            $pn = $m.Groups[1].Value.ToLower(); $fnm = $m.Groups[2].Value.ToLower()
            if ($fnm -ne 'none' -and $byName.ContainsKey($fnm)) { $script:FwMap[$pn] = $byName[$fnm] }
        }
        Write-Log ('Scatter file: ' + $sc.Name + '  platform=' + $script:FwPlatform + '  mapped partitions=' + $script:FwMap.Count) 'Green'
    }
    Write-Log ('Firmware images indexed: ' + $script:FwIndex.Count + ' (by name), scatter-mapped: ' + $script:FwMap.Count) 'Green'
    if ($script:FwIndex.Count -eq 0) { Write-Log 'No usable firmware images found.' 'Yellow' }
}
function Get-FwFile([string]$Part) {
    $k = $Part.ToLower()
    if ($script:FwMap.ContainsKey($k)) { return $script:FwMap[$k] }
    if ($script:FwIndex.ContainsKey($k)) { return $script:FwIndex[$k] }
    return $null
}
function Test-FwNameMatch([string]$Code) {
    if (-not $Code -or -not $script:FwPaths) { return $null }
    return $script:FwPaths.Contains($Code.ToLower())
}

# ------------------------------------------------------------ device detection
function Get-AdbDevices {
    if (-not $script:Adb) { return @() }
    [void](Invoke-Proc -Exe $script:Adb -ArgList @('start-server') -TimeoutSec 20)
    $r = Invoke-Proc -Exe $script:Adb -ArgList @('devices', '-l') -TimeoutSec 15
    $out = @()
    foreach ($l in ($r.Text -split "`r?`n")) {
        if ($l -match '^(\S+)\s+(device|unauthorized|offline|recovery|sideload|bootloader|rescue)\b(.*)$') {
            $out += [pscustomobject]@{ Serial = $matches[1]; State = $matches[2]; Info = $matches[3].Trim() }
        }
    }
    return $out
}
function Get-FastbootDevices {
    if (-not $script:Fastboot) { return @() }
    $r = Invoke-Proc -Exe $script:Fastboot -ArgList @('devices') -TimeoutSec 15
    $out = @()
    foreach ($l in ($r.Text -split "`r?`n")) {
        if ($l -match '^(\S+)\s+(fastboot|fastbootd)\b') { $out += [pscustomobject]@{ Serial = $matches[1]; State = $matches[2] } }
    }
    return $out
}
function Get-UsbState {
    $mtk = @(); $failed = @()
    $all = Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue
    foreach ($d in $all) {
        $id = [string]$d.DeviceID
        if ($id -match 'VID_0E8D&PID_([0-9A-Fa-f]{4})') { $mtk += [pscustomobject]@{ Id = $id; Name = $d.Name; Pid = $matches[1]; Err = $d.ConfigManagerErrorCode } }
        elseif ($d.ConfigManagerErrorCode -eq 43 -and $id -like 'USB*') { $failed += [pscustomobject]@{ Id = $id; Name = $d.Name } }
    }
    return [pscustomobject]@{ Mtk = $mtk; Failed = $failed }
}
function Get-DeviceState {
    $adbs = @(Get-AdbDevices)
    $fbs = @(Get-FastbootDevices)
    $usb = Get-UsbState
    $mode = 'NONE'; $a = $null; $f = $null
    if ($adbs.Count -gt 0) { $mode = 'ADB'; $a = $adbs[0] }
    elseif ($fbs.Count -gt 0) { $mode = 'FASTBOOT'; $f = $fbs[0] }
    elseif (@($usb.Mtk).Count -gt 0) { $mode = 'MTK-USB' }
    elseif (@($usb.Failed).Count -gt 0) { $mode = 'USB-FAILED' }
    return [pscustomobject]@{ Mode = $mode; Adb = $a; Fb = $f; Usb = $usb }
}
function Show-State($st) {
    Write-Head 'Detection result'
    switch ($st.Mode) {
        'ADB' { Write-Log ('Phone found over ADB: ' + $st.Adb.Serial + ' state=' + $st.Adb.State) 'Green' }
        'FASTBOOT' { Write-Log ('Phone found in fastboot: ' + $st.Fb.Serial) 'Green' }
        'MTK-USB' {
            foreach ($d in @($st.Usb.Mtk)) { Write-Log ('MediaTek USB device: ' + $d.Name + ' PID_' + $d.Pid + ' (error code ' + $d.Err + ')') 'Green' }
            Write-Log 'Diagnosis: phone is in BROM/preloader mode - the OS is not starting (damaged boot chain, failed flash, or power loop).' 'Yellow'
        }
        'USB-FAILED' {
            foreach ($d in @($st.Usb.Failed)) { Write-Log ('Failed USB device: ' + $d.Name + '  ' + $d.Id) 'Yellow' }
            Write-Log 'Diagnosis: something is plugged in but cannot identify itself (Code 43). Typical causes: phone power loop, weak cable, front-panel/hub port, USB 3.0 port.' 'Yellow'
        }
        default {
            Write-Log 'No phone detected over ADB, fastboot or MediaTek USB.' 'Yellow'
            Write-Log 'Diagnosis: phone is fully off/dead, cable or port is bad, or the phone only exposes USB for a second at a time (power loop).' 'Yellow'
        }
    }
}

# ------------------------------------------------------------ ADB branch
function Get-AdbProp([string]$Serial, [string]$Prop) {
    $r = Invoke-Proc -Exe $script:Adb -ArgList @('-s', $Serial, 'shell', 'getprop', $Prop) -TimeoutSec 15
    return $r.Text.Trim()
}
function Wait-Boot([int]$Sec = 150) {
    Write-Log ('Waiting up to ' + $Sec + 's for Android to report boot completed (needs USB debugging on)...')
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $Sec) {
        $d = @(Get-AdbDevices) | Where-Object { $_.State -eq 'device' } | Select-Object -First 1
        if ($d) { if ((Get-AdbProp $d.Serial 'sys.boot_completed') -eq '1') { Write-Log 'Android booted (sys.boot_completed=1).' 'Green'; return $true } }
        Start-Sleep -Seconds 5
    }
    return (Confirm-YN 'Could not confirm via ADB. Did the phone boot to Android / setup screen?')
}
function Repair-Adb($st) {
    $d = $st.Adb
    Write-Head ('ADB branch: ' + $d.Serial + ' (' + $d.State + ')')
    if ($d.State -eq 'unauthorized') { Write-Log 'Unlock the phone and accept "Allow USB debugging" (tick Always allow), then run again.' 'Yellow'; return }
    if ($d.State -eq 'offline') {
        Write-Log 'Device offline: restarting the ADB server.' 'Yellow'
        [void](Invoke-Proc -Exe $script:Adb -ArgList @('kill-server') -TimeoutSec 15)
        Start-Sleep -Seconds 2
        Write-Log 'Reconnect the cable and run the tool again.' 'Yellow'; return
    }
    if ($d.State -ne 'device') {
        Write-Log ('Phone is in ' + $d.State + ' mode: Android is not running. Booting normally is not possible from here.') 'Yellow'
        if ($script:DiagOnly) { return }
        if (Confirm-YN 'Try "adb reboot" (normal start)?') { [void](Invoke-Proc -Exe $script:Adb -ArgList @('-s', $d.Serial, 'reboot') -TimeoutSec 20); [void](Wait-Boot 120) }
        return
    }
    $props = [ordered]@{ 'Manufacturer' = 'ro.product.manufacturer'; 'Model' = 'ro.product.model'; 'Codename' = 'ro.product.device'; 'Android' = 'ro.build.version.release'; 'Build' = 'ro.build.display.id'; 'Hardware' = 'ro.hardware'; 'Boot completed' = 'sys.boot_completed'; 'Verified boot' = 'ro.boot.verifiedbootstate'; 'Bootloader locked' = 'ro.boot.flash.locked'; 'Slot suffix' = 'ro.boot.slot_suffix'; 'Security patch' = 'ro.build.version.security_patch' }
    $v = @{}
    foreach ($k in $props.Keys) { $v[$k] = Get-AdbProp $d.Serial $props[$k]; Write-Log ('{0,-18}: {1}' -f $k, $v[$k]) }
    Write-Head 'Findings'
    $issues = 0
    if ($v['Boot completed'] -ne '1') { Write-Log 'Android has NOT finished booting (stuck or looping).' 'Yellow'; $issues++ }
    $bat = Invoke-Proc -Exe $script:Adb -ArgList @('-s', $d.Serial, 'shell', 'dumpsys', 'battery') -TimeoutSec 20
    if ($bat.Text -match 'level:\s*(\d+)') { Write-Log ('Battery level: ' + $matches[1] + '%'); if ([int]$matches[1] -lt 10) { Write-Log 'Battery very low: charge before flashing anything.' 'Yellow'; $issues++ } }
    $df = Invoke-Proc -Exe $script:Adb -ArgList @('-s', $d.Serial, 'shell', 'df', '/data') -TimeoutSec 20
    if ($df.Text -match '(\d+)%') { Write-Log ('/data used: ' + $matches[1] + '%'); if ([int]$matches[1] -ge 97) { Write-Log '/data is almost full: a full disk can cause boot problems/crashes.' 'Yellow'; $issues++ } }
    $crash = Invoke-Proc -Exe $script:Adb -ArgList @('-s', $d.Serial, 'logcat', '-d', '-b', 'crash', '-t', '60') -TimeoutSec 30
    Set-Content -LiteralPath (Join-Path $SessionDir 'logcat_crash.txt') -Value $crash.Text -Encoding UTF8
    if (($crash.Text -split "`n").Count -gt 8) { Write-Log 'Crash log has entries (saved to logcat_crash.txt).' 'Yellow'; $issues++ }
    $m = Test-FwNameMatch $v['Codename']
    if ($m -eq $true) { Write-Log ('Firmware folder appears to match codename "' + $v['Codename'] + '".') 'Green' }
    elseif ($m -eq $false) { Write-Log ('Firmware folder does NOT mention codename "' + $v['Codename'] + '" - verify it is the right firmware before flashing.') 'Yellow' }
    if ($issues -eq 0) { Write-Log 'No fault found: the phone is running normally.' 'Green' }
    if ($script:DiagOnly) { return }
    Write-Host ''
    Write-Host '  [1] Reboot normally   [2] Reboot to bootloader (fastboot repair)   [3] Reboot to recovery   [Q] Done'
    switch ((Read-Host 'Choose').Trim().ToUpper()) {
        '1' { [void](Invoke-Proc -Exe $script:Adb -ArgList @('-s', $d.Serial, 'reboot') -TimeoutSec 20); [void](Wait-Boot 150) }
        '2' {
            [void](Invoke-Proc -Exe $script:Adb -ArgList @('-s', $d.Serial, 'reboot', 'bootloader') -TimeoutSec 20)
            Start-Sleep -Seconds 8
            $f = @(Get-FastbootDevices)
            if ($f.Count -gt 0) { Repair-Fastboot ([pscustomobject]@{ Fb = $f[0] }) } else { Write-Log 'Phone did not appear in fastboot.' 'Yellow' }
        }
        '3' { [void](Invoke-Proc -Exe $script:Adb -ArgList @('-s', $d.Serial, 'reboot', 'recovery') -TimeoutSec 20) }
    }
}

# ------------------------------------------------------------ Fastboot branch
function Get-FbVar([string]$Name) {
    $r = Invoke-Proc -Exe $script:Fastboot -ArgList @('getvar', $Name) -TimeoutSec 20
    if ($r.Text -match ('(?m)^\s*' + [regex]::Escape($Name) + ':\s*(.+?)\s*$')) { return $matches[1] }
    return ''
}
function Invoke-Fb([string[]]$a, [int]$t = 600) {
    Write-Log ('fastboot ' + ($a -join ' ')) 'DarkGray'
    $r = Invoke-Proc -Exe $script:Fastboot -ArgList $a -TimeoutSec $t -Live
    Add-Content -Path $LogFile -Value $r.Text -Encoding UTF8
    return $r
}
function Test-FbOk($r) { return ($r.Code -eq 0 -and $r.Text -notmatch 'FAILED') }
function Repair-Fastboot($st) {
    Write-Head ('Fastboot branch: ' + $st.Fb.Serial)
    $product = Get-FbVar 'product'
    $unlocked = Get-FbVar 'unlocked'
    $secure = Get-FbVar 'secure'
    $slot = Get-FbVar 'current-slot'
    foreach ($p in @(@('product', $product), @('unlocked', $unlocked), @('secure', $secure), @('current-slot', $slot), @('version-bootloader', (Get-FbVar 'version-bootloader')))) { Write-Log ('{0,-20}: {1}' -f $p[0], $p[1]) }
    Write-Log 'Diagnosis: phone is sitting in fastboot because Android would not start (or was sent here). Boot/vbmeta/system images are the usual cause.' 'Yellow'
    $m = Test-FwNameMatch $product
    if ($m -eq $false) { Write-Log ('Firmware folder does NOT mention "' + $product + '". Wrong firmware can brick the phone.') 'Red' }
    elseif ($m -eq $true) { Write-Log 'Firmware folder name matches this device.' 'Green' }
    if ($script:DiagOnly) { Write-Log 'Diagnose-only: stopping here. Recommended: reboot, then boot-chain flash, then full flash.' 'Cyan'; return }

    Write-Head 'Level 1: plain reboot'
    [void](Invoke-Fb @('reboot') 60)
    if (Wait-Boot 120) { Write-Log 'Fixed by reboot.' 'Green'; return }
    $f = @(Get-FastbootDevices)
    if ($f.Count -eq 0) { Write-Log 'Put the phone back in fastboot (Power + Vol Down) and rerun.' 'Yellow'; return }

    if ($unlocked -match '^(no|false)$') {
        Write-Log 'Bootloader is LOCKED: fastboot flashing will be refused. Unlock via the Xiaomi Mi Unlock process, or use the BROM (mtkclient) route.' 'Red'
        Offer-ManualFallback 'locked bootloader'
        return
    }
    if (@($script:FwIndex.Keys).Count -eq 0 -and $script:FwMap.Count -eq 0) { Request-ManualFirmware }

    Write-Head 'Level 2: restore boot chain'
    $done = 0
    foreach ($p in $BootChain) {
        $fw = Get-FwFile $p
        if ($fw) { $r = Invoke-Fb @('flash', $p, $fw.FullName); if (Test-FbOk $r) { $done++ } else { Write-Log ('  ' + $p + ' failed (partition may not exist on this model).') 'Yellow' } }
    }
    if ($done -eq 0) {
        Write-Log 'No boot-chain image was flashed automatically.' 'Yellow'
        $core = @('boot', 'recovery', 'vbmeta', 'lk')
        if ((Request-ManualImages $core) -gt 0) {
            foreach ($p in $core) { $fw = Get-FwFile $p; if ($fw) { $r = Invoke-Fb @('flash', $p, $fw.FullName); if (Test-FbOk $r) { $done++ } } }
        }
    }
    Write-Log ('Boot-chain partitions flashed: ' + $done)
    [void](Invoke-Fb @('reboot') 60)
    if (Wait-Boot 150) { Write-Log 'Fixed by boot-chain restore.' 'Green'; return }

    $f = @(Get-FastbootDevices)
    if ($f.Count -eq 0) { Write-Log 'Return to fastboot (Power + Vol Down) and rerun for Level 3.' 'Yellow'; return }
    Write-Head 'Level 3: wipe data + boot chain'
    if (Confirm-Typed 'This ERASES userdata/metadata (all personal data on the phone).') {
        foreach ($p in @('userdata', 'metadata', 'cache')) { [void](Invoke-Fb @('erase', $p) 120) }
        foreach ($p in $BootChain) { $fw = Get-FwFile $p; if ($fw) { [void](Invoke-Fb @('flash', $p, $fw.FullName)) } }
        [void](Invoke-Fb @('reboot') 60)
        if (Wait-Boot 180) { Write-Log 'Fixed by data wipe.' 'Green'; return }
    }

    $f = @(Get-FastbootDevices)
    if ($f.Count -eq 0) { Write-Log 'Return to fastboot and rerun for Level 4.' 'Yellow'; return }
    Write-Head 'Level 4: full firmware flash'
    if ($m -ne $true -and -not (Confirm-Typed 'Firmware name does not match the device. Continue ANYWAY?' 'WRONGFW')) { return }
    if (Confirm-Typed 'Full flash: every matching image except IMEI/calibration/preloader will be written.') {
        $order = @()
        if ($script:FwMap.Count -gt 0) { $order = @($script:FwMap.Keys) } else { $order = @($script:FwIndex.Keys) }
        foreach ($p in $order) {
            if ($ProtectedParts -contains $p) { continue }
            $fw = Get-FwFile $p
            if ($fw) { [void](Invoke-Fb @('flash', $p, $fw.FullName) 900) }
        }
        [void](Invoke-Fb @('erase', 'userdata') 120)
        [void](Invoke-Fb @('reboot') 60)
        if (Wait-Boot 240) { Write-Log 'Fixed by full flash.' 'Green'; return }
    }
    Write-Log 'Fastboot repair did not restore Android. Next step: BROM route (power off, rerun the tool).' 'Yellow'
    Offer-ManualFallback 'fastboot'
}

# ------------------------------------------------------------ MTK (BROM / preloader) branch
function Request-Reconnect([int]$n) {
    $combo = $Combos[($n - 1) % $Combos.Count]
    Write-Host ''
    Write-Host ('--- Connection attempt ' + $n + ' ---') -ForegroundColor Cyan
    Write-Host ' 1. Unplug the USB cable.'
    Write-Host ' 2. Power the phone fully OFF (hold Power 15-30 s; if it keeps looping, let the battery drain).'
    Write-Host (' 3. Press Enter below, THEN, while you ' + $combo.ToLower() + ', plug the cable into a REAR USB 2.0 port.')
    Write-Host ' 4. Release the buttons when the tool says the device was detected.'
    [void](Read-Host 'Press Enter to start the tool')
}
function Complete-MtkConnect($r) {
    $g = Invoke-Mtk -MtkArgs @('printgpt') -TimeoutSec 90
    $script:MtkInfo = $r.Info
    if ($g.Info.Chip) { $script:MtkInfo = $g.Info }
    $names = @($g.Info.Partitions | ForEach-Object { $_.Name })
    if ($names.Count -eq 0) { $names = @($r.Info.Partitions | ForEach-Object { $_.Name }) }
    $script:Gpt = $names
    Write-Log ('Connected. Chip: ' + $script:MtkInfo.Chip + '  HW code: ' + $script:MtkInfo.HwCode + '  partitions read: ' + $script:Gpt.Count) 'Green'
    if ($script:Gpt.Count -eq 0) { Request-ManualGpt }
}
function Connect-Mtk([int]$Max = 6) {
    for ($n = 1; $n -le $Max; $n++) {
        Request-Reconnect $n
        $r = Invoke-Mtk -MtkArgs @('payload') -TimeoutSec 120
        if ($r.Info.Detected) { Complete-MtkConnect $r; return $true }
        Show-MtkProblems $r.Info
        if ($n -lt $Max -and -not (Confirm-YN 'Not detected. Try again with the next button combination?')) { break }
    }
    return (Connect-MtkManual)
}
function Ensure-MtkLink {
    $r = Invoke-Mtk -MtkArgs @('payload') -TimeoutSec 30 -Quiet
    if ($r.Info.Detected) { return $true }
    return (Connect-Mtk)
}
function Resolve-GptNames([string]$p) {
    if (-not $script:Gpt -or $script:Gpt.Count -eq 0) { return @($p) }
    $map = @{}
    foreach ($n in $script:Gpt) { $map[$n.ToLower()] = $n }
    $pl = $p.ToLower()
    if ($map.ContainsKey($pl)) { return @($map[$pl]) }
    $r = @()
    foreach ($s in '_a', '_b') { if ($map.ContainsKey($pl + $s)) { $r += $map[$pl + $s] } }
    return $r
}
function New-Stage([string[]]$Names) {
    if (Test-Path -LiteralPath $StageDir) { Remove-Item -LiteralPath $StageDir -Recurse -Force -ErrorAction SilentlyContinue }
    New-Item -ItemType Directory -Force -Path $StageDir | Out-Null
    $staged = @(); $skipped = @()
    foreach ($p in $Names) {
        if ($ProtectedParts -contains $p.ToLower()) { $skipped += ($p + ' (protected)'); continue }
        $f = Get-FwFile $p
        if (-not $f) { $skipped += ($p + ' (no image in firmware folder)'); continue }
        if (Test-Sparse $f.FullName) { $skipped += ($p + ' (sparse image: flash it with fastboot, or convert to raw)'); continue }
        $targets = @(Resolve-GptNames $p)
        if ($targets.Count -eq 0) { $skipped += ($p + ' (not in this phone''s partition table)'); continue }
        foreach ($t in $targets) {
            $dst = Join-Path $StageDir ($t + '.bin')
            try { New-Item -ItemType HardLink -Path $dst -Value $f.FullName -ErrorAction Stop | Out-Null } catch { Copy-Item -LiteralPath $f.FullName -Destination $dst -Force }
            $staged += [pscustomobject]@{ Part = $t; File = $f.FullName; Dst = $dst }
        }
    }
    return [pscustomobject]@{ Staged = $staged; Skipped = $skipped }
}
function Write-Parts([string[]]$Names) {
    $st = New-Stage $Names
    foreach ($s in $st.Skipped) { Write-Log ('  skipped: ' + $s) 'DarkYellow' }
    if (@($st.Staged).Count -eq 0) {
        Write-Log 'No matching firmware images were found for this level.' 'Yellow'
        $core = @($Names | Where-Object { @('boot', 'recovery', 'vbmeta', 'lk') -contains $_.ToLower() })
        if ($core.Count -eq 0) { $core = @($Names | Select-Object -First 5) }
        if ((Request-ManualImages $core) -gt 0) { $st = New-Stage $Names }
        if (@($st.Staged).Count -eq 0) { Write-Log 'Nothing to write for this level.' 'Yellow'; return $false }
    }
    Write-Log ('Writing ' + @($st.Staged).Count + ' partition(s): ' + ((@($st.Staged) | ForEach-Object { $_.Part }) -join ', '))
    if (-not (Ensure-MtkLink)) { return $false }
    $r = Invoke-Mtk -MtkArgs @('wl', $StageDir)
    $ok = ([regex]::Matches($r.Text, 'Successfully wrote|Wrote')).Count
    if ($ok -ge @($st.Staged).Count) { Write-Log ('Directory write reported ' + $ok + ' successes.') 'Green'; return $true }
    Write-Log 'Directory write did not confirm every partition; retrying one by one.' 'Yellow'
    foreach ($s in $st.Staged) {
        if (-not (Ensure-MtkLink)) { return $false }
        $r = Invoke-Mtk -MtkArgs @('w', $s.Part, $s.File)
        if ($r.Text -match 'Successfully wrote|Wrote') { Write-Log ('  ' + $s.Part + ' OK') 'Green' } else { Write-Log ('  ' + $s.Part + ' no success message (see log)') 'Yellow' }
    }
    return $true
}
function Backup-Critical {
    Write-Head 'Backup before writing'
    $have = @()
    foreach ($c in $CriticalParts) { foreach ($g in $script:Gpt) { if ($g.ToLower() -eq $c) { $have += $g } } }
    if ($have.Count -eq 0) { Write-Log 'Partition table not readable, so IMEI/calibration backup could not be listed. This script never writes those partitions, but a manual backup is advised.' 'Yellow'; return }
    $files = @($have | ForEach-Object { Join-Path $BackupDir ($_ + '.bin') })
    if (-not (Ensure-MtkLink)) { return }
    [void](Invoke-Mtk -MtkArgs @('r', ($have -join ','), ($files -join ',')))
    $okc = @($files | Where-Object { (Test-Path -LiteralPath $_) -and ((Get-Item -LiteralPath $_).Length -gt 0) }).Count
    Write-Log ('Backed up ' + $okc + ' of ' + $have.Count + ' critical partitions to ' + $BackupDir) 'Green'
    if (Confirm-YN 'Also dump all partitions except userdata (slow, needs several GB)?') {
        if (Ensure-MtkLink) { [void](Invoke-Mtk -MtkArgs @('rl', '--skip', 'userdata', (Join-Path $BackupDir 'full'))) }
    }
}
function Test-AfterReset([string]$Label) {
    Write-Log 'Sending reset. Unplug the USB cable, wait 10 s, then power on if it does not start by itself.' 'Cyan'
    [void](Invoke-Mtk -MtkArgs @('reset') -TimeoutSec 60)
    return (Wait-Boot 150)
}
function Repair-Mtk($st) {
    Write-Head 'MediaTek (BROM / preloader) branch'
    if (-not (Assert-MtkReady)) { Write-Log 'mtkclient/Python are not available, so this branch cannot run.' 'Red'; Offer-ManualFallback 'tools missing'; return }
    if ($st.Mode -eq 'NONE' -or $st.Mode -eq 'USB-FAILED') {
        Write-Log 'Before connecting: use a short data cable in a rear USB 2.0 port (not front panel, hub or USB 3.0). If the phone keeps rebooting by itself, let the battery run flat, then connect.' 'Yellow'
    }
    if ($script:DiagOnly) {
        Write-Log 'Diagnose-only: the tool will connect and read information, but write nothing.' 'Cyan'
        if (Connect-Mtk) { Show-MtkSummary } else { Write-Log 'Could not connect to the phone in BROM/preloader mode.' 'Red' }
        return
    }
    if (-not (Connect-Mtk)) {
        Write-Log 'Could not reach the phone in BROM/preloader mode. Remaining options: let the battery drain fully and retry; try Linux (live USB) with mtkclient; a service centre with authenticated tools or test-point access.' 'Red'
        return
    }
    Show-MtkSummary
    Backup-Critical

    Write-Head 'Level 1: reset only'
    if (Test-AfterReset 'reset') { Write-Log 'Fixed by reset.' 'Green'; return }

    if (@($script:FwIndex.Keys).Count -eq 0 -and $script:FwMap.Count -eq 0) { Request-ManualFirmware }
    Show-FwCompat
    if (-not (Confirm-Typed 'Continue with firmware writes using this folder?')) { return }

    Write-Head 'Level 2: restore boot chain (boot, recovery, vbmeta, dtbo, lk, logo ...)'
    if (Write-Parts $BootChain) {
        if (Test-AfterReset 'bootchain') { Write-Log 'Fixed by boot-chain restore.' 'Green'; return }
    }

    Write-Head 'Level 3: erase userdata/metadata + boot chain'
    if (Confirm-Typed 'This ERASES all personal data on the phone.') {
        $wipe = @()
        foreach ($w in 'metadata', 'userdata', 'md_udc', 'cache') { if ($script:Gpt.Count -eq 0 -or ($script:Gpt | Where-Object { $_.ToLower() -eq $w })) { $wipe += $w } }
        if (Ensure-MtkLink) { [void](Invoke-Mtk -MtkArgs @('e', ($wipe -join ','))) }
        if (Write-Parts $BootChain) {
            if (Test-AfterReset 'wipe') { Write-Log 'Fixed by wipe + boot chain.' 'Green'; return }
        }
    }

    Write-Head 'Level 4: full restore of every matching raw partition'
    if (Confirm-Typed 'Full restore writes every partition that has a matching image (never IMEI/calibration/preloader).') {
        $names = @()
        if ($script:Gpt.Count -gt 0) {
            foreach ($g in $script:Gpt) { $base = $g -replace '_[ab]$', ''; if ((Get-FwFile $g) -or (Get-FwFile $base)) { $names += $base } }
            $names = @($names | Select-Object -Unique)
        } else { $names = @($script:FwMap.Keys) }
        if (Write-Parts $names) {
            if (Test-AfterReset 'full') { Write-Log 'Fixed by full restore.' 'Green'; return }
        }
    }

    Write-Head 'Level 5: advanced (bootloader seccfg)'
    if (Confirm-Typed 'Unlock bootloader state via seccfg. May factory-reset and can affect warranty/anti-rollback.' 'UNLOCK') {
        if (Ensure-MtkLink) { [void](Invoke-Mtk -MtkArgs @('da', 'seccfg', 'unlock')) }
        if (Test-AfterReset 'seccfg') { Write-Log 'Fixed after seccfg unlock.' 'Green'; return }
    }
    Write-Log 'All automatic levels were tried without a confirmed boot.' 'Red'
    Write-Log 'Likely remaining causes: wrong or anti-rollback firmware, damaged preloader, failing eMMC, or battery/PMIC fault. Keep the session folder (logs + backup) for a technician.' 'Yellow'
    Offer-ManualFallback 'mtk'
}
function Show-MtkSummary {
    Write-Head 'Device summary (BROM does not expose the model name)'
    $i = $script:MtkInfo
    Write-Log ('Chip     : ' + $i.Chip + '  (HW code ' + $i.HwCode + ')')
    Write-Log ('Mode     : ' + $(if ($i.Brom) { 'BROM' } else { 'Preloader/other' }))
    Write-Log ('Security : SBC=' + $i.Sbc + ' SLA=' + $i.Sla + ' DAA=' + $i.Daa + ' protected=' + $i.Protected)
    Write-Log ('Partitions read: ' + $script:Gpt.Count)
}
function Show-FwCompat {
    Write-Head 'Firmware compatibility check'
    if ($script:FwPlatform) { Write-Log ('Firmware platform (scatter): ' + $script:FwPlatform + '   Phone chip: ' + $script:MtkInfo.Chip) }
    if ($script:Gpt.Count -gt 0) {
        $cand = @($script:Gpt | Where-Object { $ProtectedParts -notcontains $_.ToLower() })
        $hit = @($cand | Where-Object { Get-FwFile ($_ -replace '_[ab]$', '') })
        $pct = 0
        if ($cand.Count -gt 0) { $pct = [math]::Round(100 * $hit.Count / $cand.Count) }
        Write-Log ('Partitions on the phone with a matching firmware image: ' + $hit.Count + ' of ' + $cand.Count + ' (' + $pct + '%)')
        if ($pct -lt 50) { Write-Log 'LOW match: this firmware is probably for a different model.' 'Red' } else { Write-Log 'Match looks plausible.' 'Green' }
    } else { Write-Log 'Partition table unavailable; cannot score the match. Check the folder name/platform yourself.' 'Yellow' }
}

# ------------------------------------------------------------ manual failsafes
function Split-CommandLine([string]$Line) {
    $out = @()
    if (-not $Line) { return @() }
    foreach ($m in [regex]::Matches($Line, '(?:[^\s"]+|"[^"]*")+')) { $out += ($m.Value -replace '"', '') }
    return $out
}
function Request-ManualTool([string]$Label, [string]$Exe) {
    while ($true) {
        $p = (Read-Host ('Enter the full path to ' + $Exe + ' (or its folder) for ' + $Label + ' [Enter = skip]')).Trim().Trim('"')
        if ($p -eq '') { return $null }
        $r = Resolve-Tool $p $Exe
        if ($r -and (Test-Path -LiteralPath $r -PathType Leaf)) { return $r }
        Write-Host '  Not found there, try again.' -ForegroundColor Yellow
    }
}
function Request-ManualMtk {
    while ($true) {
        $p = (Read-Host 'Enter the folder that contains mtk.py [Enter = skip]').Trim().Trim('"')
        if ($p -eq '') { return $null }
        if (Test-Path -LiteralPath $p -PathType Container) { $e = Find-MtkEntry $p; if ($e) { return $e } }
        elseif (Test-Path -LiteralPath $p -PathType Leaf) { return $p }
        Write-Host '  mtk.py not found there, try again.' -ForegroundColor Yellow
    }
}
function Request-ManualPython {
    while ($true) {
        $p = (Read-Host 'Python 3 was not found. Enter the full path to python.exe [Enter = skip]').Trim().Trim('"')
        if ($p -eq '') { return $false }
        if (Test-Path -LiteralPath $p -PathType Leaf) {
            $r = Invoke-Proc -Exe $p -ArgList @('--version') -TimeoutSec 20
            if ($r.Code -eq 0 -and $r.Text -match 'Python 3\.\d+') { $script:Python = $p; $script:PyPre = @(); return $true }
        }
        Write-Host '  That is not a working Python 3, try again.' -ForegroundColor Yellow
    }
}
function Request-ManualFirmware {
    Write-Log 'No usable firmware images were found automatically.' 'Yellow'
    while ($true) {
        $p = (Read-Host 'Enter another firmware folder to scan [Enter = skip; you can still give single image files later]').Trim().Trim('"')
        if ($p -eq '') { return }
        if (Test-Path -LiteralPath $p -PathType Container) {
            Initialize-Firmware $p
            if (@($script:FwIndex.Keys).Count -gt 0) { return }
        } else { Write-Host '  Folder not found, try again.' -ForegroundColor Yellow }
    }
}
function Request-ManualImages([string[]]$Parts) {
    $added = 0
    Write-Host ''
    Write-Host 'Manual failsafe: give the image file for each partition, or press Enter to skip it.' -ForegroundColor Yellow
    foreach ($p in $Parts) {
        if (Get-FwFile $p) { continue }
        while ($true) {
            $f = (Read-Host ("Image file for partition '" + $p + "'")).Trim().Trim('"')
            if ($f -eq '') { break }
            if (Test-Path -LiteralPath $f -PathType Leaf) { $script:FwMap[$p.ToLower()] = Get-Item -LiteralPath $f; $added++; break }
            Write-Host '  File not found, try again (or Enter to skip).' -ForegroundColor Yellow
        }
    }
    return $added
}
function Request-ManualGpt {
    Write-Log 'The partition table could not be read automatically.' 'Yellow'
    $a = (Read-Host 'Enter the partition names separated by commas, or press Enter to use standard names').Trim()
    if ($a -ne '') { $script:Gpt = @($a -split '[,\s]+' | Where-Object { $_ -ne '' }) }
}
function Assert-MtkReady {
    if (-not $script:MtkEntry) {
        $e = Request-ManualMtk
        if ($e) { $script:MtkEntry = $e; $script:MtkDir = Split-Path -Parent $e }
    }
    if ($script:MtkEntry -and -not $script:Python) {
        if (-not (Initialize-Python) -and -not (Request-ManualPython)) { return $false }
    }
    return [bool]$script:MtkEntry
}
function Connect-MtkManual {
    while ($true) {
        Write-Head 'Manual failsafe: the phone was not reached automatically'
        Write-Host '  [1] Retry with extra mtkclient arguments that I type, for example:'
        Write-Host '        --preloader="C:\path\preloader.bin"   --loader="C:\path\loader.bin"   --vid=0x0e8d --pid=0x0003   --debugmode'
        Write-Host '  [2] Re-check now (I changed the cable/port or connected the phone myself)'
        Write-Host '  [3] Open the manual command console'
        Write-Host '  [Q] Give up on BROM/preloader'
        $c = (Read-Host 'Choose').Trim().ToUpper()
        if ($c -eq 'Q') { return $false }
        if ($c -eq '3') { Invoke-ManualConsole; continue }
        if ($c -eq '1') {
            $script:MtkExtra = @(Split-CommandLine (Read-Host 'Extra arguments (Enter = none)'))
            Write-Log ('Extra mtkclient arguments in use: ' + ($script:MtkExtra -join ' ')) 'Cyan'
            Request-Reconnect 1
        }
        if ($c -eq '1' -or $c -eq '2') {
            $r = Invoke-Mtk -MtkArgs @('payload') -TimeoutSec 120
            if ($r.Info.Detected) { Complete-MtkConnect $r; return $true }
            Show-MtkProblems $r.Info
        }
    }
}
function Read-Timeout([int]$Default) {
    $t = (Read-Host ('Timeout in seconds [Enter = ' + $Default + ']')).Trim()
    if ($t -match '^\d+$') { return [int]$t }
    return $Default
}
function Invoke-ManualConsole {
    Write-Head 'Manual command console'
    Write-Host 'Type only the arguments (not the program name). Everything is logged.' -ForegroundColor DarkGray
    :console while ($true) {
        Write-Host ''
        Write-Host '  [1] adb        e.g.  devices -l   |   reboot bootloader'
        Write-Host '  [2] fastboot   e.g.  getvar all   |   flash boot "C:\fw\boot.img"'
        Write-Host '  [3] mtkclient  e.g.  printgpt   |   r boot boot.bin   |   reset'
        Write-Host '  [4] write ONE partition with mtkclient (partition name + image file)'
        Write-Host '  [5] flash ONE partition with fastboot (partition name + image file)'
        Write-Host '  [B] Back'
        switch ((Read-Host 'Choose').Trim().ToUpper()) {
            '1' {
                if (-not $script:Adb) { $script:Adb = Request-ManualTool 'adb' 'adb.exe' }
                if ($script:Adb) {
                    $a = @(Split-CommandLine (Read-Host 'adb arguments'))
                    if ($a.Count -gt 0) { $r = Invoke-Proc -Exe $script:Adb -ArgList $a -TimeoutSec (Read-Timeout 120) -Live; Add-Content -Path $LogFile -Value $r.Text -Encoding UTF8 }
                } else { Write-Host 'adb is not available.' -ForegroundColor Yellow }
            }
            '2' {
                if (-not $script:Fastboot) { $script:Fastboot = Request-ManualTool 'fastboot' 'fastboot.exe' }
                if ($script:Fastboot) {
                    $a = @(Split-CommandLine (Read-Host 'fastboot arguments'))
                    if ($a.Count -gt 0) { $r = Invoke-Proc -Exe $script:Fastboot -ArgList $a -TimeoutSec (Read-Timeout 300) -Live; Add-Content -Path $LogFile -Value $r.Text -Encoding UTF8 }
                } else { Write-Host 'fastboot is not available.' -ForegroundColor Yellow }
            }
            '3' {
                if (Assert-MtkReady) {
                    $a = @(Split-CommandLine (Read-Host 'mtkclient arguments'))
                    if ($a.Count -gt 0) { [void](Invoke-Mtk -MtkArgs $a -TimeoutSec (Read-Timeout 300)) }
                } else { Write-Host 'mtkclient/Python are not available.' -ForegroundColor Yellow }
            }
            '4' {
                if (Assert-MtkReady) {
                    $part = (Read-Host 'Partition name (for example boot)').Trim()
                    $f = (Read-Host 'Image file path').Trim().Trim('"')
                    if ($part -ne '' -and (Test-Path -LiteralPath $f -PathType Leaf)) {
                        $go = $true
                        if ($ProtectedParts -contains $part.ToLower()) { $go = Confirm-Typed ("'" + $part + "' holds IMEI/calibration/security data. Overwriting it can permanently damage the phone.") 'DANGER' }
                        if ($go -and (Ensure-MtkLink)) { [void](Invoke-Mtk -MtkArgs @('w', $part, $f)) }
                    } else { Write-Host 'Need a partition name and an existing file.' -ForegroundColor Yellow }
                } else { Write-Host 'mtkclient/Python are not available.' -ForegroundColor Yellow }
            }
            '5' {
                if (-not $script:Fastboot) { $script:Fastboot = Request-ManualTool 'fastboot' 'fastboot.exe' }
                if ($script:Fastboot) {
                    $part = (Read-Host 'Partition name (for example boot)').Trim()
                    $f = (Read-Host 'Image file path').Trim().Trim('"')
                    if ($part -ne '' -and (Test-Path -LiteralPath $f -PathType Leaf)) { [void](Invoke-Fb @('flash', $part, $f)) }
                    else { Write-Host 'Need a partition name and an existing file.' -ForegroundColor Yellow }
                } else { Write-Host 'fastboot is not available.' -ForegroundColor Yellow }
            }
            'B' { break console }
        }
    }
}
function Offer-ManualFallback([string]$Context) {
    Write-Host ''
    Write-Log ('Automatic repair could not finish (' + $Context + ').') 'Yellow'
    if (Confirm-YN 'Open the manual failsafe console to enter commands, files or partition names yourself?') { Invoke-ManualConsole }
}
function Read-ManualState {
    Write-Head 'Manual failsafe: no phone detected automatically'
    Write-Host '  [1] Re-detect (restarts the ADB server first)'
    Write-Host '  [2] Go straight to mtkclient (guided BROM/preloader connection)'
    Write-Host '  [3] Open the manual command console'
    Write-Host '  [Q] Stop this attempt'
    switch ((Read-Host 'Choose').Trim().ToUpper()) {
        '1' { return 'RETRY' }
        '2' { return 'MTK' }
        '3' { return 'CONSOLE' }
        default { return 'QUIT' }
    }
}

# ------------------------------------------------------------ main flow
function Start-Repair {
    try {
        $st = Get-DeviceState
        Show-State $st
        while ($st.Mode -eq 'NONE' -or $st.Mode -eq 'USB-FAILED') {
            $c = Read-ManualState
            if ($c -eq 'RETRY') {
                if ($script:Adb) { [void](Invoke-Proc -Exe $script:Adb -ArgList @('kill-server') -TimeoutSec 15) }
                Start-Sleep -Seconds 2
                $st = Get-DeviceState
                Show-State $st
                continue
            }
            if ($c -eq 'CONSOLE') { Invoke-ManualConsole; continue }
            if ($c -eq 'MTK') { break }
            return
        }
        switch ($st.Mode) {
            'ADB' { Repair-Adb $st }
            'FASTBOOT' { Repair-Fastboot $st }
            default { Repair-Mtk $st }
        }
        Write-Head 'Finished'
        Write-Log ('Session folder (log + backups): ' + $SessionDir) 'Cyan'
    } catch {
        Write-Log ('Unexpected script error: ' + $_.Exception.Message) 'Red'
        Write-Log ([string]$_.ScriptStackTrace) 'DarkGray'
        Offer-ManualFallback 'script error'
    }
}

Clear-Host
Write-Host ''
Write-Host '  MTK AutoRepair' -ForegroundColor Cyan
Write-Host '  Safest fix first - backups before writes - IMEI/calibration never overwritten' -ForegroundColor DarkGray
Write-Host '  No tool can guarantee a fix for hardware faults or locked/authenticated devices.' -ForegroundColor DarkGray
Initialize-Paths

# labeled loop so 'Q' really exits (break inside switch only leaves the switch)
:menu while ($true) {
    Write-Host ''
    Write-Host '  [1] Auto diagnose and repair'
    Write-Host '  [2] Diagnose only (no changes to the phone)'
    Write-Host '  [3] Change tool / firmware paths and rescan'
    Write-Host '  [4] Open session folder'
    Write-Host '  [5] Manual command console (adb / fastboot / mtkclient, your own files and partitions)'
    Write-Host '  [Q] Quit'
    switch ((Read-Host 'Choose').Trim().ToUpper()) {
        '1' { $script:DiagOnly = $false; Start-Repair }
        '2' { $script:DiagOnly = $true; Start-Repair }
        '3' { Initialize-Paths }
        '4' { Start-Process explorer.exe $SessionDir }
        '5' { Invoke-ManualConsole }
        'Q' { break menu }
    }
}
