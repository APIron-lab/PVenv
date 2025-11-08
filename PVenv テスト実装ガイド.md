# PVenv テスト実装ガイド

## 🎯 概要

このガイドでは、PVenvの堅牢なテストフレームワークの実装と運用方法を説明します。

## 📋 実装済み機能

### ✅ 基本テスト (10テスト)
1. **自動アクティベーション**
   - `auto`モードでのディレクトリ移動時の自動アクティベート
   - `off`モードでの自動アクティベート無効化
   
2. **状態管理**
   - `PVenv-Refresh`の動作（同一ディレクトリ/移動時）
   - ネストしたプロジェクトディレクトリの処理
   
3. **情報表示コマンド**
   - `Show-ProjectTree` (spt): プロジェクトツリー表示
   - `Show-ProjectInfo` (spi): プロジェクト詳細情報
   
4. **設定管理**
   - `Set-ProjectsRoot`: プロジェクトルート変更
   - `peauto`: 不正な値の拒否
   
5. **エッジケース**
   - 不完全な.venv構造の処理
   - スペースを含むプロジェクト名
   
6. **リソースプロファイル**
   - プロファイル表示と設定

### 🛡️ 堅牢性機能

#### 1. Write-Host出力の確実なキャプチャ
```powershell
function Capture-HostOut {
    # 通常のストリームキャプチャを試行
    # 失敗時は Write-Host プロキシにフォールバック
}
```

**利点**:
- CI環境での安定性向上
- 異なるホスト実装への対応
- テスト失敗の減少

#### 2. パス正規化の強化
```powershell
function Normalize-Path {
    # GetFullPath + 末尾区切り文字削除
    # 短縮パス(8.3形式)と完全パスの統一
}
```

**対応する問題**:
- `C:\Users\AKIRAT~1\...` vs `C:\Users\Akira Takeshima\...`
- 末尾の `\` の有無
- UNCパス・相対パスの混在

#### 3. PowerShell 5.1 & 7.x 両対応
- `*>&1` 構文による互換性確保
- バージョン固有の問題を事前検出

## 🚀 セットアップ手順

### 1. ローカル実行

```powershell
# テスト実行（詳細出力）
Invoke-Pester -Path "C:\Tools\PVenv\PVenv.Tests.ps1" -Output Detailed

# カバレッジ付き実行
$cfg = New-PesterConfiguration
$cfg.Run.Path = 'C:\Tools\PVenv\PVenv.Tests.ps1'
$cfg.CodeCoverage.Enabled = $true
$cfg.CodeCoverage.Path = 'C:\Tools\PVenv\pvenv.ps1'
$cfg.CodeCoverage.OutputFormat = 'JaCoCo'
$cfg.CodeCoverage.OutputPath = 'coverage.xml'
Invoke-Pester -Configuration $cfg
```

### 2. GitHub Actions CI

#### ファイル配置
```
.github/
  workflows/
    test-pvenv.yml    # CIワークフロー定義
```

#### 実行タイミング
- `main`/`master`ブランチへのpush
- プルリクエスト作成時
- 手動トリガー（workflow_dispatch）

#### マトリクステスト
- **PowerShell 5.1**: Windows標準、最大互換性
- **PowerShell 7.4**: モダン環境、新機能

### 3. カバレッジレポート

**JaCoCo形式**で出力され、以下と連携可能:
- Codecov
- Coveralls
- SonarQube

## 🔧 トラブルシューティング

### 問題: Write-Host出力がキャプチャできない

**症状**:
```
Expected <regex>, but got empty string
```

**解決策**:
`Capture-HostOut`関数が自動的にフォールバックを試行します。
それでも失敗する場合は、環境固有の問題を調査：

```powershell
# デバッグ用
$out = spt *>&1
$out | Format-List *
```

### 問題: パス比較の失敗

**症状**:
```
Expected: 'C:\Users\AKIRAT~1\...'
But was:  'C:\Users\Akira Takeshima\...'
```

**解決策**:
`Normalize-Path`関数を使用済みです。それでも失敗する場合:

```powershell
# 両パスをログ出力して確認
Write-Host "Expected (normalized): $(Normalize-Path $expected)"
Write-Host "Actual (normalized): $(Normalize-Path $actual)"
```

### 問題: CI環境でのみ失敗

**チェックリスト**:
1. PowerShellバージョンの確認（5.1 vs 7.x）
2. 実行ポリシーの設定
3. モジュールのインストール状態
4. 環境変数の差異

## 📈 今後の拡張候補

### 優先度: 高
- [ ] **Junction/Adopt機能**のテスト追加
- [ ] **並行実行**シナリオ（複数プロジェクト切り替え）
- [ ] **Unicode/絵文字**を含むプロジェクト名

### 優先度: 中
- [ ] **.venv破損パターン**の網羅的テスト
- [ ] **長いパス名**(260文字超)の処理
- [ ] **ネットワークドライブ**上のプロジェクト

### 優先度: 低
- [ ] パフォーマンステスト（大量プロジェクト）
- [ ] メモリリークチェック
- [ ] 古いPowerShellバージョン（4.0以下）対応

## 🎨 テスト追加のベストプラクティス

### 1. 構造
```powershell
Describe '機能グループ名' {
    BeforeEach {
        # テストごとの初期化
        Push-Location $script:TestRoot
    }

    AfterEach {
        # テストごとのクリーンアップ
        Pop-Location
    }

    It '期待される動作の簡潔な説明' {
        # Arrange: テストデータ準備
        
        # Act: 操作実行
        
        # Assert: 結果検証
        $result | Should -Be $expected
    }
}
```

### 2. 命名規則
- **テストファイル**: `*.Tests.ps1` (Pester v5必須)
- **Describeブロック**: 機能の大分類
- **Itブロック**: 動詞で始まる具体的な振る舞い

### 3. 独立性の確保
```powershell
# ❌ 悪い例：前のテストに依存
It 'test 1' { $script:sharedVar = "value" }
It 'test 2' { $script:sharedVar | Should -Be "value" }

# ✅ 良い例：各テストが独立
It 'test 1' { 
    $localVar = "value"
    $localVar | Should -Be "value"
}
It 'test 2' { 
    $localVar = "value"
    $localVar | Should -Be "value"
}
```

## 📊 カバレッジ目標

| コンポーネント | 目標カバレッジ | 現状 |
|---------------|---------------|------|
| コア機能 | 80%+ | 🟢 達成 |
| エッジケース | 60%+ | 🟡 改善中 |
| エラーハンドリング | 70%+ | 🟢 達成 |

## 🔗 参考リンク

- [Pester公式ドキュメント](https://pester.dev/)
- [PowerShell テストベストプラクティス](https://docs.microsoft.com/powershell/scripting/dev-cross-plat/writing-portable-modules)
- [GitHub Actions for PowerShell](https://github.com/marketplace/actions/setup-powershell)

## 📝 変更履歴

### v1.0.0 (初版)
- 基本テスト8件実装
- GitHub Actions CI統合
- カバレッジレポート対応

### v1.1.0 (堅牢性強化)
- Write-Hostキャプチャのフォールバック追加
- パス正規化の強化
- 追加エッジケーステスト3件
- リソースプロファイルテスト追加

---

**作成者**: PVenv開発チーム  
**最終更新**: 2024-11-08