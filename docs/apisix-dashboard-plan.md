# APISIX Dashboard 導入計画

## 概要

開発環境では APISIX Dashboard を internal-only で提供し、ローカル開発者が `az containerapp port-forward` を使ってアクセス。本番環境では Dashboard を除外し、スクリプト運用で統一。

## 現在状態

- APISIX + etcd: co-locate（単一 Container App）
- ルート管理: スクリプト（`scripts/register-routes.sh` など）
- 管理経路: `make routes` / `make routes-apply`

## 目標状態

### 開発環境
- APISIX Dashboard: internal ingress で ACA 内にのみ露出
- 開発者: `az containerapp port-forward` で `localhost:9000` にフォワード
- 用途: ルート確認、試験的な編集（実装・テスト用）

### 本番環境
- Dashboard: 除外（コンテナから削除）
- ルート管理: スクリプト + etcd による declarative 運用
- 管理経路: CLI のみ（ポートフォワードは RBAC で禁止）

## 実装概要

### 1. APISIX + Dashboard co-locate 構成

```yaml
# apisix/containerapp.yaml の containers セクション

containers:
  - name: apisix
    image: apache/apisix:3.x
    resources:
      cpu: 0.5
      memory: 1Gi
    ports:
      - containerPort: 9080  # API Gateway
      - containerPort: 9180  # Admin API
    ...

  - name: etcd
    image: quay.io/coreos/etcd:v3.x
    resources:
      cpu: 0.5
      memory: 1Gi
    ...

  - name: dashboard
    image: apache/apisix-dashboard:3.x
    resources:
      cpu: 0.25
      memory: 512Mi
    ports:
      - containerPort: 9000  # Dashboard
    env:
      - name: APISIX_ADMIN_API_URI
        value: "http://127.0.0.1:9180"
    ...
```

### 2. 選択的デプロイ

デプロイスクリプト側で環境変数で Dashboard の有無を制御：

```bash
# apisix/deploy.sh

ENABLE_DASHBOARD="${ENABLE_DASHBOARD:-false}"

if [[ "$ENABLE_DASHBOARD" == "true" ]]; then
  # dashboard コンテナを含める
  export TEMPLATE_PATH="apisix/containerapp-with-dashboard.yaml"
else
  # dashboard を除く standard テンプレート
  export TEMPLATE_PATH="apisix/containerapp.yaml"
fi
```

### 3. Ingress 設定

- 外部 ingress は APISIX ゲートウェイ port 9080 のみ
- Dashboard は internal ingress のみ（port 9000）

```yaml
ingress:
  - name: gateway
    external: true
    targetPort: 9080

  - name: dashboard
    external: false  # internal-only
    targetPort: 9000
```

### 4. 開発者向け使用方法

#### 4-1. Dashboard にアクセス

```bash
# 別ターミナルで port-forward を起動（バックグラウンド）
az containerapp port-forward \
  --resource-group "$RESOURCE_GROUP" \
  --name "$GATEWAY_APP" \
  --port 9000:9000 &

# localhost:9000 で Dashboard を開く
# ブラウザ: http://localhost:9000

# port-forward を停止
kill %1
```

#### 4-2. Dashboard でのルート確認

- 左パネル: Routes
- ビジュアルで現在のルート定義を確認
- 必要に応じて URI パターン、plugins を確認

#### 4-3. 試験的な編集

- Dashboard で新ルートを試験作成
- `curl` で動作確認
- 本確定後は `scripts/register-routes.sh` に追加して Git 管理

### 5. 本番環境での除外

本番デプロイ時：

```bash
ENABLE_DASHBOARD=false make deploy-apisix
```

または `.env` で固定：

```env
ENABLE_DASHBOARD=false
```

## セキュリティ / RBAC 考察

### 開発環境

- Dashboard へのアクセス: 開発者のローカルマシンのみ
- port-forward: 開発チームに `Microsoft.App/containerApps/startPortForward/action` を許可

### 本番環境

- port-forward: RBAC で明示的に禁止（または Deny ポリシーで拒否）
- 関連操作: 管理者のみ `az containerapp exec` 許可
- Dashboard コンテナ: 削除されているため問題なし

## 実装タイミング

### Phase 1: 計画書確認（現在）
- ✅ 構成案、手順、セキュリティ方針を確認

### Phase 2: 実装（後日、決定後）
1. `apisix/containerapp-with-dashboard.yaml` を別テンプレートとして作成
2. `apisix/deploy.sh` に `ENABLE_DASHBOARD` 制御を追加
3. ドキュメント: [verification.md](verification.md) に port-forward 手順を追加
4. `Makefile` に `dashboard-access` ターゲットを追加（簡便化）

## 代替案：etcd 分離 + Dashboard

**現在の推奨外（後の段階）:**
- etcd を独立 Container App へ分離
- APISIX は etcd との通信を VNet 内部で実施
- snapshot 定期取得を Blob Storage に保管

このパターンは「ルート定義を複数環境で同期したい」「APISIX クラスタ化する」といった要件が出てきた時に検討。現段階では co-locate サイドカー案で十分。

## 関連ドキュメント

- [docs/vnet-first-checklist.md](vnet-first-checklist.md) - ネットワーク境界の設計
- [docs/verification.md](verification.md) - 実行手順（port-forward 追加予定）
