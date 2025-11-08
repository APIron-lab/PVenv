# PVenv - PowerShell-native Python venv manager

![PVenv CI](https://github.com/APIron-lab/PVenv/actions/workflows/test-pvenv.yml/badge.svg)
![PowerShell](https://img.shields.io/badge/PowerShell-5.1%20%7C%207.4-blue)
![Coverage](https://codecov.io/gh/APIron-lab/PVenv/branch/main/graph/badge.svg)
![License](https://img.shields.io/github/license/APIron-lab/PVenv)

**PVenv** は、PowerShellでPython仮想環境を快適に管理するための軽量ツールです。
フォルダ移動だけで `.venv` を自動認識してアクティベートし、プロジェクト単位のリソース制御を可能にします。

---

## ✨ 主な特徴

* 🚀 **自動アクティベーション**：ディレクトリ移動時に `.venv` を自動有効化（デフォルトON）
* ⚙️ **リソースプロファイル管理**：CPUコア・優先度をJSONプロファイルで制御
* 📦 **プロジェクト一元管理**：共通ルートを指定してvenvを整理
* 🔗 **外部venvのAdopt**：`junction` / `shim` / `move` 方式で他環境を取り込み
* 🎨 **状態別カラー表示**：背景色非依存、前景色のみで明瞭に区別
* 💡 **プロンプト統合**：アクティブ時に `(venv)` を自動表示
* 🧪 **CI対応テスト済み**：PowerShell 5.1 / 7.4で自動テスト実施

---

## 🧰 基本コマンド

```powershell
# プロジェクト作成
npe MyProject

# 自動アクティベーション（既定でauto）
peauto auto

# プロジェクト一覧
spt

# プロジェクト詳細
spi

# プロジェクトルート変更
Set-ProjectsRoot 'C:\Projects'

# リソースプロファイル設定
srp -Scope Project -Profile balanced
```

### 💬 ステータス表示例（spt）

| 記号    | 意味               | 色   |
| ----- | ---------------- | --- |
| [A]   | Active (現在アクティブ) | 緑   |
| [V]   | venvあり           | シアン |
| [-]   | なし               | 灰   |
| [ERR] | エラー              | 赤   |

---

## 🧪 テストとCI

ローカルテスト：

```powershell
Invoke-Pester -Path "PVenv.Tests.ps1" -Output Detailed
```

GitHub Actions：

* PowerShell 5.1 / 7.4 並列テスト
* カバレッジ生成（JaCoCo形式）
* Codecovへ自動送信

---

## 🧩 導入方法

1. PVenvスクリプトを配置（例：`C:\Tools\PVenv\pvenv.ps1`）
2. PowerShellプロファイルへ以下を追加：

   ```powershell
   . "C:\Tools\PVenv\pvenv.ps1"
   ```
3. 再起動後、以下のように起動メッセージが表示されます：

   ```
   [PVenv v0.6.8a] ProjectsRoot: C:\Projects | Auto: auto
   ```

---

## 📊 開発状況

| 項目                    | 状態          |
| --------------------- | ----------- |
| ✅ テスト自動化              | 完了          |
| ✅ カバレッジ可視化            | Codecov連携済み |
| ✅ Junction / Adopt 機能 | 実装済み        |
| ✅ CLI改善               | 完了          |
| 🧩 GUIブラウザ            | 検討中         |

---

**Author:** APIron-lab
**License:** MIT
**Version:** 0.6.8a

---