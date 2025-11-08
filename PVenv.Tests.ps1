# PVenv.Tests.ps1
# Requires -Version 5.1
$ErrorActionPreference = 'Stop'

Describe 'PVenv' {

    #
    # ========= File-scoped hooks =========
    #
    BeforeAll {
        # 古いテスト用一時ディレクトリをクリーンアップ（自己修復）
        $oldTests = Get-ChildItem "$env:TEMP" -Directory -Filter 'PVenvTest_*' -ErrorAction SilentlyContinue
        foreach ($d in $oldTests) {
            try { Remove-Item $d.FullName -Recurse -Force -ErrorAction Stop } catch {}
        }

        # =========================
        # pvenv.ps1 読み込み（CI/ローカル両対応）
        # =========================
        $pvenvPath = $null
        $possiblePaths = @(
            (Join-Path $PSScriptRoot 'pvenv.ps1'),                      # テストと同階層（CI最優先）
            (Join-Path (Split-Path $PSScriptRoot -Parent) 'pvenv.ps1'), # 親ディレクトリ
            '.\pvenv.ps1',                                              # 実行ディレクトリ相対
            '..\pvenv.ps1',                                             # 1つ上
            'C:\Tools\PVenv\pvenv.ps1'                                  # ローカル固定
        )
        foreach ($path in $possiblePaths) {
            try {
                if (Test-Path $path) {
                    $resolved = (Resolve-Path $path -ErrorAction Stop).Path
                    if (Test-Path $resolved) { $pvenvPath = $resolved; break }
                }
            } catch { continue }
        }
        if (-not $pvenvPath) {
            throw "pvenv.ps1 not found. Tried: $($possiblePaths -join ', ')"
        }

        Write-Host "[Test] Loading pvenv.ps1 from: $pvenvPath" -ForegroundColor Cyan
        . $pvenvPath

        # ========= Helpers (file scope) =========

        function Remove-DirSafe {
            param([Parameter(Mandatory)][string]$Path)
            if (Test-Path -LiteralPath $Path) {
                try {
                    attrib -r -h -s -a "$Path\*.*" /s /d -ErrorAction SilentlyContinue | Out-Null
                    Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
                } catch {
                    Start-Sleep -Milliseconds 100
                    Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
        }

        function New-DummyVenv {
            param([Parameter(Mandatory)][string]$ProjectPath)
            $venvRoot = Join-Path $ProjectPath '.venv'
            $scr      = Join-Path $venvRoot 'Scripts'
            New-Item -ItemType Directory -Force -Path $scr | Out-Null

            @"
# dummy activate
`$env:VIRTUAL_ENV = '$venvRoot'
function global:deactivate {
    Remove-Item Env:\VIRTUAL_ENV -ErrorAction SilentlyContinue
    Remove-Item Function:\deactivate -ErrorAction SilentlyContinue
}
Write-Host "Activated: `$env:VIRTUAL_ENV"
"@ | Set-Content -LiteralPath (Join-Path $scr 'Activate.ps1') -Encoding UTF8

            New-Item -ItemType File -Force -Path (Join-Path $scr 'python.exe') | Out-Null
        }

        # --- Write-Host を安全に取得：Transcript方式 ---
        function Capture-HostOut {
            param([Parameter(Mandatory)][ScriptBlock]$Script)
            $log = Join-Path $env:TEMP ("PVenvTranscript_{0}.txt" -f ([guid]::NewGuid().ToString('N')))
            try {
                Start-Transcript -Path $log -Force | Out-Null
                & $Script *>&1 | Out-Null
            } finally {
                try { Stop-Transcript | Out-Null } catch {}
            }
            if (Test-Path $log) {
                try { return (Get-Content -LiteralPath $log -Raw) } catch { return "" }
            }
            return ""
        }

        function Normalize-Path {
            param([string]$Path)
            if (-not $Path) { return $Path }
            try {
                $full = [System.IO.Path]::GetFullPath($Path)
                return $full.TrimEnd('\', '/')
            } catch {
                return $Path
            }
        }

        # テスト用ルート
        $script:TestRoot = Join-Path $env:TEMP ("PVenvTest_" + [guid]::NewGuid().ToString("N"))
        New-Item -ItemType Directory -Force -Path $script:TestRoot | Out-Null

        # プロジェクトルート設定
        Set-ProjectsRoot -Path $script:TestRoot | Out-Null
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

    #
    # ========= Tests =========
    #
    Context 'basic behaviours' {

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
            $pA = Join-Path $script:TestRoot 'project-A'
            New-Item -ItemType Directory -Force -Path $pA | Out-Null
            New-DummyVenv -ProjectPath $pA
            peauto auto | Out-Null
            Set-Location $pA
            $env:VIRTUAL_ENV | Should -Not -BeNullOrEmpty
            $env:VIRTUAL_ENV | Should -BeLike "*project-A*\.venv"
        }

        It 'off: does not auto-activate' {
            $pB = Join-Path $script:TestRoot 'project-B'
            New-Item -ItemType Directory -Force -Path $pB | Out-Null
            New-DummyVenv -ProjectPath $pB
            peauto off | Out-Null
            Set-Location $pB
            $env:VIRTUAL_ENV | Should -BeNullOrEmpty
        }

        It 'refresh: no-op in same dir, deactivate when leaving root' {
            $pA = Join-Path $script:TestRoot 'project-A'
            if (-not (Test-Path $pA)) { New-Item -ItemType Directory -Force -Path $pA | Out-Null }
            if (-not (Test-Path (Join-Path $pA '.venv'))) { New-DummyVenv -ProjectPath $pA }

            peauto auto | Out-Null
            Set-Location $pA
            $beforeVenv = $env:VIRTUAL_ENV
            $beforeVenv | Should -Not -BeNullOrEmpty

            PVenv-Refresh
            $env:VIRTUAL_ENV | Should -Be $beforeVenv

            Set-Location $env:TEMP
            $env:VIRTUAL_ENV | Should -BeNullOrEmpty
        }

        It 'spt: prints at least one of [A]/[V]/[-]' {
            $out = Capture-HostOut { spt }
            $out | Should -Match '\[A\]|\[V\]|\[-\]'
        }

        It 'spi: contains "profile" or project info in output' {
            $pA = Join-Path $script:TestRoot 'project-spi-test'
            if (-not (Test-Path $pA)) { New-Item -ItemType Directory -Force -Path $pA | Out-Null }
            Set-Location $pA
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
        }

        It 'peauto: rejects invalid mode' {
            $out = Capture-HostOut { peauto invalid-mode }
            $out | Should -Match '(ERR|Invalid|mode)'
        }
    }

    Context 'edge cases' {

        BeforeEach {
            Push-Location $script:TestRoot
            if (Test-Path Env:\VIRTUAL_ENV) { Remove-Item Env:\VIRTUAL_ENV }
        }

        AfterEach {
            if (Test-Path Env:\VIRTUAL_ENV) { Remove-Item Env:\VIRTUAL_ENV }
            Pop-Location
        }

        It 'handles nested project directories' {
            $parent = Join-Path $script:TestRoot 'parent-proj'
            $child  = Join-Path $parent 'child-proj'
            New-Item -ItemType Directory -Force -Path $parent | Out-Null
            New-Item -ItemType Directory -Force -Path $child | Out-Null
            New-DummyVenv -ProjectPath $parent
            New-DummyVenv -ProjectPath $child

            peauto auto | Out-Null
            Set-Location $child
            $env:VIRTUAL_ENV | Should -BeLike "*child-proj*\.venv"
        }

        It 'does not activate if .venv is missing Scripts' {
            $pX = Join-Path $script:TestRoot 'broken-proj'
            New-Item -ItemType Directory -Force -Path $pX | Out-Null
            $venvDir = Join-Path $pX '.venv'
            New-Item -ItemType Directory -Force -Path $venvDir | Out-Null
            peauto auto | Out-Null
            Set-Location $pX
            $env:VIRTUAL_ENV | Should -BeNullOrEmpty
        }

        It 'handles project name with spaces' {
            $pSpace = Join-Path $script:TestRoot 'project with spaces'
            New-Item -ItemType Directory -Force -Path $pSpace | Out-Null
            New-DummyVenv -ProjectPath $pSpace
            peauto auto | Out-Null
            Set-Location $pSpace
            $env:VIRTUAL_ENV | Should -Not -BeNullOrEmpty
            $env:VIRTUAL_ENV | Should -BeLike "*project with spaces*\.venv"
        }
    }

    Context 'resource profile management' {

        BeforeEach { Push-Location $script:TestRoot }
        AfterEach  { Pop-Location }

        It 'Show-ResourceProfile: displays effective profile' {
            $pProf = Join-Path $script:TestRoot 'profile-test'
            New-Item -ItemType Directory -Force -Path $pProf | Out-Null
            Set-Location $pProf
            $out = Capture-HostOut { Show-ResourceProfile }
            $out | Should -Match '\b(profile|Global|Project|Effective)\b'
        }

        It 'Set-ResourceProfile: validates preset values' {
            $pProf = Join-Path $script:TestRoot 'profile-preset-test'
            New-Item -ItemType Directory -Force -Path $pProf | Out-Null
            Set-Location $pProf
            { Set-ResourceProfile -Scope Project -Profile balanced } | Should -Not -Throw
            $profilePath = Join-Path $pProf '.pvenv.profile.json'
            Test-Path $profilePath | Should -Be $true
        }
    }
}
