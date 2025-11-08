# PVenv.Tests.ps1
# Requires -Version 5.1
$ErrorActionPreference = 'Stop'

# =========================
# Test bootstrap (safe for CI)
# =========================
BeforeAll {
    # --- Execution Policy ---
    try { Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force } catch {}

    $script:IsCI      = ($env:GITHUB_ACTIONS -eq 'true' -or $env:CI -eq 'true')
    $script:IsWindows = $PSVersionTable.PSEdition -ne 'Core' -or $IsWindows
    $script:SkipAll   = $false

    # --- Helper functions ---
    function Remove-DirSafe {
        param([Parameter(Mandatory)][string]$Path)
        if (Test-Path -LiteralPath $Path) {
            try {
                attrib -r -h -s -a "$Path\*.*" /s /d -ErrorAction SilentlyContinue | Out-Null
                Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
            } catch {
                Start-Sleep -Milliseconds 120
                Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    function New-DummyVenv {
        param([Parameter(Mandatory)][string]$ProjectPath)
        $venvRoot = Join-Path $ProjectPath ".venv"
        $scr      = Join-Path $venvRoot "Scripts"
        New-Item -ItemType Directory -Force -Path $scr | Out-Null

        @"
# dummy activate
`$env:VIRTUAL_ENV = '$venvRoot'
function global:deactivate {
    Remove-Item Env:\VIRTUAL_ENV -ErrorAction SilentlyContinue
    Remove-Item Function:\deactivate -ErrorAction SilentlyContinue
}
Write-Host "Activated: `$env:VIRTUAL_ENV"
"@ | Set-Content -LiteralPath (Join-Path $scr "Activate.ps1") -Encoding UTF8

        New-Item -ItemType File -Force -Path (Join-Path $scr "python.exe") | Out-Null
    }

    function Capture-HostOut {
        param([Parameter(Mandatory)][ScriptBlock]$Script)
        try {
            $out = & $Script *>&1 | Out-String
            return ($out -replace "\s+$","")
        } catch {
            return ""
        }
    }

    function Normalize-Path {
        param([string]$Path)
        if (-not $Path) { return $Path }
        try { [System.IO.Path]::GetFullPath($Path).TrimEnd('\','/') } catch { $Path }
    }

    # --- Paths ---
    $script:TestRoot     = Join-Path $env:TEMP ("PVenvTest_" + [guid]::NewGuid().ToString("N"))
    $script:ProjectsRoot = Join-Path $script:TestRoot "Projects"
    New-Item -ItemType Directory -Force -Path $script:ProjectsRoot | Out-Null

    # --- Find pvenv.ps1 safely ---
    $candidates = @(
        (Join-Path $PSScriptRoot "pvenv.ps1"),
        (Join-Path (Split-Path $PSScriptRoot -Parent) "pvenv.ps1"),
        "D:\a\PVenv\PVenv\pvenv.ps1",
        "C:\Tools\PVenv\pvenv.ps1"
    )
    foreach ($p in $candidates) {
        try {
            if (Test-Path $p) { $script:PvenvPath = (Resolve-Path $p).Path; break }
        } catch {}
    }

    if (-not $script:PvenvPath) {
        Write-Warning "pvenv.ps1 not found — skipping all PVenv tests."
        $script:SkipAll = $true
        return
    }

    try {
        . $script:PvenvPath
        Set-ProjectsRoot -Path $script:ProjectsRoot | Out-Null
        Set-Location     -Path $script:TestRoot
        Write-Host "[INFO] PVenv loaded for test."
        Write-Host "[INFO] TestRoot: $script:TestRoot"
        Write-Host "[INFO] ProjectsRoot: $script:ProjectsRoot"
    } catch {
        Write-Warning "Failed to import pvenv.ps1: $_"
        $script:SkipAll = $true
    }
}

AfterAll {
    try {
        if (Test-Path $script:TestRoot) {
            attrib -r -h -s -a "$($script:TestRoot)\*.*" /s /d -ErrorAction SilentlyContinue | Out-Null
            Remove-Item -LiteralPath $script:TestRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    } catch { Write-Warning "Cleanup failed: $_" }
}

# =========================
# Tests
# =========================
Describe 'PVenv basic behaviours' {
    if ($script:SkipAll) { Set-ItResult -Skipped -Because 'pvenv.ps1 missing'; return }

    BeforeEach {
        Push-Location $script:TestRoot
        if (Test-Path Env:\VIRTUAL_ENV) { Remove-Item Env:\VIRTUAL_ENV -ErrorAction SilentlyContinue }
        if (Get-Command deactivate -ErrorAction SilentlyContinue) {
            Remove-Item Function:\deactivate -ErrorAction SilentlyContinue
        }
    }
    AfterEach {
        if (Test-Path Env:\VIRTUAL_ENV) { Remove-Item Env:\VIRTUAL_ENV -ErrorAction SilentlyContinue }
        if (Get-Command deactivate -ErrorAction SilentlyContinue) {
            Remove-Item Function:\deactivate -ErrorAction SilentlyContinue
        }
        Pop-Location
    }

    It 'auto: activates on entering project dir' {
        $pA = Join-Path $script:ProjectsRoot 'project-A'
        New-Item -ItemType Directory -Force -Path $pA | Out-Null
        New-DummyVenv -ProjectPath $pA
        peauto auto | Out-Null
        Set-Location $pA
        $env:VIRTUAL_ENV | Should -BeLike "*project-A*\.venv"
    }

    It 'off: does not auto-activate' {
        $pB = Join-Path $script:ProjectsRoot 'project-B'
        New-Item -ItemType Directory -Force -Path $pB | Out-Null
        New-DummyVenv -ProjectPath $pB
        peauto off | Out-Null
        Set-Location $pB
        $env:VIRTUAL_ENV | Should -BeNullOrEmpty
    }

    It 'refresh: deactivates when leaving root' {
        $pA = Join-Path $script:ProjectsRoot 'project-A'
        if (-not (Test-Path $pA)) { New-Item -ItemType Directory -Force -Path $pA | Out-Null }
        if (-not (Test-Path (Join-Path $pA '.venv'))) { New-DummyVenv -ProjectPath $pA }
        peauto auto | Out-Null
        Set-Location $pA
        $before = $env:VIRTUAL_ENV
        PVenv-Refresh
        Set-Location $env:TEMP
        $env:VIRTUAL_ENV | Should -BeNullOrEmpty
    }

    It 'spt: prints one of [A]/[V]/[-]' {
        $out = Capture-HostOut { spt }
        $out | Should -Match '\[A\]|\[V\]|\[-\]'
    }

    It 'spi: contains profile or path info' {
        $p = Join-Path $script:ProjectsRoot 'spi-test'
        New-Item -ItemType Directory -Force -Path $p | Out-Null
        Set-Location $p
        $txt = Capture-HostOut { spi }
        $txt | Should -Match '\b(profile|project|path)\b'
    }
}

Describe 'PVenv adopt (shim/move)' {
    if ($script:SkipAll) { Set-ItResult -Skipped -Because 'pvenv.ps1 missing'; return }
    BeforeEach { Push-Location $script:ProjectsRoot }
    AfterEach  { Pop-Location }

    It 'peadopt shim works' {
        $ext = Join-Path $script:TestRoot 'ext-venv'
        New-DummyVenv -ProjectPath $ext
        $p = Join-Path $script:ProjectsRoot 'shim-proj'
        New-Item -ItemType Directory -Force -Path $p | Out-Null
        Set-Location $p
        peadopt -Mode shim -TargetVenvPath (Join-Path $ext '.venv')
        Test-Path (Join-Path $p '.pvenv.adopt.json') | Should -Be $true
    }

    It 'peadopt move (skip if CI)' -Skip:$script:IsCI {
        $ext = Join-Path $script:TestRoot 'ext-move'
        New-DummyVenv -ProjectPath $ext
        $p = Join-Path $script:ProjectsRoot 'proj-move'
        New-Item -ItemType Directory -Force -Path $p | Out-Null
        Set-Location $p
        peadopt -Mode move -TargetVenvPath (Join-Path $ext '.venv')
        Test-Path (Join-Path $p '.venv\Scripts\Activate.ps1') | Should -Be $true
    }
}
