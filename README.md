# ACA学習ガイド: APISIX + etcd + Spring Boot/Clojure Hybrid

## 📋 学習目標
- Azure Container Apps (ACA) の基本操作
- マルチコンテナアプリケーション (APISIX + etcd)
- API Gateway のルーティング設定
- Spring Boot を土台にした Clojure ハイブリッド API の ACA デプロイ
- JWT 認証を含む API 保護の実装と確認

## 🗂 最新の検証記録
- VNet先行の移行手順: [docs/vnet-first-checklist.md](docs/vnet-first-checklist.md)
- ドキュメント一覧: [docs/README.md](docs/README.md)

## ✅ 現在の到達点
- 既存環境（`hello-api` / `apisix-gateway`）の運用コマンドは安定化済み
- VNet PoC ネットワーク作成（VNet/Subnet/NSG）を `make vnet-poc` で再実行可能化
- VNet 統合 ACA Environment への `hello-api-vnet` / `apisix-gateway-vnet` デプロイと smoke/routes 確認まで完了

## 🛠 日次運用コマンド

```bash
cd /home/mtok/dev.home/aca-learning

# 前提チェック（コマンド・.env・Azure疎通）
make doctor

# スモークテスト（JWT login -> /hello 200 -> 未認証 403）
make smoke

# APISIX ルート一覧確認（リトライ + ログフォールバック付き）
make routes

# ルート再投入（必要時）
make routes-apply

# APISIX_ADMIN_KEY ローテーション（デプロイ/再投入/スモーク/失敗時ロールバックを自動実行）
make rotate-apisix-key

# VNet PoC 用ネットワーク作成（VNet/Subnet/NSG）
make vnet-poc
```

## 🔀 VNet環境向け実行の要点

既存 `make` コマンドは既定で `.env` を読むため、VNet 側検証時は `ENV_FILE` を切り替えて実行します。

```bash
cd /home/mtok/dev.home/aca-learning

# .env + .env.vnet-checklist を合成したローカル実行用ファイルを作成
cat .env .env.vnet-checklist > .env.vnet-runtime
{
  echo "ACA_ENV_NAME=${NEW_ACA_ENV_NAME}"
  echo "GATEWAY_APP=${NEW_GATEWAY_APP}"
  echo "HELLO_APP=${NEW_HELLO_APP}"
} >> .env.vnet-runtime

# VNet側での確認
ENV_FILE=.env.vnet-runtime make doctor
ENV_FILE=.env.vnet-runtime make smoke
ENV_FILE=.env.vnet-runtime make routes
```

`.env.vnet-runtime` は `.env.*` に該当するため Git には含まれません。

## 🚀 実習手順

### 事前準備: 秘匿情報を `.env` に集約（必須）

```bash
cd /home/mtok/dev.home/aca-learning

# .env を作成
# a) 既に存在する場合（以前の作業から継続）
if [ -f .env ]; then
  echo ".env already exists"
  grep "^RESOURCE_GROUP\|^ACR_NAME\|^APP_JWT_SECRET" .env
else
  # b) 初回作成の場合
  cp .env.example .env
  
  # .env 内の REPLACE_ME_* をすべて実値に置換
  # 例：
  # - RESOURCE_GROUP=実際のRG名
  # - ACR_NAME=実際のACR名
  # - APP_SECURITY_PASSWORD=強い パスワード
  # - APP_JWT_SECRET=32文字以上のシークレット
  # - APISIX_ADMIN_KEY=APISIX管理キー
  
  echo "Please edit .env and fill in all REPLACE_ME_* values"
fi

# 検証: 必須変数がすべて設定されている
set -a
source ./.env
set +a

if [ -z "$RESOURCE_GROUP" ] || [ "$RESOURCE_GROUP" = "REPLACE_ME"* ]; then
  echo "ERROR: .env is not fully configured"
  exit 1
fi

echo "✓ .env is ready"
```

### Step 1: ACA環境構築
```bash
# 基本環境作成
az group create --name aca-learning-rg --location japaneast

az monitor log-analytics workspace create \
  --resource-group aca-learning-rg \
  --workspace-name aca-learning-logs

LOG_WORKSPACE_ID=$(az monitor log-analytics workspace show \
  --resource-group aca-learning-rg \
  --workspace-name aca-learning-logs \
  --query id -o tsv)

az containerapp env create \
  --name aca-learning-env \
  --resource-group aca-learning-rg \
  --location japaneast \
  --logs-workspace-id $LOG_WORKSPACE_ID
```

### Step 2: Spring Boot + Clojure Hybrid API デプロイ

**前提条件:**
- `.env` が準備済みであること
- `ACR_NAME`, `APP_SECURITY_PASSWORD`, `APP_JWT_SECRET` が設定済みであること

```bash
cd /home/mtok/dev.home/aca-learning/spring-hello

# .env を読み込む
set -a
source ../.env
set +a

# ビルドとデプロイを一括実行
# deploy-aca.sh は以下を自動実行:
# - mvn clean package
# - docker build & push to ACR
# - az containerapp create/update
./deploy-aca.sh

# 完了後、FQDN が表示される
# "App URL: https://hello-api...."
```

### Step 3: APISIX + etcd デプロイ

**前提条件:** `.env` が `/home/mtok/dev.home/aca-learning/.env` に存在すること

```bash
cd /home/mtok/dev.home/aca-learning

# .env 読み込み（必須）
set -a
source ./.env
set +a

# APISIX デプロイディレクトリへ移動
cd apisix

# APISIX + etcd をco-locate デプロイ
# deploy.sh は .env から APISIX_ADMIN_KEY を読む
./deploy.sh

# 結果確認
az containerapp show \
  --name "$GATEWAY_APP" \
  --resource-group "$RESOURCE_GROUP" \
  --query "properties.latestRevisionName" -o tsv
```

### Step 4: 動作確認

**前提条件:** `.env` が読み込まれていること（`source ./.env` を実施済み）

#### 4-1. FQDN の確認

```bash
GATEWAY_FQDN=$(az containerapp show \
  --name "$GATEWAY_APP" \
  --resource-group "$RESOURCE_GROUP" \
  --query "properties.configuration.ingress.fqdn" -o tsv)

API_FQDN=$(az containerapp show \
  --name "$HELLO_APP" \
  --resource-group "$RESOURCE_GROUP" \
  --query "properties.configuration.ingress.fqdn" -o tsv)

echo "Gateway: https://$GATEWAY_FQDN"
echo "API:     https://$API_FQDN (should be .internal.*)"
```

#### 4-2. スモークテスト（手動実行）

```bash
GATEWAY="https://$GATEWAY_FQDN"

# JWT ログイン
TOKEN=$(curl -fsS -X POST "$GATEWAY/auth/login" \
  -H "Content-Type: application/json" \
  -d "{\"username\":\"$APP_SECURITY_USERNAME\",\"password\":\"$APP_SECURITY_PASSWORD\"}" | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')

echo "Token: ${#TOKEN} chars"

# 保護エンドポイント (with token)
curl -fsS -H "Authorization: Bearer $TOKEN" "$GATEWAY/hello"
echo ""

# ワイルドカードルート
curl -fsS -H "Authorization: Bearer $TOKEN" "$GATEWAY/hello/world"
echo ""

# ステータス
curl -fsS -H "Authorization: Bearer $TOKEN" "$GATEWAY/status"
echo ""

# 認可チェック (without token → 403 expected)
curl -s -o /dev/null -w "HTTP %{http_code}\n" "$GATEWAY/hello"
```

#### 4-3. 自動化スクリプト

```bash
# 推奨: Make ターゲット
cd /home/mtok/dev.home/aca-learning
make smoke

# 必要時の補助コマンド
make doctor
make routes
make routes-apply
make rotate-apisix-key

# 直接実行する場合（make smoke の実体）
./scripts/smoke.sh

# 詳細なテストプロセス
# See: docs/verification.md
```

## 🔍 学習ポイント

### ACA の特徴理解
- **マルチコンテナサポート**: APISIX + etcd を1つのContainer Appで実行
- **自動スケーリング**: トラフィック量に応じた動的スケール
- **内蔵負荷分散**: 複数レプリカへの自動振り分け

### Hybrid 構成の理解
- **Spring Boot**: 起動、既存連携、将来の Spring Security 統合の土台
- **Clojure**: APIの制御ロジックを担当
- **Mavenベース**: 既存のJava資産と同じ管理系統を維持

### APISIX による API Gateway
- **動的ルーティング**: etcd でリアルタイム設定変更
- **プラグイン機能**: CORS、Rate Limiting、認証など
- **監視機能**: Prometheus メトリクス、ログ出力

### 運用監視
```bash
# Container Apps ログ確認
az containerapp logs show --name hello-api --resource-group aca-learning-rg --follow
az containerapp logs show --name apisix-gateway --resource-group aca-learning-rg --follow

# スケーリング状況
az containerapp revision list --name hello-api --resource-group aca-learning-rg
```

## 🧹 クリーンアップ
```bash
# 全リソース削除 (学習完了後)
az group delete --name aca-learning-rg --yes --no-wait
```

## 📚 次のステップ
1. PostgreSQL データベース接続
2. 複数テナント対応
3. CI/CD パイプライン構築
4. 監視・アラート設定

## 📁 ファイル構成
```
/home/mtok/dev.home/aca-learning/
├── spring-hello/
│   ├── pom.xml
│   ├── Dockerfile  
│   ├── build.sh
│   ├── README.md
│   └── src/main/java/com/example/acahello/
├── apisix/
│   ├── config.yaml
│   ├── containerapp.yaml
│   ├── deploy.sh
│   ├── setup-routes.sh
│   └── verify-jwt-via-gateway.sh
└── README.md (このファイル)
```