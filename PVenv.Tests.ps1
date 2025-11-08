# PVenv.Tests.ps1
# Requires -Version 5.1
$ErrorActionPreference = 'Stop'

# =========================
# Test bootstrap
# =========================
BeforeAll {
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

        # python.exe 繝繝溘・・亥ｭ伜惠繝√ぉ繝・け逕ｨ・・
        New-Item -ItemType File -Force -Path (Join-Path $scr "python.exe") | Out-Null
    }

    function Capture-HostOut-Proxy {
        param([Parameter(Mandatory)][ScriptBlock]$Script)
        $buffer = New-Object System.Collections.Generic.List[string]
        
        # 譌｢蟄倥・Write-Host繧帝驕ｿ
        $origWriteHost = $null
        if (Get-Command Write-Host -CommandType Function -ErrorAction SilentlyContinue) {
            $origWriteHost = Get-Command Write-Host -CommandType Function
        }
        
        # 繝励Ο繧ｭ繧ｷ髢｢謨ｰ繧貞ｮ夂ｾｩ
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
        
        # 繝舌ャ繝輔ぃ繧偵せ繧ｯ繝ｪ繝励ヨ繧ｹ繧ｳ繝ｼ繝励↓蜈ｬ髢・
        $script:__pvenv_host_buffer = $buffer
        
        # Write-Host繧貞ｷｮ縺玲崛縺・
        $function:Write-Host = [ScriptBlock]::Create($proxyDef)
        
        try {
            & $Script *>&1 | Out-Null
        } finally {
            # 蜴溽憾蝗槫ｾｩ
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
            # 縺ｾ縺夐壼ｸｸ縺ｮ *>&1 縺ｧ繧ｭ繝｣繝励メ繝｣繧定ｩｦ縺・
            $output = & $Script *>&1 | Out-String
            if ($output) { return $output }
        } catch {}
        
        # 繝輔か繝ｼ繝ｫ繝舌ャ繧ｯ: Write-Host繝励Ο繧ｭ繧ｷ
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
            # 譛ｫ蟆ｾ縺ｮ蛹ｺ蛻・ｊ譁・ｭ励ｂ蜑企勁縺励※螳悟・縺ｫ豁｣隕丞喧
            return $full.TrimEnd('\', '/')
        } catch {
            return $Path
        }
    }

    # 繝・せ繝育畑繝ｫ繝ｼ繝医ョ繧｣繝ｬ繧ｯ繝医Μ菴懈・
    $script:TestRoot = Join-Path $env:TEMP ("PVenvTest_" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Force -Path $script:TestRoot | Out-Null

    # pvenv.ps1繧定ｪｭ縺ｿ霎ｼ縺ｿ
    $repoPath  = Join-Path $PSScriptRoot 'pvenv.ps1'
    $localPath = 'C:\Tools\PVenv\pvenv.ps1'
    $pvenvPath = @($repoPath, $localPath) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $pvenvPath) {
        throw "pvenv.ps1 not found. Searched: `"$repoPath`", `"$localPath`""
    }
    . $pvenvPath

    # 繝励Ο繧ｸ繧ｧ繧ｯ繝医Ν繝ｼ繝郁ｨｭ螳・
    Set-ProjectsRoot -Path $script:TestRoot | Out-Null
}

AfterAll {
    try { 
        if (Test-Path $script:TestRoot) {
            # attrib縺ｧ繧ｯ繝ｪ繝ｼ繝ｳ繧｢繝・・
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
        # 蛻晄悄迥ｶ諷九↓謌ｻ縺・
        Push-Location $script:TestRoot
        
        # 譌｢蟄倥・venv迺ｰ蠅・ｒ辟｡蜉ｹ蛹・
        if (Test-Path Env:\VIRTUAL_ENV) {
            Remove-Item Env:\VIRTUAL_ENV -ErrorAction SilentlyContinue
        }
        if (Get-Command deactivate -ErrorAction SilentlyContinue) {
            Remove-Item Function:\deactivate -ErrorAction SilentlyContinue
        }
    }

    AfterEach {
        # 繧ｯ繝ｪ繝ｼ繝ｳ繧｢繝・・
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

        # auto 繝｢繝ｼ繝峨ｒ譛牙柑蛹・
        peauto auto | Out-Null
        
        # 繝・ぅ繝ｬ繧ｯ繝医Μ遘ｻ蜍包ｼ・Venv-SetLocation縺瑚・蜍輔〒繧｢繧ｯ繝・ぅ繝吶・繝茨ｼ・
        Set-Location $pA
        
        # 讀懆ｨｼ
        $env:VIRTUAL_ENV | Should -Not -BeNullOrEmpty
        $env:VIRTUAL_ENV | Should -BeLike "*project-A*\.venv"
    }

    It 'off: does not auto-activate' {
        $pB = Join-Path $script:TestRoot 'project-B'
        New-Item -ItemType Directory -Force -Path $pB | Out-Null
        New-DummyVenv -ProjectPath $pB

        # auto 繝｢繝ｼ繝峨ｒ辟｡蜉ｹ蛹・
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

        # 蜷後§繝・ぅ繝ｬ繧ｯ繝医Μ縺ｧ蜀榊ｺｦRefresh
        PVenv-Refresh
        $env:VIRTUAL_ENV | Should -Be $beforeVenv  # 螟牙喧縺ｪ縺・

        # 繝ｫ繝ｼ繝亥､悶∈遘ｻ蜍包ｼ・Venv-SetLocation縺瑚・蜍輔〒髱槭い繧ｯ繝・ぅ繝門喧・・
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
        
        # "profile" 縺ｾ縺溘・ "project" 繧貞性繧縺薙→繧堤｢ｺ隱・
        $txt | Should -Match '\b(profile|project|path)\b'
    }

    It 'Set-ProjectsRoot: changes global root' {
        $newRoot = Join-Path $script:TestRoot 'new-root'
        New-Item -ItemType Directory -Force -Path $newRoot | Out-Null
        
        Set-ProjectsRoot -Path $newRoot | Out-Null
        
        # 螳悟・豁｣隕丞喧・育洒邵ｮ繝代せ/譛ｫ蟆ｾ蛹ｺ蛻・ｊ縺ｮ驕輔＞繧貞精蜿趣ｼ・
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
        
        # 蟄舌・繝ｭ繧ｸ繧ｧ繧ｯ繝医∈遘ｻ蜍・
        Set-Location $child
        
        # 譛繧りｿ代＞.venv縺悟━蜈医＆繧後ｋ縺ｹ縺・
        $env:VIRTUAL_ENV | Should -BeLike "*child-proj*\.venv"
    }

    It 'does not activate if .venv is missing Scripts' {
        $pX = Join-Path $script:TestRoot 'broken-proj'
        New-Item -ItemType Directory -Force -Path $pX | Out-Null
        
        # .venv縺ｯ菴懊ｋ縺郡cripts縺ｯ菴懊ｉ縺ｪ縺・
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
        
        # 蝓ｺ譛ｬ逧・↑繝励Ο繝輔ぃ繧､繝ｫ諠・ｱ縺悟性縺ｾ繧後※縺・ｋ縺・
        $out | Should -Match '\b(profile|Global|Project|Effective)\b'
    }

    It 'Set-ResourceProfile: validates preset values' {
        $pProf = Join-Path $script:TestRoot 'profile-preset-test'
        New-Item -ItemType Directory -Force -Path $pProf | Out-Null
        Set-Location $pProf
        
        # balanced 繝励Μ繧ｻ繝・ヨ繧定ｨｭ螳・
        { Set-ResourceProfile -Scope Project -Profile balanced } | Should -Not -Throw
        
        # 險ｭ螳壹ヵ繧｡繧､繝ｫ縺御ｽ懈・縺輔ｌ縺溘％縺ｨ繧堤｢ｺ隱・
        $profilePath = Join-Path $pProf '.pvenv.profile.json'
        Test-Path $profilePath | Should -Be $true
    }
}
