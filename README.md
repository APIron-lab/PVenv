# PVenv - PowerShell-native Python venv manager

![PVenv CI](https://github.com/APIron-lab/PVenv/actions/workflows/test-pvenv.yml/badge.svg)
![PowerShell](https://img.shields.io/badge/PowerShell-5.1%20%7C%207.4-blue)
![Coverage](https://codecov.io/gh/APIron-lab/PVenv/branch/main/graph/badge.svg)
![License](https://img.shields.io/github/license/APIron-lab/PVenv)

**PVenv** は、PowerShellでPython仮想環境を快適に管理するための軽量ツールです。  
フォルダ移動だけで `.venv` を自動認識してアクティベートし、プロジェクト単位のリソース制御を可能にします。

---

## ✨ 主な特徴

- 🚀 **自動アクティベーション**：ディレクトリ移動時に自動でvenvを有効化  
- ⚙️ **リソースプロファイル管理**：CPUコア・優先度・スレッド数をプロファイルで制御  
- 📦 **プロジェクト一元管理**：共通ルートを指定してvenvを整理  
- 🧪 **CI対応テスト済み**：PowerShell 5.1 / 7.4で自動テスト  
- 📈 **カバレッジ可視化**：Codecovによる品質トラッキング  

---

## 🧰 基本コマンド例

```powershell
# プロジェクト作成
npe MyProject

# 自動アクティベーションを有効化
peauto auto

# プロジェクト一覧表示
spt

# プロジェクト情報
spi

# リソースプロファイル設定
srp -Scope Project -Profile balanced

🧪 開発・テスト

ローカルでテストする場合：

Invoke-Pester -Path "PVenv.Tests.ps1" -Output Detailed


GitHub Actionsが自動で実行：

PowerShell 5.1 / 7.4 並列テスト

JaCoCo形式のカバレッジレポート生成

Codecovへ自動アップロード

🧩 導入方法

PVenvスクリプトを配置（例：C:\Tools\PVenv\pvenv.ps1）

PowerShellプロファイルへ以下を追加：

. "C:\Tools\PVenv\pvenv.ps1"


PowerShellを再起動して完了！

📊 開発状況
項目状態
✅ テスト自動化完了
✅ カバレッジ可視化Codecov連携済み
🔄 Junction/Adopt 機能実装予定
🧩 CLI改善検討中

Author: APIron-lab
License: MIT
Version: 0.6.4
