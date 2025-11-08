# PVenv.Tests.ps1
# Requires -Version 5.1
$ErrorActionPreference = 'Stop'

# =========================
# Test bootstrap
# =========================
BeforeAll {
    # 古いテスト用一時ディレクトリをクリーンアップ（自己修復）
    $oldTests = Get-ChildItem "$env:TEMP" -Directory -Filter 'PVenvTest_*' -ErrorAction SilentlyContinue
    foreach ($d in $oldTests) {
        try { 
            Remove-Item $d.FullName -Recurse -Force -ErrorAction Stop 
        } catch {
            # クリーンアップ失敗は無視（既に使用中の可能性）
        }
    }

    # =========================
    # Helpers (BeforeAll scope)
    # =========================
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
        $venvRoot = Join-Path $ProjectPath ".venv"
        $scr      = Join-Path $venvRoot "Scripts"
        New-Item -ItemType Directory -Force -Path $scr | Out-Null

        # Activate.ps1
        @"
# dummy activate
`$env:VIRTUAL_ENV = '$venvRoot'
function global:deactivate {
    Remove-Item Env:\VIRTUAL_ENV -ErrorAction SilentlyContinue
    Remove-Item Function:\deactivate -ErrorAction SilentlyContinue
}
Write-Host "Activated: `$env:VIRTUAL_ENV"
"@ | Set-Content -LiteralPath (Join-Path $scr "Activate.ps1") -Encoding UTF8

        # python.exe ダミー（存在チェック用）
        New-Item -ItemType File -Force -Path (Join-Path $scr "python.exe") | Out-Null
    }

    function Capture-HostOut-Proxy {
        param([Parameter(Mandatory)][ScriptBlock]$Script)
        $buffer = New-Object System.Collections.Generic.List[string]
        
        # 既存のWrite-Hostを退避
        $origWriteHost = $null
        if (Get-Command Write-Host -CommandType Function -ErrorAction SilentlyContinue) {
            $origWriteHost = Get-Command Write-Host -CommandType Function
        }
        
        # プロキシ関数を定義
        $proxyDef = @'
param(
    [Parameter(Position=0, ValueFromRemainingArguments=$true)]
    $Object,
    [ConsoleColor]$ForegroundColor,
    [ConsoleColor]$BackgroundColor,
    [switch]$NoNewLine
)
$line = ($Object | ForEach-Object { 
    if ($_ -is [string]) { $_ } 
    else { $_ | Out-String } 
}) -join ''
$script:__pvenv_host_buffer.Add($line) | Out-Null
'@
        
        # バッファをスクリプトスコープに公開
        $script:__pvenv_host_buffer = $buffer
        
        # Write-Hostを差し替え
        $function:Write-Host = [ScriptBlock]::Create($proxyDef)
        
        try {
            & $Script *>&1 | Out-Null
        } finally {
            # 原状回復
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
            # まず通常の *>&1 でキャプチャを試す
            $output = & $Script *>&1 | Out-String
            if ($output) { return $output }
        } catch {}
        
        # フォールバック: Write-Hostプロキシ
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
            # 末尾の区切り文字も削除して完全に正規化
            return $full.TrimEnd('\', '/')
        } catch {
            return $Path
        }
    }

    # テスト用ルートディレクトリ作成
    $script:TestRoot = Join-Path $env:TEMP ("PVenvTest_" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Force -Path $script:TestRoot | Out-Null

    # pvenv.ps1を読み込み（リポジトリルートからの相対パス対応）
    $pvenvPath = $null
    $possiblePaths = @(
        ".\pvenv.ps1",                         # リポジトリルート（CI環境）最優先
        (Join-Path $PSScriptRoot "pvenv.ps1"), # スクリプトと同じディレクトリ
        "C:\Tools\PVenv\pvenv.ps1",            # ローカル環境
        "..\pvenv.ps1"                         # 一つ上のディレクトリ
    )
    
    foreach ($path in $possiblePaths) {
        $resolvedPath = $null
        try {
            if (Test-Path $path) {
                $resolvedPath = (Resolve-Path $path -ErrorAction Stop).Path
                if (Test-Path $resolvedPath) {
                    $pvenvPath = $resolvedPath
                    break
                }
            }
        } catch {
            # パス解決失敗は無視して次へ
            continue
        }
    }
    
    if (-not $pvenvPath) {
        $currentDir = Get-Location
        throw "pvenv.ps1 not found in any of the expected locations.`nCurrent directory: $currentDir`nTried: $($possiblePaths -join ', ')"
    }
    
    Write-Host "[Test] Loading pvenv.ps1 from: $pvenvPath" -ForegroundColor Cyan
    . $pvenvPath

    # プロジェクトルート設定
    Set-ProjectsRoot -Path $script:TestRoot | Out-Null
}

AfterAll {
    try { 
        if (Test-Path $script:TestRoot) {
            # attribでクリーンアップ
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
        # 初期状態に戻す
        Push-Location $script:TestRoot
        
        # 既存のvenv環境を無効化
        if (Test-Path Env:\VIRTUAL_ENV) {
            Remove-Item Env:\VIRTUAL_ENV -ErrorAction SilentlyContinue
        }
        if (Get-Command deactivate -ErrorAction SilentlyContinue) {
            Remove-Item Function:\deactivate -ErrorAction SilentlyContinue
        }
    }

    AfterEach {
        # クリーンアップ
        if (Test-Path Env:\VIRTUAL_ENV) {
            Remove-Item Env:\VIRTUAL_ENV -ErrorAction SilentlyContinue
        }
        if (Get-Command deactivate -ErrorAction SilentlyContinue) {
            Remove-Item Function:\deactivate -ErrorAction SilentlyContinue
        }
        Pop-Location
    }

    It 'auto: activates on entering project dir' {
        $pA = Join-Path $script:TestRoot 'project-A'
        New-Item -ItemType Directory -Force -Path $pA | Out-Null
        New-DummyVenv -ProjectPath $pA

        # auto モードを有効化
        peauto auto | Out-Null
        
        # ディレクトリ移動（PVenv-SetLocationが自動でアクティベート）
        Set-Location $pA
        
        # 検証
        $env:VIRTUAL_ENV | Should -Not -BeNullOrEmpty
        $env:VIRTUAL_ENV | Should -BeLike "*project-A*\.venv"
    }

    It 'off: does not auto-activate' {
        $pB = Join-Path $script:TestRoot 'project-B'
        New-Item -ItemType Directory -Force -Path $pB | Out-Null
        New-DummyVenv -ProjectPath $pB

        # auto モードを無効化
        peauto off | Out-Null
        
        Set-Location $pB

        $env:VIRTUAL_ENV | Should -BeNullOrEmpty
    }

    It 'refresh: no-op in same dir, deactivate when leaving root' {
        $pA = Join-Path $script:TestRoot 'project-A'
        if (-not (Test-Path $pA)) {
            New-Item -ItemType Directory -Force -Path $pA | Out-Null
        }
        if (-not (Test-Path (Join-Path $pA '.venv'))) {
            New-DummyVenv -ProjectPath $pA
        }

        peauto auto | Out-Null
        Set-Location $pA
        
        $beforeVenv = $env:VIRTUAL_ENV
        $beforeVenv | Should -Not -BeNullOrEmpty

        # 同じディレクトリで再度Refresh
        PVenv-Refresh
        $env:VIRTUAL_ENV | Should -Be $beforeVenv  # 変化なし

        # ルート外へ移動（PVenv-SetLocationが自動で非アクティブ化）
        Set-Location $env:TEMP
        
        $env:VIRTUAL_ENV | Should -BeNullOrEmpty
    }

    It 'spt: prints at least one of [A]/[V]/[-]' {
        $out = Capture-HostOut { spt }
        $out | Should -Match '\[A\]|\[V\]|\[-\]'
    }

    It 'spi: contains "profile" or project info in output' {
        $pA = Join-Path $script:TestRoot 'project-spi-test'
        if (-not (Test-Path $pA)) {
            New-Item -ItemType Directory -Force -Path $pA | Out-Null
        }
        Set-Location $pA
        
        $txt = Capture-HostOut { spi }
        
        # "profile" または "project" を含むことを確認
        $txt | Should -Match '\b(profile|project|path)\b'
    }

    It 'Set-ProjectsRoot: changes global root' {
        $newRoot = Join-Path $script:TestRoot 'new-root'
        New-Item -ItemType Directory -Force -Path $newRoot | Out-Null
        
        Set-ProjectsRoot -Path $newRoot | Out-Null
        
        # 完全正規化（短縮パス/末尾区切りの違いを吸収）
        $expectedPath = Normalize-Path $newRoot
        $actualPath   = Normalize-Path $Global:PVenv.ProjectsRoot
        
        $actualPath | Should -Be $expectedPath
    }

    It 'peauto: rejects invalid mode' {
        $out = Capture-HostOut { peauto invalid-mode }
        $out | Should -Match '(ERR|Invalid|mode)'
    }
}

Describe 'PVenv edge cases' {
    
    BeforeEach {
        Push-Location $script:TestRoot
        if (Test-Path Env:\VIRTUAL_ENV) {
            Remove-Item Env:\VIRTUAL_ENV
        }
    }

    AfterEach {
        if (Test-Path Env:\VIRTUAL_ENV) {
            Remove-Item Env:\VIRTUAL_ENV
        }
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
        
        # 子プロジェクトへ移動
        Set-Location $child
        
        # 最も近い.venvが優先されるべき
        $env:VIRTUAL_ENV | Should -BeLike "*child-proj*\.venv"
    }

    It 'does not activate if .venv is missing Scripts' {
        $pX = Join-Path $script:TestRoot 'broken-proj'
        New-Item -ItemType Directory -Force -Path $pX | Out-Null
        
        # .venvは作るがScriptsは作らない
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

Describe 'PVenv resource profile management' {
    
    BeforeEach {
        Push-Location $script:TestRoot
    }

    AfterEach {
        Pop-Location
    }

    It 'Show-ResourceProfile: displays effective profile' {
        $pProf = Join-Path $script:TestRoot 'profile-test'
        New-Item -ItemType Directory -Force -Path $pProf | Out-Null
        Set-Location $pProf
        
        $out = Capture-HostOut { Show-ResourceProfile }
        
        # 基本的なプロファイル情報が含まれているか
        $out | Should -Match '\b(profile|Global|Project|Effective)\b'
    }

    It 'Set-ResourceProfile: validates preset values' {
        $pProf = Join-Path $script:TestRoot 'profile-preset-test'
        New-Item -ItemType Directory -Force -Path $pProf | Out-Null
        Set-Location $pProf
        
        # balanced プリセットを設定
        { Set-ResourceProfile -Scope Project -Profile balanced } | Should -Not -Throw
        
        # 設定ファイルが作成されたことを確認
        $profilePath = Join-Path $pProf '.pvenv.profile.json'
        Test-Path $profilePath | Should -Be $true
    }
}