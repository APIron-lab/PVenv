# PVenv.Tests.ps1
# Requires -Version 5.1
$ErrorActionPreference = 'Stop'

# =========================
# Test bootstrap (CI-friendly)
# =========================
BeforeAll {
    # ---- ExecutionPolicy (CIでRestrictedを回避) ----
    try { Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force } catch {}

    # ---- CI/環境フラグ ----
    $script:IsCI      = ($env:GITHUB_ACTIONS -eq 'true' -or $env:CI -eq 'true')
    $script:IsWindows = $PSVersionTable.PSEdition -ne 'Core' -or $IsWindows

    # ---- Helper functions ----
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

        # 存在チェック用ダミー
        New-Item -ItemType File -Force -Path (Join-Path $scr "python.exe") | Out-Null
    }

    function Capture-HostOut-Proxy {
        param([Parameter(Mandatory)][ScriptBlock]$Script)
        $buffer = New-Object System.Collections.Generic.List[string]

        $origWriteHost = $null
        if (Get-Command Write-Host -CommandType Function -ErrorAction SilentlyContinue) {
            $origWriteHost = Get-Command Write-Host -CommandType Function
        }

        $proxyDef = @'
param(
  [Parameter(Position=0, ValueFromRemainingArguments=$true)]
  $Object,
  [ConsoleColor]$ForegroundColor,
  [ConsoleColor]$BackgroundColor,
  [switch]$NoNewLine
)
$line = ($Object | ForEach-Object {
  if ($_ -is [string]) { $_ } else { $_ | Out-String }
}) -join ''
$script:__pvenv_host_buffer.Add($line) | Out-Null
'@

        $script:__pvenv_host_buffer = $buffer
        $function:Write-Host = [ScriptBlock]::Create($proxyDef)

        try {
            & $Script *>&1 | Out-Null
        } finally {
            if ($origWriteHost) {
                $function:Write-Host = $origWriteHost.ScriptBlock
            } else {
                Remove-Item Function:\Write-Host -ErrorAction SilentlyContinue
            }
        }
        ($buffer -join [Environment]::NewLine)
    }

    function Capture-HostOut {
        param([Parameter(Mandatory)][ScriptBlock]$Script)
        try {
            $output = & $Script *>&1 | Out-String
            if ($output) { return $output }
        } catch {}
        try {
            return Capture-HostOut-Proxy -Script $Script
        } catch {
            Write-Warning "Capture-HostOut failed: $_"
            return ""
        }
    }

    function Normalize-Path {
        param([string]$Path)
        if (-not $Path) { return $Path }
        try {
            $full = [System.IO.Path]::GetFullPath($Path)
            return $full.TrimEnd('\','/')
        } catch {
            return $Path
        }
    }

    # ---- テスト用ルートは必ず TEMP 配下に作成（CI互換）----
    $script:TestRoot = Join-Path $env:TEMP ("PVenvTest_" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Force -Path $script:TestRoot | Out-Null

    # ProjectsRoot も TEMP 配下に隔離（C:\Projects 前提を排除）
    $script:ProjectsRoot = Join-Path $script:TestRoot "Projects"
    New-Item -ItemType Directory -Force -Path $script:ProjectsRoot | Out-Null

    # ---- pvenv.ps1 の探索：ワークスペース/同階層/標準パス ----
    $script:PvenvPath = $null
    $candidates = @(
        (Join-Path $PSScriptRoot "pvenv.ps1"),               # テストと同じ場所
        (Join-Path (Split-Path $PSScriptRoot -Parent) "pvenv.ps1"), # 親
        (Join-Path (Get-Location).Path "pvenv.ps1"),         # 現在地
        "D:\a\PVenv\PVenv\pvenv.ps1",                        # GitHub Actions windows-latest 既定
        "C:\Tools\PVenv\pvenv.ps1"                           # ローカル既定
    )
    foreach ($p in $candidates) {
        try {
            if (Test-Path $p) { $script:PvenvPath = (Resolve-Path $p).Path; break }
        } catch {}
    }
    if (-not $script:PvenvPath) { throw "pvenv.ps1 not found. Tried: $($candidates -join ', ')" }

    . $script:PvenvPath

    # ---- 明示的に ProjectsRoot をセットし、カレントも揃える ----
    Set-ProjectsRoot -Path $script:ProjectsRoot | Out-Null
    Set-Location     -Path $script:TestRoot
    Write-Host "[INFO] TestRoot: $script:TestRoot"
    Write-Host "[INFO] ProjectsRoot: $script:ProjectsRoot"
}

AfterAll {
    try {
        if (Test-Path $script:TestRoot) {
            attrib -r -h -s -a "$($script:TestRoot)\*.*" /s /d -ErrorAction SilentlyContinue | Out-Null
            Remove-Item -LiteralPath $script:TestRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    } catch {
        Write-Warning "Cleanup failed: $_"
    }
}

# =========================
# Tests
# =========================

Describe 'PVenv basic behaviours' {
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

        $env:VIRTUAL_ENV | Should -Not -BeNullOrEmpty
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

    It 'refresh: no-op in same dir, deactivate when leaving root' {
        $pA = Join-Path $script:ProjectsRoot 'project-A'
        if (-not (Test-Path $pA)) { New-Item -ItemType Directory -Force -Path $pA | Out-Null }
        if (-not (Test-Path (Join-Path $pA '.venv'))) { New-DummyVenv -ProjectPath $pA }

        peauto auto | Out-Null
        Set-Location $pA

        $beforeVenv = $env:VIRTUAL_ENV
        $beforeVenv | Should -Not -BeNullOrEmpty

        PVenv-Refresh
        $env:VIRTUAL_ENV | Should -Be $beforeVenv

        # ルート外へ移動 → 自動的に非アクティブ化
        Set-Location $env:TEMP
        $env:VIRTUAL_ENV | Should -BeNullOrEmpty
    }

    It 'spt: prints at least one of [A]/[V]/[-]' {
        $out = Capture-HostOut { spt }
        $out | Should -Match '\[A\]|\[V\]|\[-\]'
    }

    It 'spi: contains "profile" or project info in output' {
        $p = Join-Path $script:ProjectsRoot 'project-spi-test'
        if (-not (Test-Path $p)) { New-Item -ItemType Directory -Force -Path $p | Out-Null }
        Set-Location $p
        $txt = Capture-HostOut { spi }
        $txt | Should -Match '\b(profile|project|path)\b'
    }

    It 'Set-ProjectsRoot: changes global root' {
        $newRoot = Join-Path $script:TestRoot 'new-root'
        New-Item -ItemType Directory -Force -Path $newRoot | Out-Null
        Set-ProjectsRoot -Path $newRoot | Out-Null
        $expectedPath = Normalize-Path $newRoot
        $actualPath   = Normalize-Path $Global:PVenv.ProjectsRoot
        $actualPath | Should -Be $expectedPath

        # 元に戻す（他テストに影響させない）
        Set-ProjectsRoot -Path $script:ProjectsRoot | Out-Null
    }

    It 'peauto: rejects invalid mode' {
        $out = Capture-HostOut { peauto invalid-mode }
        $out | Should -Match '(ERR|Invalid|mode)'
    }
}

Describe 'PVenv edge cases' {
    BeforeEach { Push-Location $script:ProjectsRoot }
    AfterEach  { Pop-Location }

    It 'handles nested project directories' {
        $parent = Join-Path $script:ProjectsRoot 'parent-proj'
        $child  = Join-Path $parent 'child-proj'
        New-Item -ItemType Directory -Force -Path $parent, $child | Out-Null
        New-DummyVenv -ProjectPath $parent
        New-DummyVenv -ProjectPath $child

        peauto auto | Out-Null
        Set-Location $child

        $env:VIRTUAL_ENV | Should -BeLike "*child-proj*\.venv"
    }

    It 'does not activate if .venv is missing Scripts' {
        $pX = Join-Path $script:ProjectsRoot 'broken-proj'
        New-Item -ItemType Directory -Force -Path $pX | Out-Null
        New-Item -ItemType Directory -Force -Path (Join-Path $pX '.venv') | Out-Null

        peauto auto | Out-Null
        Set-Location $pX

        $env:VIRTUAL_ENV | Should -BeNullOrEmpty
    }

    It 'handles project name with spaces' {
        $p = Join-Path $script:ProjectsRoot 'project with spaces'
        New-Item -ItemType Directory -Force -Path $p | Out-Null
        New-DummyVenv -ProjectPath $p

        peauto auto | Out-Null
        Set-Location $p

        $env:VIRTUAL_ENV | Should -Not -BeNullOrEmpty
        $env:VIRTUAL_ENV | Should -BeLike "*project with spaces*\.venv"
    }
}

Describe 'PVenv adopt (shim) & switch' {
    BeforeEach { Push-Location $script:ProjectsRoot }
    AfterEach  { Pop-Location }

    It 'peadopt shim: records meta and Switch-ProjectVenv activates target' {
        # 外部venv（ダミー）を別フォルダに作る
        $ext = Join-Path $script:TestRoot 'external-venv'
        New-Item -ItemType Directory -Force -Path $ext | Out-Null
        New-DummyVenv -ProjectPath $ext

        # プロジェクト側
        $p = Join-Path $script:ProjectsRoot 'proj-shim'
        New-Item -ItemType Directory -Force -Path $p | Out-Null
        Set-Location $p

        peauto off | Out-Null
        peadopt -Mode shim -TargetVenvPath (Join-Path $ext '.venv')

        # shimメタができていること
        Test-Path (Join-Path $p '.pvenv.adopt.json') | Should -Be $true

        # 明示切替
        $r = Switch-ProjectVenv -Path $p
        $r.State | Should -Be 'ACTIVE'
        $env:VIRTUAL_ENV | Should -BeLike "*external-venv*\.venv"
    }
}

Describe 'PVenv adopt (junction / move)' {
    BeforeEach { Push-Location $script:ProjectsRoot }
    AfterEach  { Pop-Location }

    # junction/move はCI環境だと権限で失敗する可能性が高いため条件付き
    $canMklink = -not $script:IsCI  # CIでは基本スキップ（Developers Mode/昇格無し）

    It 'peadopt move: relocates external venv into project and activates' -Skip:(-not $canMklink) {
        $ext = Join-Path $script:TestRoot 'ext-move'
        New-Item -ItemType Directory -Force -Path $ext | Out-Null
        New-DummyVenv -ProjectPath $ext

        $p = Join-Path $script:ProjectsRoot 'proj-move'
        New-Item -ItemType Directory -Force -Path $p | Out-Null
        Set-Location $p

        peauto off | Out-Null
        peadopt -Mode move -TargetVenvPath (Join-Path $ext '.venv')

        Test-Path (Join-Path $p '.venv\Scripts\Activate.ps1') | Should -Be $true

        $r = Switch-ProjectVenv -Path $p
        $r.State | Should -Be 'ACTIVE'
        $env:VIRTUAL_ENV | Should -BeLike "*proj-move*\.venv"
    }

    It 'peadopt junction: creates .venv junction to external venv and activates' -Skip:(-not $canMklink) {
        $ext = Join-Path $script:TestRoot 'ext-junc'
        New-Item -ItemType Directory -Force -Path $ext | Out-Null
        New-DummyVenv -ProjectPath $ext

        $p = Join-Path $script:ProjectsRoot 'proj-junc'
        New-Item -ItemType Directory -Force -Path $p | Out-Null
        Set-Location $p

        peauto off | Out-Null
        peadopt -Mode junction -TargetVenvPath (Join-Path $ext '.venv')

        Test-Path (Join-Path $p '.venv\Scripts\Activate.ps1') | Should -Be $true

        $r = Switch-ProjectVenv -Path $p
        $r.State | Should -Be 'ACTIVE'
        $env:VIRTUAL_ENV | Should -BeLike "*ext-junc*\.venv"
    }
}
