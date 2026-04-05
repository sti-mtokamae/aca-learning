# VNet先行チェックリスト（ACA + APISIX）

このチェックリストは、APISIX Dashboard導入より前にネットワーク境界を固めるための最小手順です。
現行構成（`apisix-gateway` 外部公開、`hello-api` 内部利用）を前提にしています。

## 現在ステータス（2026-04-05）

- このドキュメントは **実施ログ付きテンプレート**。
- **セキュリティ**: 実環境値は `.env.vnet-checklist` （`.gitignore` 対象）に記録。本ドキュメントはプレースホルダーのみ。
- Section 1-2: 実施ガイド確定
- Section 3: VNet/Subnet/NSG 作成手順を `make vnet-poc` に統一
- Section 4: VNet 統合環境で `doctor` / `smoke` / `routes` 検証を実施済み
- Section 5: Dashboard導入条件を PoC 観点で確認済み
- 次段階：Dashboard PoC の要否判断（スクリプト運用継続か、UI運用へ拡張か）
- 下記チェックボックスを実施順に埋める。

## 実施ログ

- 実施日: `<YYYY-MM-DD>`
- 実施者: `<YOUR_NAME>`
- 対象環境（RG/ACA Env）: `<RESOURCE_GROUP>` / `<ACA_ENV_NAME>`
- 変更チケット/PR: `<TICKET_OR_PR_URL>`
- 備考: VNet導入前ベースラインとして `make doctor` / `make smoke` / `make routes` 実行済み

**注記:** 実際の環境値は `.env.vnet-checklist` に記録してください（`.gitignore` 対象）

## このドキュメントの使い方

- ここでは「何を完了とみなすか」と「次に何を判断するか」を管理する。
- 実行コマンドの詳細は [verification.md](verification.md) を参照する。
- ローカル実値は `.env.vnet-checklist` にのみ記録し、この文書には残さない。

## 1. 先に決めること（設計）

- [x] この検証は PoC とし、カスタムドメインは使わない。
- [x] Azure の既定 FQDN（`*.azurecontainerapps.io`）をそのまま使う。
- [x] 外部公開するアプリは `apisix-gateway` のみとする。
- [x] `hello-api` は internal ingress のまま維持する。
- [x] APISIX Admin API（`9180`）は外部公開しない。
- [x] 管理操作（ルート確認・再投入）は運用経路を限定する。
- [x] VNet の主目的は内部コンテナ間通信と、Azure サービス接続（例: Azure Storage Files）に置く。

### 補足: internal ingress と VNet の役割

- internal ingress:
	- ACA アプリを外部公開しないための設定。
	- 同じ ACA Environment 内のアプリ間通信（internal FQDN）には通常これで対応できる。
- VNet:
	- 通信の到達範囲と経路をネットワーク単位で制御するための基盤。
	- 他ネットワークや Azure サービス（例: Private Endpoint 経由の Storage Files）との私設接続で効く。
	- NSG/UDR などの境界制御を使いたい場合に必要。

要点:
- 「hello-api を外に出さない」は internal ingress の責務。
- 「どこにどう繋ぐかを厳密に制御する」は VNet の責務。

## 2. VNet導入前の現状固定

- [x] 日次確認を実行して、現状の正常値を記録する。

```bash
cd /home/mtok/dev.home/aca-learning
make doctor
make smoke
make routes
```

- [x] 以下を記録する（`.env.vnet-checklist` に記入）。
	- `RESOURCE_GROUP`
	- `ACA_ENV_NAME`
	- `GATEWAY_APP`
	- `HELLO_APP`
	- `GATEWAY_FQDN`
	- 現在の APISIX revision 名

記録方法：
```bash
cp .env.vnet-checklist.example .env.vnet-checklist
# .env.vnet-checklist を編集して実値を記入
```

（`.env.vnet-checklist` は `.gitignore` 対象のため公開されません）

## 3. ネットワーク境界の目標状態

- [x] インターネット -> `apisix-gateway:9080`（公開 ingress）のみ許可。
- [x] `apisix-gateway` -> `hello-api:443`（internal FQDN）を NSG で許可。
- [ ] `hello-api` -> Azure Storage Files（PoC は Public + IP制限、本番は Private Endpoint検討）
- [ ] `apisix-gateway` -> Azure Storage Files（同上）
- [ ] 管理者 -> Admin API / APISIX Dashboard（実装未定、当面 az exec は許可、踏み台は未配置）
- [ ] その他すべて deny-by-default をベースに NSG で実装。

### PoC での実装方針

| 責務 | PoC方針 | 備考 |
|------|--------|------|
| VNet作成 | 新規作成（ACA Environment 統合） | Workload Profiles + VNet 適用済み前提 |
| Subnet分け | 未実施（PoC は1 subnet） | 本番で ingress/workload/service に分ける |
| Storage接続 | Public + IP制限 | Private Endpoint は本番化時に検討 |
| 管理経路 | az exec 経由のみ | 踏み台/VPN は未準備 |
| Managed ID | 有効化済みが前提 | Storage/KeyVault アクセス予定 |
| NSG | 最小限（app-to-app + storage-out） | 本番で細粒度化 |

### Section 3 実行手順（PoC）

- [x] ローカル作業ファイルを準備する（未作成の場合のみ）

```bash
cd /home/mtok/dev.home/aca-learning
cp .env.vnet-checklist.example .env.vnet-checklist
# .env.vnet-checklist のプレースホルダーを実値で埋める
```

- [x] VNet / Subnet / NSG を作成する

```bash
cd /home/mtok/dev.home/aca-learning
make vnet-poc
```

- [x] 実行結果を記録する

記録項目（.env.vnet-checklist）:
- `VNET_NAME`
- `SUBNET_NAME`
- `NSG_NAME`
- `NEW_ACA_ENV_NAME`
- `DEPLOYMENT_DATE`

補足:
- `make vnet-poc` は `scripts/create-vnet-poc.sh` を実行する。
- 初回PoCでは deny ルールは自動追加しない（ACA 制御面の疎通確認を優先）。
- VNet 側の `doctor` / `smoke` / `routes` 実行方法は [verification.md](verification.md) の「VNet 環境での検証実行」を参照する。

## 4. VNet適用後の確認項目

- [x] 事前健全性確認

```bash
ENV_FILE=.env.vnet-runtime make doctor
```

- [x] データプレーン疎通

```bash
ENV_FILE=.env.vnet-runtime make smoke
```

- [x] 管理系確認

```bash
ENV_FILE=.env.vnet-runtime make routes
```

- [ ] ルート再投入（必要時のみ）

```bash
make routes-apply
```

- [x] 期待結果を満たす
	- `ENV_FILE=.env.vnet-runtime make smoke` が成功（login成功、`/hello` 成功、未認証 `403`）
	- `ENV_FILE=.env.vnet-runtime make routes` で route 一覧を確認
	- 旧環境（`apisix-gateway` / `hello-api`）の active revision を停止した状態でも、VNet側 smoke が成功

## 5. Dashboard導入の着手条件

以下を満たしたら Dashboard を検討する。

- [x] VNet境界と管理経路が確定している。
- [x] 日次確認（doctor/smoke/routes）が安定している（PoC範囲）。
- [x] ルート更新の責務を一本化できている（現時点はスクリプト運用）。

判断メモ:
- 現段階では「Dashboardなし（スクリプト運用）」でも要件を満たせる。
- Dashboard 導入は、運用者増加や手動ルート編集ニーズが出た時点で再評価する。
- **計画案**: [apisix-dashboard-plan.md](apisix-dashboard-plan.md) を参照（開発用 internal-only、本番ではスクリプト運用で統一）。

## 6. 運用ルール（推奨）

1. APISIXキー変更時は必ず `make rotate-apisix-key` を使う。
2. 変更後は `make smoke` を必ず実行する。
3. route定義変更時は `make routes-apply` 後に `make routes` で確認する。
4. 障害判定はデータプレーン（`make smoke`）を正とする。
