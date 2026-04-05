# Docs Index

- **Verification & Testing**: [verification.md](verification.md) - スモークテストと動作確認手順
- **VNet First Plan**: [vnet-first-checklist.md](vnet-first-checklist.md) - Dashboard導入前に進めるネットワーク先行チェック
- **APISIX Dashboard Plan**: [apisix-dashboard-plan.md](apisix-dashboard-plan.md) - Dashboard 導入検討（開発用 internal-only + 本番スクリプト運用）

この `docs/` 配下は、検証で確定した運用判断や移行方針を残す場所です。

## Reading Order

1. まず全体状況を確認: [vnet-first-checklist.md](vnet-first-checklist.md)
2. 実行コマンドを確認: [verification.md](verification.md)
3. 日次運用や背景はルートの [README.md](../README.md)

## Role Split

- [vnet-first-checklist.md](vnet-first-checklist.md): 進行管理、到達点、判断メモ
- [verification.md](verification.md): 実行コマンド、期待結果、トラブルシュート
- [../README.md](../README.md): 全体像、環境構成、主要コマンドの入口

## Current Focus

- 既存環境の日次運用: `make doctor` / `make smoke` / `make routes`
- VNet PoC の進行管理: `vnet-first-checklist.md`
- VNet 側の検証手順: `verification.md` の「VNet 環境での検証実行」
