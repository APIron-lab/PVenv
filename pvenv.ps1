# ==============================
# PVenv - PowerShell-native Python venv manager
# Version : v0.6.8a
# Author  : APIron-lab
# License : MIT
# ==============================

# region: Safe initialization -------------------------------------------

if (-not (Get-Variable -Name PVenv -Scope Global -ErrorAction SilentlyContinue)) {
    $Global:PVenv = [ordered]@{}
}

# Utility for key check
function PVenv-HasKey {
    param([System.Collections.Specialized.OrderedDictionary]$Dict, [string]$Key)
    try { return $Dict.Contains($Key) } catch { return $false }
}

# Symbols
if (-not (PVenv-HasKey $Global:PVenv 'Symbols')) {
    $Global:PVenv.Symbols = [ordered]@{
        Active = '[A]'
        Venv   = '[V]'
        None   = '[-]'
        Error  = '[ERR]'
        Ok     = '[OK]'
        Info   = '[..]'
        Adopt  = '[ADPT]'
    }
}

# Colors (foreground only)
if (-not (PVenv-HasKey $Global:PVenv 'Colors')) {
    $Global:PVenv.Colors = [ordered]@{
        Foreground = [ordered]@{
            Normal = 'Gray'
            Muted  = 'DarkGray'
            Good   = 'Green'
            Error  = 'Red'
            Accent = 'Cyan'
            Title  = 'White'
        }
    }
}

# Auto activation ON by default
if (-not (PVenv-HasKey $Global:PVenv 'Auto')) {
    $Global:PVenv.Auto = 'auto'
}

# Active project
if (-not (PVenv-HasKey $Global:PVenv 'ActiveProject')) {
    $Global:PVenv.ActiveProject = ''
}

# Default ProjectsRoot
function PVenv-DefaultProjectsRoot {
    try {
        $dir = Split-Path -Parent $MyInvocation.MyCommand.Path
        if ($dir -and (Test-Path $dir)) { return (Resolve-Path $dir).Path }
    } catch {}
    return (Get-Location).Path
}

if (-not (PVenv-HasKey $Global:PVenv 'ProjectsRoot')) {
    $Global:PVenv.ProjectsRoot = PVenv-DefaultProjectsRoot
}

# region: Helpers -------------------------------------------------------

function PVenv-GetFullPath {
    param([string]$Path)
    try { return (Resolve-Path $Path -ErrorAction Stop).Path } catch {
        try { return [System.IO.Path]::GetFullPath($Path) } catch { return $Path }
    }
}

function PVenv-NormalizePath {
    param([string]$Path)
    $full = PVenv-GetFullPath $Path
    if ($full) { return $full.TrimEnd('\','/') } else { return $Path }
}

function PVenv-IsUnder {
    param([string]$Root, [string]$Path)
    $nRoot = PVenv-NormalizePath $Root
    $nPath = PVenv-NormalizePath $Path
    if (-not $nRoot.EndsWith('\')) { $nRoot += '\' }
    return $nPath.StartsWith($nRoot, [System.StringComparison]::OrdinalIgnoreCase)
}

function PVenv-SaveJsonFile {
    param([string]$Path, [object]$Data)
    try {
        $json = $Data | ConvertTo-Json -Depth 8
        [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding $false))
        return $true
    } catch { return $false }
}

function PVenv-LoadJsonFile {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $null }
    try { return (Get-Content $Path -Raw) | ConvertFrom-Json } catch { return $null }
}

function PVenv-Deactivate {
    try { if (Get-Command deactivate -ErrorAction SilentlyContinue) { deactivate } } catch {}
    Remove-Item Env:\VIRTUAL_ENV -ErrorAction SilentlyContinue
}

function PVenv-NearestVenv {
    param([string]$Start = (Get-Location).Path)
    $cur = PVenv-GetFullPath $Start
    while ($true) {
        $venv = Join-Path $cur '.venv'
        $act  = Join-Path $venv 'Scripts\Activate.ps1'
        if (Test-Path $act) { return $act }
        $p = Split-Path $cur -Parent
        if ($p -eq $cur) { break }
        $cur = $p
    }
    return $null
}

# region: Prompt ---------------------------------------------------------
if (-not (Get-Command -Name PVenv_original_prompt -ErrorAction SilentlyContinue)) {
    Copy-Item Function:\prompt Function:\PVenv_original_prompt -Force -ErrorAction SilentlyContinue
}

function prompt {
    $prefix = ''
    if ($env:VIRTUAL_ENV -and -not $env:VIRTUAL_ENV_DISABLE_PROMPT) {
        $name = Split-Path $env:VIRTUAL_ENV -Leaf
        $prefix = "($name) "
    }
    return ($prefix + (& PVenv_original_prompt))
}

# region: Core commands -------------------------------------------------

function peauto {
    param([ValidateSet('auto','off')][string]$Mode)
    if (-not $PSBoundParameters.ContainsKey('Mode')) {
        Write-Host "Auto mode: $($Global:PVenv.Auto)"
        return
    }
    $Global:PVenv.Auto = $Mode
    Write-Host "$($Global:PVenv.Symbols.Ok) Auto = $Mode" -ForegroundColor $Global:PVenv.Colors.Foreground.Accent
    if ($Mode -eq 'auto') { PVenv-Refresh }
}

function Set-ProjectsRoot {
    param([string]$Path)
    $root = PVenv-NormalizePath $Path
    if (-not (Test-Path $root)) { New-Item -ItemType Directory -Path $root -Force | Out-Null }
    $Global:PVenv.ProjectsRoot = (Resolve-Path $root).Path
    Write-Host "$($Global:PVenv.Symbols.Ok) ProjectsRoot = $root" -ForegroundColor $Global:PVenv.Colors.Foreground.Accent
}

function PVenv-Refresh {
    param([string]$At = (Get-Location).Path)
    $here = PVenv-GetFullPath $At
    $root = $Global:PVenv.ProjectsRoot

    if (-not (PVenv-IsUnder $root $here)) {
        if ($env:VIRTUAL_ENV) {
            PVenv-Deactivate
            $Global:PVenv.ActiveProject = ''
            Write-Host "$($Global:PVenv.Symbols.Info) Left ProjectsRoot, deactivating." -ForegroundColor $Global:PVenv.Colors.Foreground.Muted
        }
        return
    }

    $act = PVenv-NearestVenv -Start $here
    if ($act) {
        $venvDir = Split-Path (Split-Path $act -Parent) -Parent
        if ($env:VIRTUAL_ENV -and (PVenv-NormalizePath $env:VIRTUAL_ENV) -eq (PVenv-NormalizePath $venvDir)) { return }

        PVenv-Deactivate
        . $act
        $Global:PVenv.ActiveProject = Split-Path $venvDir -Leaf
        Write-Host "$($Global:PVenv.Symbols.Active) Activated .venv" -ForegroundColor $Global:PVenv.Colors.Foreground.Good
    }
}

# Hook Set-Location
if (-not (Get-Command Set-Location -CommandType Function -ErrorAction SilentlyContinue)) {
    function Set-Location {
        param([string]$Path)
        Microsoft.PowerShell.Management\Set-Location $Path
        if ($Global:PVenv.Auto -eq 'auto') { PVenv-Refresh }
    }
}

# --- Safe alias registration (avoid conflict with built-in cd/sl) ---
if (-not (Get-Alias cd -ErrorAction SilentlyContinue)) {
    Set-Alias cd Set-Location -Scope Global -Force
}
if (-not (Get-Alias sl -ErrorAction SilentlyContinue)) {
    Set-Alias sl Set-Location -Scope Global -Force
}
if (-not (Get-Alias chdir -ErrorAction SilentlyContinue)) {
    Set-Alias chdir Set-Location -Scope Global -Force
}

# region: Display -------------------------------------------------------

function spt {
    $root = $Global:PVenv.ProjectsRoot
    if (-not (Test-Path $root)) {
        Write-Host "$($Global:PVenv.Symbols.Error) ProjectsRoot not found: $root" -ForegroundColor $Global:PVenv.Colors.Foreground.Error
        return
    }

    Write-Host ("{0} Projects under: {1}" -f $Global:PVenv.Symbols.Info, $root)
    $dirs = Get-ChildItem $root -Directory -ErrorAction SilentlyContinue | Sort-Object Name
    if (-not $dirs -or $dirs.Count -eq 0) {
        Write-Host "No projects." -ForegroundColor $Global:PVenv.Colors.Foreground.Muted
        return
    }

    foreach ($d in $dirs) {
        $projName  = $d.Name
        $venvHere  = Join-Path $d.FullName '.venv'
        $actScript = Join-Path $venvHere 'Scripts\Activate.ps1'
        $hasLocal  = Test-Path $actScript

        $mark = $Global:PVenv.Symbols.None
        $fg   = $Global:PVenv.Colors.Foreground.Muted

        if ($Global:PVenv.ActiveProject -and ($Global:PVenv.ActiveProject -ieq $projName)) {
            $mark = $Global:PVenv.Symbols.Active
            $fg   = $Global:PVenv.Colors.Foreground.Good
        } elseif ($hasLocal) {
            $mark = $Global:PVenv.Symbols.Venv
            $fg   = $Global:PVenv.Colors.Foreground.Accent
        }

        Write-Host ("{0}  {1}" -f $mark, $projName) -ForegroundColor $fg
    }
}

function spi {
    param([string]$Path)
    $here = if ($Path) { $Path } else { (Get-Location).Path }
    $proj = Split-Path $here -Leaf
    $venv = Join-Path $here '.venv'
    Write-Host "Project  : $proj" -ForegroundColor $Global:PVenv.Colors.Foreground.Title
    Write-Host "Path     : $here"
    Write-Host "Root     : $($Global:PVenv.ProjectsRoot)"
    Write-Host "Active   : $($Global:PVenv.ActiveProject)"
    Write-Host "Venv     : " -NoNewline
    if (Test-Path (Join-Path $venv 'Scripts\Activate.ps1')) {
        Write-Host "$($Global:PVenv.Symbols.Venv) $venv" -ForegroundColor $Global:PVenv.Colors.Foreground.Accent
    } else {
        Write-Host "$($Global:PVenv.Symbols.None)" -ForegroundColor $Global:PVenv.Colors.Foreground.Muted
    }
    Write-Host "Auto     : $($Global:PVenv.Auto)" -ForegroundColor $Global:PVenv.Colors.Foreground.Accent
}

# region: Project creation ----------------------------------------------

function npe {
    param([string]$Name)
    $root = Join-Path $Global:PVenv.ProjectsRoot $Name
    if (-not (Test-Path $root)) { New-Item -ItemType Directory -Path $root -Force | Out-Null }
    $venv = Join-Path $root '.venv'
    if (-not (Test-Path $venv)) {
        New-Item -ItemType Directory -Path (Join-Path $venv 'Scripts') -Force | Out-Null
        $act = Join-Path $venv 'Scripts\Activate.ps1'
        @"
# dummy activate
`$env:VIRTUAL_ENV = '$venv'
function global:deactivate {
    Remove-Item Env:\VIRTUAL_ENV -ErrorAction SilentlyContinue
    Remove-Item Function:\deactivate -ErrorAction SilentlyContinue
}
Write-Host "Activated: `$env:VIRTUAL_ENV"
"@ | Set-Content -LiteralPath $act -Encoding UTF8
    }
    Write-Host "$($Global:PVenv.Symbols.Ok) Project created: $root" -ForegroundColor $Global:PVenv.Colors.Foreground.Good
}

# region: Banner --------------------------------------------------------

if (-not (PVenv-HasKey $Global:PVenv 'BannerShown')) {
    $Global:PVenv.BannerShown = $true
    Write-Host "[PVenv v0.6.8] ProjectsRoot: $($Global:PVenv.ProjectsRoot) | Auto: $($Global:PVenv.Auto)" `
        -ForegroundColor $Global:PVenv.Colors.Foreground.Accent
}
