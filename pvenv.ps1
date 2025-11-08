# ==============================
# PVenv - PowerShell-native Python venv manager
# Version : v0.6.4
# Author  : APIron-lab
# License : MIT
# ==============================

if (-not $Global:PVenv) { $Global:PVenv = @{} }

$Script:PVENV_CONFIG = @{
    MaxLogSizeBytes = 10MB
    DefaultProfile  = "balanced"
    ValidProfiles   = @("balanced","lite","max","custom")
    ValidPriorities = @("BelowNormal","Normal","AboveNormal","High")
    ValidAutoModes  = @("auto","prompt","off")
    ConfigCacheTtlS = 300
}

function PVenv-GlobalConfigPath { Join-Path $HOME ".pvenv.json" }
function PVenv-ProjectConfigPath { param([string]$Root) if (-not $Root) { $Root = (Get-Location).Path }; Join-Path $Root ".pvenv.profile.json" }
function PVenv-ProjectAdoptPath  { param([string]$Root) if (-not $Root) { $Root = (Get-Location).Path }; Join-Path $Root ".pvenv.adopt.json" }

function PVenv-LoadJsonFile { param([string]$Path) if (-not (Test-Path -LiteralPath $Path)) { return $null }; try { (Get-Content -LiteralPath $Path -Raw -Encoding UTF8) | ConvertFrom-Json } catch { $null } }
function PVenv-SaveJsonFile { param([string]$Path, [hashtable]$Data) $json = ($Data | ConvertTo-Json -Depth 8); Set-Content -LiteralPath $Path -Value $json -Encoding UTF8 }

function PVenv-CoerceHashtable {
    param($Obj)
    if ($Obj -is [hashtable]) { return $Obj }
    if ($null -eq $Obj) { return @{} }
    $h = @{}
    foreach ($p in $Obj.PSObject.Properties) { $h[$p.Name] = $p.Value }
    return $h
}

function Write-PVLog {
    param([string]$Message,[string]$Level="INFO")
    if (-not $env:PYENV_LOG) { return }
    try {
        $path  = $env:PYENV_LOG
        if (Test-Path -LiteralPath $path) {
            $size = (Get-Item -LiteralPath $path).Length
            if ($size -gt [int64]$Script:PVENV_CONFIG.MaxLogSizeBytes) {
                $old = "$path.old"
                try { Remove-Item -LiteralPath $old -Force -ErrorAction SilentlyContinue } catch {}
                Rename-Item -LiteralPath $path -NewName $old -Force
            }
        }
        $stamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        $line  = "[{0}] [{1}] {2}" -f $stamp,$Level.ToUpper(),$Message
        Add-Content -LiteralPath $path -Value $line -Encoding UTF8
    } catch { }
}

if (-not $Global:PVenv.__ConfigCache) {
    $Global:PVenv.__ConfigCache = @{
        LastCheck = $null
        Config    = $null
        TTL       = [int]$Script:PVENV_CONFIG.ConfigCacheTtlS
    }
}
function PVenv-LoadGlobalConfig {
    $now   = Get-Date
    $cache = $Global:PVenv.__ConfigCache
    if ($cache.LastCheck -and $cache.Config -and (($now - $cache.LastCheck).TotalSeconds -lt $cache.TTL)) {
        return $cache.Config
    }
    $p   = PVenv-GlobalConfigPath
    $cfg = PVenv-LoadJsonFile $p
    if (-not $cfg) { $cfg = @{} } else { $cfg = PVenv-CoerceHashtable $cfg }
    $cache.LastCheck = $now
    $cache.Config    = $cfg
    return $cfg
}
function PVenv-SaveGlobalConfig {
    param([hashtable]$Cfg)
    if (-not $Cfg) { $Cfg = @{} }
    PVenv-SaveJsonFile -Path (PVenv-GlobalConfigPath) -Data $Cfg
    $Global:PVenv.__ConfigCache.LastCheck = $null
    $Global:PVenv.__ConfigCache.Config    = $null
}

function PVenv-DetectPython {
    $python = (Get-Command python -ErrorAction SilentlyContinue)
    if ($python) {
        try {
            $ver = & python --version 2>&1
            if ($ver -match "Python\s+3") { return "python" }
        } catch { }
    }
    $py = (Get-Command py -ErrorAction SilentlyContinue)
    if ($py) {
        try {
            $ver = & py -3 --version 2>&1
            if ($ver -match "Python\s+3") { return "py -3" }
        } catch { }
    }
    return $null
}
function PVenv-ProjectPath { param([Parameter(Mandatory=$true)][string]$Name) (Join-Path $Global:PVenv.ProjectsRoot $Name) }
function PVenv-HasVenv    { param([string]$Path) (Test-Path (Join-Path $Path ".venv\Scripts\Activate.ps1")) }
function PVenv-IsJunction { param([string]$Path) try { ((Get-Item -LiteralPath $Path -ErrorAction Stop).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 } catch { $false } }
function PVenv-GetFullPath { param([string]$Path) try { [System.IO.Path]::GetFullPath($Path) } catch { $Path } }
function PVenv-IsSubPath {
    param([string]$Parent,[string]$Child)
    try {
        $pa = (PVenv-GetFullPath $Parent).TrimEnd('\')
        $ch = (PVenv-GetFullPath $Child ).TrimEnd('\')
        return $ch.StartsWith($pa,[StringComparison]::OrdinalIgnoreCase)
    } catch { return $false }
}
function PVenv-ResolveProjectPath {
    param([string]$Name, [switch]$AllowCurrent)
    $root = $Global:PVenv.ProjectsRoot
    if ($Name) { return (Join-Path $root $Name) }
    if ($AllowCurrent) {
        $activeRoot = PVenv-ActiveProjectRoot
        if ($activeRoot) { return $activeRoot }
        $cwd = (Get-Location).Path
        if ($cwd -like (($root.TrimEnd('\')) + "\*")) { return $cwd }
    }
    return $null
}

function PVenv-ProjectNameFromVenv {
    if (-not $env:VIRTUAL_ENV) { return $null }
    try {
        $venvDir = (PVenv-GetFullPath $env:VIRTUAL_ENV)
        $projDir = Split-Path -Parent $venvDir
        if (Test-Path (Join-Path $projDir ".venv")) { return (Split-Path $projDir -Leaf) }
        $root = $Global:PVenv.ProjectsRoot
        if (Test-Path $root) {
            $dirs = Get-ChildItem -Path $root -Directory -ErrorAction SilentlyContinue
            foreach ($d in $dirs) {
                $ad = PVenv-LoadJsonFile (PVenv-ProjectAdoptPath -Root $d.FullName)
                if ($ad) {
                    $h = PVenv-CoerceHashtable $ad
                    $mode = "$($h.mode)".ToLowerInvariant()
                    $target = $h.target
                    if ($mode -eq "shim" -and $target) {
                        try {
                            if ((PVenv-GetFullPath $target) -eq $venvDir) { return $d.Name }
                        } catch { }
                    }
                }
            }
        }
        return $null
    } catch { return $null }
}

function PVenv-ActiveProjectRoot {
    try {
        if ($env:VIRTUAL_ENV -and (Test-Path $env:VIRTUAL_ENV)) {
            $venvPath = PVenv-GetFullPath $env:VIRTUAL_ENV
            $projPath = Split-Path -Parent $venvPath
            if (Test-Path (Join-Path $projPath ".venv")) { return (PVenv-GetFullPath $projPath) }
            $root = $Global:PVenv.ProjectsRoot
            if (Test-Path $root) {
                foreach ($d in (Get-ChildItem -Path $root -Directory -ErrorAction SilentlyContinue)) {
                    $ad = PVenv-LoadJsonFile (PVenv-ProjectAdoptPath -Root $d.FullName)
                    if ($ad) {
                        $h = PVenv-CoerceHashtable $ad
                        $mode = "$($h.mode)".ToLowerInvariant()
                        $target = $h.target
                        if ($mode -eq "shim" -and $target) {
                            try { if ((PVenv-GetFullPath $target) -eq $venvPath) { return (PVenv-GetFullPath $d.FullName) } } catch { }
                        }
                    }
                }
            }
        }
        return $null
    } catch { return $null }
}

function PVenv-GetAutoActivation {
    if ($Global:PVenv.AutoAct) { return $Global:PVenv.AutoAct }
    $g = PVenv-LoadGlobalConfig
    $mode = $g.auto_activation
    if (-not $mode) { $mode = "auto" }
    $Global:PVenv.AutoAct = "$mode".ToLowerInvariant()
    return $Global:PVenv.AutoAct
}
function Set-AutoActivation {
    [CmdletBinding()]
    param([string]$Mode)
    if (-not $Mode) { Write-Host ("[INFO] Auto-activation mode = {0}" -f (PVenv-GetAutoActivation)); return }
    $val = "$Mode".ToLowerInvariant()
    if ($val -eq "prompt-clear") {
        if ($Global:PVenv.__AutoCache) { $Global:PVenv.__AutoCache.Clear() }
        Write-Host "[OK] Cleared prompt cache for this session."
        return
    }
    if ($Script:PVENV_CONFIG.ValidAutoModes -notcontains $val) {
        Write-Host "[ERR] Invalid mode. Use: auto | prompt | off | prompt-clear"
        return
    }
    $g = PVenv-LoadGlobalConfig
    $g = PVenv-CoerceHashtable $g
    $g.auto_activation = $val
    PVenv-SaveGlobalConfig -Cfg $g
    $Global:PVenv.AutoAct = $val
    Write-Host ("[OK] Auto-activation mode = {0}" -f $val)
}
Set-Alias peauto Set-AutoActivation -Scope Global -Option AllScope -Force

function PVenv-DefaultProfile { @{ profile=$Script:PVENV_CONFIG.DefaultProfile; cpu_cores=$null; priority="Normal"; threads=$null } }
function PVenv-ResolveProfile {
    param([string]$ProjectRoot)
    $projCfg = $null
    if ($ProjectRoot) { $projCfg = PVenv-LoadJsonFile (PVenv-ProjectConfigPath -Root $ProjectRoot) }
    else { $projCfg = PVenv-LoadJsonFile (PVenv-ProjectConfigPath -Root (Get-Location).Path) }
    if ($projCfg) { return (PVenv-CoerceHashtable $projCfg) }
    $globCfg = PVenv-LoadGlobalConfig
    if ($globCfg) {
        $mapped = PVenv-DefaultProfile
        foreach ($k in @("profile","cpu_cores","priority","threads")) {
            if ($globCfg.ContainsKey($k)) { $mapped[$k] = $globCfg[$k] }
        }
        return $mapped
    }
    PVenv-DefaultProfile
}
function PVenv-ApplyResourceProfile {
    param([string]$ProjectRoot)
    $cfg   = PVenv-ResolveProfile -ProjectRoot $ProjectRoot
    $total = [Environment]::ProcessorCount
    $preset = "$($cfg.profile)".ToLowerInvariant()
    if ($Script:PVENV_CONFIG.ValidProfiles -notcontains $preset) { $preset = $Script:PVENV_CONFIG.DefaultProfile }
    $prio   = $cfg.priority
    if ($prio -and ($Script:PVENV_CONFIG.ValidPriorities -notcontains $prio)) { $prio = "Normal" }
    $cores = $cfg.cpu_cores
    if ($cores) {
        $cores = [int][Math]::Max(1,[Math]::Min([int]$cores,$total))
        if ($cores -ne $cfg.cpu_cores) {
            Write-Host ("[WARN] Adjusted cpu_cores from {0} to {1}" -f $cfg.cpu_cores,$cores) -ForegroundColor Yellow
        }
    }
    $th = $cfg.threads
    if ($th) {
        $maxThreads = $total
        if ($cores) { $maxThreads = $cores }
        $th = [int][Math]::Max(1,[Math]::Min([int]$th,$maxThreads))
        if ($th -ne $cfg.threads) {
            Write-Host ("[WARN] Adjusted threads from {0} to {1}" -f $cfg.threads,$th) -ForegroundColor Yellow
        }
    }
    switch ($preset) {
        "lite" {
            if (-not $cores) { $cores = [Math]::Max(1,[Math]::Floor($total/2)) }
            if (-not $prio)  { $prio  = "BelowNormal" }
            if (-not $th)    { $th    = $cores }
        }
        "max" {
            if (-not $cores) { $cores = $total }
            if (-not $prio)  { $prio  = "High" }
            if (-not $th)    { $th    = $cores }
        }
        default {
            if (-not $prio) { $prio = "Normal" }
        }
    }
    if ($cores) {
        $cores = [int][Math]::Max(1,[Math]::Min($cores,$total))
        $mask  = ([bigint]1 -shl $cores) - 1
        try { (Get-Process -Id $PID).ProcessorAffinity = [IntPtr]::new([int64]$mask) } catch { Write-PVLog "Set affinity failed: $($_.Exception.Message)" "WARN" }
    }
    if ($prio) {
        try { (Get-Process -Id $PID).PriorityClass = $prio } catch { Write-PVLog "Set priority failed: $($_.Exception.Message)" "WARN" }
    }
    if ($th) {
        $th = [int][Math]::Max(1,$th)
        $env:OMP_NUM_THREADS      = "$th"
        $env:MKL_NUM_THREADS      = "$th"
        $env:OPENBLAS_NUM_THREADS = "$th"
        $env:NUMEXPR_NUM_THREADS  = "$th"
    }
    $coresStr = "-"
    if ($null -ne $cores) { $coresStr = "$cores" }
    $thStr = "-"
    if ($null -ne $th) { $thStr = "$th" }
    $ann = "profile={0}, cpu_cores={1}, priority={2}, threads={3}" -f $preset, $coresStr, $prio, $thStr
    Write-Host ("[PVenv] ResourceProfile -> {0}" -f $ann) -ForegroundColor $Global:PVenv.BodyColor
    Write-PVLog "ApplyResourceProfile: $ann"
}

function Set-ProjectsRoot {
    [CmdletBinding()] param([Parameter(Mandatory=$true)][string]$Path)
    try {
        if (-not (Test-Path -LiteralPath $Path)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null }
        $Global:PVenv.ProjectsRoot = (PVenv-GetFullPath $Path)
        Write-Host ("[OK] ProjectsRoot = {0}" -f $Global:PVenv.ProjectsRoot)
        Write-PVLog "Set-ProjectsRoot: $($Global:PVenv.ProjectsRoot)"
    } catch {
        Write-Host "[ERR] Set-ProjectsRoot failed: $($_.Exception.Message)"
        Write-PVLog "Set-ProjectsRoot failed: $($_.Exception.Message)" "ERROR"
    }
}
function Show-ProjectTree {
    [CmdletBinding()] param()
    $root = $Global:PVenv.ProjectsRoot
    if (-not (Test-Path -LiteralPath $root)) { Write-Host "[WARN] ProjectsRoot not found: $root"; return }
    Write-Host "[A]=active (cyan), [V]=venv (green), [J]=junction (magenta), [S]=shim (yellow), [-]=none (darkyellow)" -ForegroundColor $Global:PVenv.BodyColor
    Write-Host ("{0}\" -f $root) -ForegroundColor $Global:PVenv.BodyColor
    $dirs = Get-ChildItem -Path $root -Directory -ErrorAction SilentlyContinue | Sort-Object Name
    if (-not $dirs) { Write-Host " (empty)"; return }
    $activeRoot = PVenv-ActiveProjectRoot
    $activeRootResolved = $null
    if ($activeRoot -and (Test-Path $activeRoot)) { $activeRootResolved = (PVenv-GetFullPath $activeRoot) }
    foreach ($d in $dirs) {
        $thisResolved = PVenv-GetFullPath $d.FullName
        $isActive = ($activeRootResolved -and ($thisResolved -eq $activeRootResolved))
        $venvDir = Join-Path $d.FullName ".venv"
        $hasVenv = Test-Path (Join-Path $venvDir "Scripts\Activate.ps1")
        $isJunc  = $false
        if (Test-Path $venvDir) { $isJunc = PVenv-IsJunction -Path $venvDir }
        $ad = PVenv-LoadJsonFile (PVenv-ProjectAdoptPath -Root $d.FullName)
        $isShim = $false
        if ($ad) {
            $h = PVenv-CoerceHashtable $ad
            $mode = "$($h.mode)".ToLowerInvariant()
            if ($mode -eq "shim") { $isShim = $true }
        }
        if ($isActive)      { Write-Host ("|-- [A] {0}" -f $d.Name) -ForegroundColor Cyan }
        elseif ($hasVenv)   { Write-Host ("|-- [V] {0} (.venv)" -f $d.Name) -ForegroundColor Green }
        elseif ($isJunc)    { Write-Host ("|-- [J] {0} (.venv@junction)" -f $d.Name) -ForegroundColor Magenta }
        elseif ($isShim)    { Write-Host ("|-- [S] {0} (shim)" -f $d.Name) -ForegroundColor Yellow }
        else                { Write-Host ("|-- [-] {0}" -f $d.Name) -ForegroundColor DarkYellow }
    }
}
function PyEnv-Help {
@"
PVenv Commands
  New-PyEnv            (alias: npe)
  New-PyEnvCustom      (alias: npec)
  Show-ProjectTree     (alias: spt)
  Show-ProjectInfo     (alias: spi)
  Set-ProjectsRoot     (alias: spr)
  Set-ResourceProfile  (alias: srp)
  Show-ResourceProfile (alias: grp)
  Exit-PyEnv           (alias: peexit)
  Set-AutoActivation   (alias: peauto)
  Activate-PyEnvHere   (alias: aenv)
  Remove-PyEnv         (alias: rpe)
  Adopt-ExternalVenv   (alias: peadopt)
Notes
  - Auto activation respects modes: auto | prompt | off
  - Threads apply to OMP/MKL/OPENBLAS/NUMEXPR
  - Set $env:PYENV_LOG to enable logging
"@ | Write-Output
}
Set-Alias spt    Show-ProjectTree     -Scope Global -Option AllScope -Force
Set-Alias spr    Set-ProjectsRoot     -Scope Global -Option AllScope -Force
Set-Alias pehelp PyEnv-Help           -Scope Global -Option AllScope -Force

function Set-ResourceProfile {
    [CmdletBinding()]
    param(
        [ValidateSet("Global","Project")][string]$Scope = "Project",
        [ValidateSet("balanced","lite","max","custom")][string]$Profile = "balanced",
        [int]$CpuCores,
        [ValidateSet("BelowNormal","Normal","AboveNormal","High")][string]$Priority,
        [int]$Threads
    )
    $cfg = @{ profile=$Profile; cpu_cores=$null; priority=$null; threads=$null }
    if ($PSBoundParameters.ContainsKey("CpuCores")) { $cfg.cpu_cores = $CpuCores }
    if ($PSBoundParameters.ContainsKey("Priority")) { $cfg.priority  = $Priority  }
    if ($PSBoundParameters.ContainsKey("Threads"))  { $cfg.threads   = $Threads   }
    if ($Scope -eq "Global") {
        $g = PVenv-LoadGlobalConfig
        foreach ($k in @("profile","cpu_cores","priority","threads")) { $g[$k] = $cfg[$k] }
        PVenv-SaveGlobalConfig -Cfg $g
        $path = PVenv-GlobalConfigPath
    } else {
        $path = PVenv-ProjectConfigPath -Root (Get-Location).Path
        PVenv-SaveJsonFile -Path $path -Data $cfg
    }
    Write-Host ("[OK] Saved {0} profile at: {1}" -f $Scope, $path)
    $total = [Environment]::ProcessorCount
    Write-Host ""; Write-Host ("Ranges: CpuCores=1..{0}, Priority={{BelowNormal|Normal|AboveNormal|High}}, Threads=1..CpuCores" -f $total)
    Write-Host "Note: Threads apply to OMP/MKL/OPENBLAS/NUMEXPR."
}
function Show-ResourceProfile {
    [CmdletBinding()] param()
    $cwd = (Get-Location).Path
    $proj = PVenv-LoadJsonFile (PVenv-ProjectConfigPath -Root $cwd)
    $glob = PVenv-LoadGlobalConfig
    $eff  = PVenv-ResolveProfile -ProjectRoot $cwd
    Write-Host "[Project] .pvenv.profile.json"
    if ($proj) { (PVenv-CoerceHashtable $proj) | ConvertTo-Json -Depth 8 | Write-Output } else { Write-Host "(none)" }
    Write-Host ""; Write-Host "[Global]  $HOME\.pvenv.json"
    if ($glob) { $glob | ConvertTo-Json -Depth 8 | Write-Output } else { Write-Host "(none)" }
    Write-Host ""; Write-Host "[Effective]"
    $eff | ConvertTo-Json -Depth 8 | Write-Output
    $total = [Environment]::ProcessorCount
    Write-Host ""; Write-Host ("Ranges: CpuCores=1..{0}, Priority={{BelowNormal|Normal|AboveNormal|High}}, Threads=1..CpuCores" -f $total)
}
Set-Alias srp Set-ResourceProfile  -Scope Global -Option AllScope -Force
Set-Alias grp Show-ResourceProfile -Scope Global -Option AllScope -Force

function New-PyEnv {
    [CmdletBinding()] param([string]$Name)
    if (-not $Name) { $Name = Read-Host "Enter project name" }
    if (-not $Name) { Write-Host "[STOP] Cancelled."; return }
    if ($Name -match '[^\w\-]') { Write-Host "[WARN] Use letters/digits/underscore/hyphen." }
    $projectPath = PVenv-ProjectPath -Name $Name
    if (Test-Path $projectPath) {
        Write-Host "Project '$Name' exists. Choose: [R]euse  [A]lternate  [T]imestamp  [C]ancel"
        $choice = (Read-Host "Choice").ToUpperInvariant()
        switch ($choice) { "R" { } "A" { $alt = Read-Host "Enter another name"; if (-not $alt) { Write-Host "[STOP] Cancelled."; return }; $projectPath = PVenv-ProjectPath -Name $alt } "T" { $stamp = (Get-Date).ToString("yyyyMMdd_HHmmss"); $projectPath = PVenv-ProjectPath -Name ($Name + "_" + $stamp) } default { Write-Host "[STOP] Cancelled."; return } }
    }
    try {
        if (-not (Test-Path $projectPath)) { New-Item -ItemType Directory -Path $projectPath -Force | Out-Null }
        Set-Location $projectPath
        $py = PVenv-DetectPython
        if (-not $py) { Write-Host "[ERR] Python 3 not found."; Write-PVLog "python not found" "ERROR"; return }
        Write-Host ("[DO] Creating venv: {0}" -f (Join-Path $projectPath ".venv"))
        & $py -m venv ".venv"
        if ($LASTEXITCODE -ne 0) { Write-Host "[ERR] venv creation failed."; Write-PVLog "venv create failed at $projectPath" "ERROR"; return }
        if (Test-Path ".\requirements.txt") {
            Write-Host "[DO] requirements.txt -> pip install"
            & ".\.venv\Scripts\python.exe" -m pip install -r ".\requirements.txt"
        }
        Write-Host ("[OK] Completed: {0}" -f $projectPath)
        Write-PVLog "New-PyEnv created at $projectPath"
        if (PVenv-GetAutoActivation -ne "off") { . ".\.venv\Scripts\Activate.ps1"; PVenv-ApplyResourceProfile -ProjectRoot $projectPath }
        Show-ProjectTree
    } catch {
        Write-Host "[ERR] New-PyEnv failed: $($_.Exception.Message)"
        Write-PVLog "New-PyEnv failed: $($_.Exception.Message)" "ERROR"
    }
}
Set-Alias npe New-PyEnv -Scope Global -Option AllScope -Force

function New-PyEnvCustom {
    [CmdletBinding()] param([string]$Name)
    if (-not $Name) { $Name = Read-Host "Enter project name" }
    if (-not $Name) { Write-Host "[STOP] Cancelled."; return }
    if ($Name -match '[^\w\-]') { Write-Host "[WARN] Use letters/digits/underscore/hyphen." }
    $projectPath = PVenv-ProjectPath -Name $Name
    if (Test-Path $projectPath) {
        Write-Host "Project '$Name' exists. Choose: [R]euse  [A]lternate  [T]imestamp  [C]ancel"
        $choice = (Read-Host "Choice").ToUpperInvariant()
        switch ($choice) { "R" { } "A" { $alt = Read-Host "Enter another name"; if (-not $alt) { Write-Host "[STOP] Cancelled."; return }; $projectPath = PVenv-ProjectPath -Name $alt } "T" { $stamp = (Get-Date).ToString("yyyyMMdd_HHmmss"); $projectPath = PVenv-ProjectPath -Name ($Name + "_" + $stamp) } default { Write-Host "[STOP] Cancelled."; return } }
    }
    $total = [Environment]::ProcessorCount
    Write-Host ("Resource profile setup (ranges: CpuCores=1..{0}, Priority={{BelowNormal|Normal|AboveNormal|High}}, Threads=1..CpuCores)" -f $total)
    $preset = (Read-Host "Preset [balanced|lite|max|custom] (default=custom)"); if (-not $preset) { $preset = "custom" }; $preset = $preset.ToLowerInvariant()
    if ($Script:PVENV_CONFIG.ValidProfiles -notcontains $preset) { $preset = "custom" }
    $cores=$null; $prio=$null; $th=$null
    if ($preset -eq "custom") {
        $cin = Read-Host ("CpuCores (1..{0}, blank=skip)" -f $total); if ($cin) { $cores = [int]$cin }
        $pin = Read-Host "Priority [BelowNormal|Normal|AboveNormal|High] (blank=Normal)"; if ($pin) { $prio = $pin }
        $tin = Read-Host "Threads (1..CpuCores, blank=skip)"; if ($tin) { $th = [int]$tin }
    }
    try {
        if (-not (Test-Path $projectPath)) { New-Item -ItemType Directory -Path $projectPath -Force | Out-Null }
        Set-Location $projectPath
        $py = PVenv-DetectPython
        if (-not $py) { Write-Host "[ERR] Python 3 not found."; Write-PVLog "python not found" "ERROR"; return }
        $cfg=@{ profile=$preset; cpu_cores=$cores; priority=$prio; threads=$th }
        PVenv-SaveJsonFile -Path (PVenv-ProjectConfigPath -Root $projectPath) -Data $cfg
        Write-Host ("[OK] Saved project profile: {0}" -f (PVenv-ProjectConfigPath -Root $projectPath))
        Write-Host ("[DO] Creating venv: {0}" -f (Join-Path $projectPath ".venv"))
        & $py -m venv ".venv"
        if ($LASTEXITCODE -ne 0) { Write-Host "[ERR] venv creation failed."; Write-PVLog "venv create failed at $projectPath" "ERROR"; return }
        if (Test-Path ".\requirements.txt") {
            Write-Host "[DO] requirements.txt -> pip install"
            & ".\.venv\Scripts\python.exe" -m pip install -r ".\requirements.txt"
        }
        Write-Host ("[OK] Completed: {0}" -f $projectPath)
        Write-PVLog "New-PyEnvCustom created at $projectPath"
        if (PVenv-GetAutoActivation -ne "off") { . ".\.venv\Scripts\Activate.ps1"; PVenv-ApplyResourceProfile -ProjectRoot $projectPath }
        Show-ProjectTree
    } catch {
        Write-Host "[ERR] New-PyEnvCustom failed: $($_.Exception.Message)"
        Write-PVLog "New-PyEnvCustom failed: $($_.Exception.Message)" "ERROR"
    }
}
Set-Alias npec New-PyEnvCustom -Scope Global -Option AllScope -Force

function Show-ProjectInfo {
    [CmdletBinding()] param([string]$Name)
    $root = $Global:PVenv.ProjectsRoot
    $projPath = $null
    if ($Name) {
        $projPath = Join-Path $root $Name
    } else {
        $activeRoot = PVenv-ActiveProjectRoot
        if ($activeRoot) { $projPath = $activeRoot }
        else {
            $cwd = (Get-Location).Path
            if ($cwd -like ($root + "\*")) { $projPath = $cwd } else { Write-Host "[INFO] Not in a project. Specify -Name."; return }
        }
    }
    if (-not (Test-Path $projPath)) { Write-Host ("[WARN] Project path not found: {0}" -f $projPath); return }
    $pname   = Split-Path $projPath -Leaf
    $venvDir = (Join-Path $projPath ".venv")
    $act     = $false
    $ar = PVenv-ActiveProjectRoot
    if ($ar -and (Test-Path $ar)) { if ((PVenv-GetFullPath $ar) -eq (PVenv-GetFullPath $projPath)) { $act = $true } }
    $hasVenv = Test-Path (Join-Path $venvDir "Scripts\Activate.ps1")
    $isJunc  = $false
    if (Test-Path $venvDir) { $isJunc = PVenv-IsJunction -Path $venvDir }
    $adopt = PVenv-LoadJsonFile (PVenv-ProjectAdoptPath -Root $projPath)
    Write-Host "ProjectInfo"
    Write-Host ("  Name     : {0}" -f $pname)
    Write-Host ("  Path     : {0}" -f $projPath)
    Write-Host ("  .venv    : {0}" -f $(if ($hasVenv) { "exists" } else { "none" }))
    Write-Host ("  Active   : {0}" -f $(if ($act) { "YES" } else { "NO" }))
    Write-Host ("  Junction : {0}" -f $(if ($isJunc) { "YES" } else { "NO" }))
    Write-Host  "  Adopt    : " -NoNewline
    if ($adopt) { ($adopt | ConvertTo-Json -Depth 8) | Write-Output } else { Write-Host "(none)" }
    $projCfg = PVenv-LoadJsonFile (PVenv-ProjectConfigPath -Root $projPath)
    $globCfg = PVenv-LoadGlobalConfig
    $eff     = PVenv-ResolveProfile -ProjectRoot $projPath
    Write-Host "  Profile (project)"
    if ($projCfg) { (PVenv-CoerceHashtable $projCfg) | ConvertTo-Json -Depth 8 | Write-Output } else { Write-Host "    (none)" }
    Write-Host "  Profile (global)"
    if ($globCfg) { $globCfg | ConvertTo-Json -Depth 8 | Write-Output } else { Write-Host "    (none)" }
    Write-Host "  Profile (effective)"
    $eff | ConvertTo-Json -Depth 8 | Write-Output
    $total = [Environment]::ProcessorCount
    Write-Host ("  Ranges   : CpuCores=1..{0}, Priority={{BelowNormal|Normal|AboveNormal|High}}, Threads=1..CpuCores" -f $total)
}
Set-Alias spi Show-ProjectInfo -Scope Global -Option AllScope -Force

function PVenv-ActivateFrom {
    param([string]$VenvRoot,[string]$ProjectRootForProfile)
    $act = Join-Path $VenvRoot "Scripts\Activate.ps1"
    if (Test-Path $act) { . $act; PVenv-ApplyResourceProfile -ProjectRoot $ProjectRootForProfile; Write-PVLog "Activated: $VenvRoot" }
}
# ---------- Location hook (auto-activate/deactivate) ----------
function PVenv-SetLocation {
    param(
        [Parameter(ValueFromRemainingArguments = $true)]
        [object[]] $Arguments
    )

    if ($null -ne $Arguments -and $Arguments.Count -gt 0) {
        __PVenv_OrigSL @Arguments
    } else {
        __PVenv_OrigSL
    }

    try {
        $path = Get-Location
        $activate = Join-Path $path ".venv\Scripts\Activate.ps1"
        $hasVenv = Test-Path $activate
        if ($hasVenv) {
            $mode = PVenv-GetAutoActivation
            if ($mode -ne "off") {
                if ($env:VIRTUAL_ENV -and (Test-Path $env:VIRTUAL_ENV)) {
                    $currVenv = (Resolve-Path $env:VIRTUAL_ENV).Path
                    $newVenv  = (Resolve-Path (Join-Path $path ".venv")).Path
                    if ($currVenv -eq $newVenv) { return }
                }
                if ($mode -eq "prompt") {
                    if (-not $Global:PVenv.__AutoCache) { $Global:PVenv.__AutoCache = @{} }
                    $key = (Resolve-Path $path).Path
                    if ($Global:PVenv.__AutoCache.ContainsKey($key)) {
                        if (-not $Global:PVenv.__AutoCache[$key]) { return }
                    } else {
                        $ans = (Read-Host "Activate venv here? [Y]es / [N]o / [A]lways / [S]kip (default=Y)").ToUpperInvariant()
                        if (-not $ans) { $ans = "Y" }
                        switch ($ans) {
                            "N" { return }
                            "S" { $Global:PVenv.__AutoCache[$key] = $false; return }
                            "A" { $Global:PVenv.__AutoCache[$key] = $true }
                            default { } # Y
                        }
                    }
                }
                . $activate
                PVenv-ApplyResourceProfile -ProjectRoot $path
                Write-PVLog "Activated: $activate (mode=$(PVenv-GetAutoActivation))"
            }
        } else {
            if ($env:VIRTUAL_ENV) {
                try {
                    $deactFn = Get-Command deactivate -CommandType Function -ErrorAction SilentlyContinue
                    if ($deactFn) {
                        deactivate
                    } else {
                        $deact = Join-Path $env:VIRTUAL_ENV "Scripts\deactivate.ps1"
                        if (Test-Path $deact) { . $deact }
                    }
                } catch { }
                $env:VIRTUAL_ENV = $null
                Write-PVLog "Deactivated"
            }
        }
    } catch {
        Write-Host "[WARN] Auto switch error: $($_.Exception.Message)"
        Write-PVLog "Auto switch error: $($_.Exception.Message)" "WARN"
    }
}

Set-Alias __PVenv_OrigSL Microsoft.PowerShell.Management\Set-Location -Scope Global -Option AllScope -Force
Set-Item  function:\Set-Location ${function:PVenv-SetLocation} -Options AllScope -Force
Set-Alias cd    PVenv-SetLocation -Scope Global -Option AllScope -Force
Set-Alias chdir PVenv-SetLocation -Scope Global -Option AllScope -Force
Set-Alias sl    PVenv-SetLocation -Scope Global -Option AllScope -Force

function PVenv-Refresh {
    try {
        $mode = PVenv-GetAutoActivation
        if ($mode -eq "off") { return }
        $path = (Get-Location).Path
        $act  = Join-Path $path ".venv\Scripts\Activate.ps1"
        if (Test-Path $act) {
            if ($env:VIRTUAL_ENV) {
                $curr = PVenv-GetFullPath $env:VIRTUAL_ENV
                $new  = PVenv-GetFullPath (Join-Path $path ".venv")
                if ($curr -eq $new) { return }
            }
            . $act; PVenv-ApplyResourceProfile -ProjectRoot $path; Write-PVLog "Activated by Refresh: $act"
        } else {
            $ad = PVenv-LoadJsonFile (PVenv-ProjectAdoptPath -Root $path)
            if ($ad) {
                $h=PVenv-CoerceHashtable $ad; $modeAd="$($h.mode)".ToLowerInvariant(); $target=$h.target
                if ($modeAd -eq "shim" -and $target -and (Test-Path (Join-Path $target "Scripts\Activate.ps1"))) {
                    . (Join-Path $target "Scripts\Activate.ps1"); PVenv-ApplyResourceProfile -ProjectRoot $path; Write-PVLog "Activated by Refresh (shim): $target"; return
                }
            }
            if ($env:VIRTUAL_ENV) {
                try {
                    $deactFn = Get-Command deactivate -CommandType Function -ErrorAction SilentlyContinue
                    if ($deactFn) { deactivate } else { $deact = Join-Path $env:VIRTUAL_ENV "Scripts\deactivate.ps1"; if (Test-Path $deact) { . $deact } }
                } catch { }
                $env:VIRTUAL_ENV = $null
                Write-PVLog "Deactivated by Refresh"
            }
        }
    } catch { Write-Host "[WARN] Refresh error: $($_.Exception.Message)"; Write-PVLog "Refresh error: $($_.Exception.Message)" "WARN" }
}
Set-Alias pref PVenv-Refresh -Scope Global -Option AllScope -Force

function Activate-PyEnvHere {
    [CmdletBinding()] param()
    $path = (Get-Location).Path
    $act  = Join-Path $path ".venv\Scripts\Activate.ps1"
    if (Test-Path $act) {
        . $act; PVenv-ApplyResourceProfile -ProjectRoot $path; Write-PVLog "Activated by aenv: $act"
    } else {
        $ad = PVenv-LoadJsonFile (PVenv-ProjectAdoptPath -Root $path)
        if ($ad) {
            $h=PVenv-CoerceHashtable $ad; $mode="$($h.mode)".ToLowerInvariant(); $target=$h.target
            if ($mode -eq "shim" -and $target -and (Test-Path (Join-Path $target "Scripts\Activate.ps1"))) {
                . (Join-Path $target "Scripts\Activate.ps1"); PVenv-ApplyResourceProfile -ProjectRoot $path; Write-PVLog "Activated by aenv (shim): $target"; return
            }
        }
        Write-Host "[PVenv] .venv not found here." -ForegroundColor DarkYellow
    }
}
Set-Alias aenv Activate-PyEnvHere -Scope Global -Option AllScope -Force

function Exit-PyEnv {
    [CmdletBinding()] param()
    if ($env:VIRTUAL_ENV) {
        try {
            $deactFn = Get-Command deactivate -CommandType Function -ErrorAction SilentlyContinue
            if ($deactFn) { deactivate }
            else {
                $deact = Join-Path $env:VIRTUAL_ENV "Scripts\deactivate.ps1"
                if (Test-Path $deact) { . $deact } else { Write-Host "[PVenv] No deactivate found." -ForegroundColor DarkYellow }
            }
            $env:VIRTUAL_ENV = $null
            Write-Host "[PVenv] Virtual environment deactivated." -ForegroundColor Yellow
            Write-PVLog "Manual deactivate by peexit"
        } catch {
            Write-Host "[PVenv] Error during deactivate: $($_.Exception.Message)"
            Write-PVLog "Error during peexit: $($_.Exception.Message)" "WARN"
        }
    } else {
        Write-Host "[PVenv] Not currently in a virtual environment." -ForegroundColor DarkGray
    }
}
Set-Alias peexit Exit-PyEnv -Scope Global -Option AllScope -Force

function Remove-PyEnv {
    [CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact="High")]
    param([string]$Name,[switch]$VenvOnly,[switch]$Force)
    $root   = $Global:PVenv.ProjectsRoot
    $target = $null
    if ($Name) { $target = Join-Path $root $Name }
    else {
        $cwd = (Get-Location).Path
        if ($cwd -like ($root + "\*")) { $target = $cwd } else { Write-Host "[ERR] Not under ProjectsRoot and -Name not specified." -ForegroundColor Red; return }
    }
    if (-not (Test-Path $target)) { Write-Host ("[WARN] Target not found: {0}" -f $target); return }
    if (-not (PVenv-IsSubPath -Parent $root -Child $target)) { Write-Host "[ERR] Refusing to delete outside ProjectsRoot." -ForegroundColor Red; return }
    $projName = (Split-Path $target -Leaf)
    $venvPath = Join-Path $target ".venv"
    $activeName = PVenv-ProjectNameFromVenv
    if ($activeName -and ($activeName -eq $projName)) { try { Exit-PyEnv | Out-Null } catch { } }
    if ($VenvOnly) {
        if (-not (Test-Path $venvPath)) { Write-Host "[INFO] .venv not found; nothing to remove."; return }
        $title = "[CONFIRM] Remove only .venv of '{0}' ?" -f $projName
        if ($Force -or $PSCmdlet.ShouldProcess($venvPath,"Remove .venv")) {
            if (-not $Force) { $ans=(Read-Host "$title [Y/N] (default=N)").ToUpperInvariant(); if ($ans -ne "Y") { Write-Host "[STOP] Cancelled."; return } }
            try { Remove-Item -LiteralPath $venvPath -Recurse -Force -ErrorAction Stop; Write-Host ("[OK] Removed: {0}" -f $venvPath); Write-PVLog "Removed .venv: $venvPath" }
            catch { Write-Host ("[ERR] Failed to remove .venv: {0}" -f $_.Exception.Message) }
        }
    } else {
        $title = "[CONFIRM] Remove ENTIRE project '{0}' ?" -f $projName
        if ($Force -or $PSCmdlet.ShouldProcess($target,"Remove project dir")) {
            if (-not $Force) { $ans=(Read-Host "$title [type the project name to confirm]").Trim(); if ($ans -ne $projName) { Write-Host "[STOP] Cancelled (name mismatch)."; return } }
            try { Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction Stop; Write-Host ("[OK] Removed project: {0}" -f $target); Write-PVLog "Removed project: $target" }
            catch { Write-Host ("[ERR] Failed to remove project: {0}" -f $_.Exception.Message) }
        }
    }
}
Set-Alias rpe Remove-PyEnv -Scope Global -Option AllScope -Force

function Adopt-ExternalVenv {
    [CmdletBinding(SupportsShouldProcess=$true)]
    param(
        [ValidateSet("junction","move","shim")][string]$Mode,
        [Parameter(Mandatory=$true)][string]$TargetVenvPath
    )
    $cwd      = (Get-Location).Path
    $venvHere = Join-Path $cwd ".venv"
    $adoptPath = PVenv-ProjectAdoptPath -Root $cwd
    $actScript = Join-Path $TargetVenvPath "Scripts\Activate.ps1"
    if (-not (Test-Path $actScript)) { Write-Host "[ERR] Target does not look like a venv (Activate.ps1 missing)."; return }
    switch ($Mode) {
        "junction" {
            if (Test-Path $venvHere) { Write-Host "[ERR] .venv already exists here."; return }
            $parent = Split-Path $venvHere -Parent; if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
            $venvHereEsc = ($venvHere -replace '"','\"')
            $targetEsc   = ((PVenv-GetFullPath $TargetVenvPath) -replace '"','\"')
            cmd /c "mklink /J `"$venvHereEsc`" `"$targetEsc`"" | Out-Null
            if (-not (Test-Path (Join-Path $venvHere "Scripts\Activate.ps1"))) { Write-Host "[ERR] Failed to create junction."; return }
            if (Test-Path $adoptPath) { Remove-Item -LiteralPath $adoptPath -Force -ErrorAction SilentlyContinue }
            Write-Host "[OK] Junction created: .venv -> $TargetVenvPath"
        }
        "move" {
            if (Test-Path $venvHere) { Write-Host "[ERR] .venv already exists here."; return }
            Move-Item -LiteralPath $TargetVenvPath -Destination $venvHere -Force
            Write-Host "[OK] Moved venv into project: $venvHere"
            if (Test-Path $adoptPath) { Remove-Item -LiteralPath $adoptPath -Force -ErrorAction SilentlyContinue }
        }
        "shim" {
            if (Test-Path $venvHere) { Write-Host "[ERR] .venv exists. Remove it first or use junction."; return }
            $data = @{ mode="shim"; target=(PVenv-GetFullPath $TargetVenvPath) }
            PVenv-SaveJsonFile -Path $adoptPath -Data $data
            Write-Host "[OK] Shim recorded at: $adoptPath"
        }
    }
}
Set-Alias peadopt Adopt-ExternalVenv -Scope Global -Option AllScope -Force

function global:prompt {
    $proj = PVenv-ProjectNameFromVenv
    $dir  = (Get-Location).Path
    if ($proj) {
        Write-Host "PS [" -NoNewline -ForegroundColor $Global:PVenv.BodyColor
        Write-Host "$proj" -NoNewline -ForegroundColor $Global:PVenv.PromptColor
        Write-Host "] " -NoNewline -ForegroundColor $Global:PVenv.BodyColor
        Write-Host "$dir" -NoNewline -ForegroundColor $Global:PVenv.BodyColor
        return "> "
    } else {
        return "PS $dir> "
    }
}

function Initialize-PVenv {
    if (-not $Global:PVenv.ProjectsRoot) { $Global:PVenv.ProjectsRoot = "C:\Projects" }
    if (-not (Test-Path $Global:PVenv.ProjectsRoot)) { New-Item -ItemType Directory -Path $Global:PVenv.ProjectsRoot -Force | Out-Null }
    $Global:PVenv.BodyColor   = 'Gray'
    $Global:PVenv.PromptColor = 'Cyan'
    $null = PVenv-GetAutoActivation
    Set-Alias __PVenv_OrigSL Microsoft.PowerShell.Management\Set-Location -Scope Global -Option AllScope -Force
    Set-Item  function:\Set-Location ${function:PVenv-SetLocation} -Options AllScope -Force
    Set-Alias cd    PVenv-SetLocation -Scope Global -Option AllScope -Force
    Set-Alias chdir PVenv-SetLocation -Scope Global -Option AllScope -Force
    Set-Alias sl    PVenv-SetLocation -Scope Global -Option AllScope -Force
    if ($env:PVENV_QUIET -ne '1') {
        Write-Host ("[PVenv v0.6.4] ProjectsRoot: {0}" -f $Global:PVenv.ProjectsRoot) -ForegroundColor $Global:PVenv.BodyColor
    }
}
Initialize-PVenv | Out-Null
