# Verification Guide - Running Smoke Tests

## Quick Path

最短確認は次の 2 パターンです。

- 既存環境を確認する:

```bash
cd /home/mtok/dev.home/aca-learning
make doctor
make smoke
make routes
```

- VNet 環境を確認する:

```bash
cd /home/mtok/dev.home/aca-learning

awk -F= '/^[A-Z0-9_]+=/ {print $0}' .env > .env.vnet-runtime
awk -F= '/^[A-Z0-9_]+=/ {print $0}' .env.vnet-checklist >> .env.vnet-runtime

NEW_ACA_ENV_NAME=$(awk -F= '/^NEW_ACA_ENV_NAME=/{print $2}' .env.vnet-checklist | tail -n1)
NEW_GATEWAY_APP=$(awk -F= '/^NEW_GATEWAY_APP=/{print $2}' .env.vnet-checklist | tail -n1)
NEW_HELLO_APP=$(awk -F= '/^NEW_HELLO_APP=/{print $2}' .env.vnet-checklist | tail -n1)

{
  echo "ACA_ENV_NAME=${NEW_ACA_ENV_NAME}"
  echo "GATEWAY_APP=${NEW_GATEWAY_APP}"
  echo "HELLO_APP=${NEW_HELLO_APP}"
} >> .env.vnet-runtime

ENV_FILE=.env.vnet-runtime make doctor
ENV_FILE=.env.vnet-runtime make smoke
ENV_FILE=.env.vnet-runtime make routes
```

手で curl を打つ詳細確認が必要なときだけ、この下の各セクションを使います。

## Prerequisites

### 1. .env ファイルの準備（必須）

```bash
cd /home/mtok/dev.home/aca-learning

# 既存されていない場合
if [ ! -f .env ]; then
  echo "ERROR: .env file not found"
  echo "Please create .env from .env.example and fill in actual values"
  exit 1
fi

# 以降のコマンドで .env を読み込む
set -a
source ./.env
set +a
```

### 2. 前提条件の確認

```bash
# 全コンテナアプリが Running 状態か確認
az containerapp list \
  --resource-group "$RESOURCE_GROUP" \
  --query "[].{name:name, state:properties.runningStatus}" \
  -o table

# Expected output（環境によってアプリ名は異なる）:
# Name                   State
# ------------------------------
# hello-api-vnet         Running
# apisix-gateway-vnet    Running
# (その他)
```

### 3. FQDN の確認

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
echo "API:     https://$API_FQDN"

# Expected:
# Gateway: FQDN で外部接続可能
# API: .internal で内部 ONLY（外部からはアクセス不可）
```

## Smoke Tests

### Test 1: JWT ログイン

```bash
GATEWAY="https://$GATEWAY_FQDN"

echo "=== Test 1: /auth/login ==="
LOGIN_RESPONSE=$(curl -fsS -X POST "$GATEWAY/auth/login" \
  -H "Content-Type: application/json" \
  -d "{\"username\":\"$APP_SECURITY_USERNAME\",\"password\":\"$APP_SECURITY_PASSWORD\"}")

TOKEN=$(echo "$LOGIN_RESPONSE" | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')

if [ -z "$TOKEN" ]; then
  echo "FAIL: token extraction failed"
  echo "Response: $LOGIN_RESPONSE"
  exit 1
fi

echo "PASS: token acquired (${#TOKEN} chars)"
```

### Test 2: 保護エンドポイント `/hello`

```bash
echo "=== Test 2: GET /hello (with token) ==="
RESPONSE=$(curl -fsS -H "Authorization: Bearer $TOKEN" "$GATEWAY/hello")
echo "$RESPONSE"

# Expected: Clojure via Spring Boot response
# Example: {"message":"Hello from ACA Learning via Clojure control!","timestamp":"...","service":"spring-clojure-hybrid-api","version":"1.0.0"}
```

### Test 3: ワイルドカードルート `/hello/{name}`

```bash
echo "=== Test 3: GET /hello/world (wildcard route) ==="
RESPONSE=$(curl -fsS -H "Authorization: Bearer $TOKEN" "$GATEWAY/hello/world")
echo "$RESPONSE"

# Expected: personalized response
# Example: {"message":"Hello world from Clojure on Spring Boot!","timestamp":"...","service":"spring-clojure-hybrid-api"}
```

### Test 4: ステータスエンドポイント

```bash
echo "=== Test 4: GET /status ==="
RESPONSE=$(curl -fsS -H "Authorization: Bearer $TOKEN" "$GATEWAY/status")
echo "$RESPONSE"

# Expected:
# {"status":"UP","control":"clojure","base":"spring-boot","timestamp":"..."}
```

### Test 5: 認可チェック（トークンなし）

```bash
echo "=== Test 5: GET /hello without token (expect 403) ==="
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "$GATEWAY/hello")

if [ "$HTTP_CODE" = "403" ]; then
  echo "PASS: HTTP 403 (unauthorized)"
else
  echo "FAIL: Expected 403, got $HTTP_CODE"
  exit 1
fi
```

## Automated Verification Scripts

### Option A: Recommended Commands

すべてのテストを一度に実行:

```bash
cd /home/mtok/dev.home/aca-learning

# 推奨: Make ターゲット（内部で scripts/smoke.sh を実行）
make smoke
```

or

```bash
cd /home/mtok/dev.home/aca-learning

set -a
source ./.env
set +a

GATEWAY_FQDN=$(az containerapp show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$GATEWAY_APP" \
  --query "properties.configuration.ingress.fqdn" -o tsv)

GATEWAY_URL="https://$GATEWAY_FQDN" ./apisix/verify-jwt-via-gateway.sh
```

or

```bash
cd /home/mtok/dev.home/aca-learning
set -a
source ./.env
set +a

GATEWAY_URL=$(az containerapp show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$GATEWAY_APP" \
  --query "properties.configuration.ingress.fqdn" -o tsv)
API_URL="https://$(az containerapp show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$HELLO_APP" \
  --query "properties.configuration.ingress.fqdn" -o tsv)" ./scripts/verify-jwt-direct.sh
```

### Option B: Direct Script Calls

```bash
# リポジトリルート
cd /home/mtok/dev.home/aca-learning

# .env を読み込む環境で実行
set -a
source ./.env
set +a

# Gateway 検証
GATEWAY_URL=$(az containerapp show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$GATEWAY_APP" \
  --query "properties.configuration.ingress.fqdn" -o tsv)

GATEWAY_URL="https://$GATEWAY_URL" ./apisix/verify-jwt-via-gateway.sh

# 直接 API 検証（内部アクセス限定のため、スクリプト内での az コマンド利用想定）
API_URL=$(az containerapp show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$HELLO_APP" \
  --query "properties.configuration.ingress.fqdn" -o tsv)

API_URL="https://$API_URL" ./scripts/verify-jwt-direct.sh
```

## VNet 環境での検証実行

既定のスクリプトは `.env` を読むため、VNet 側検証では一時的な実行用 env を作って `ENV_FILE` を切り替える。

```bash
cd /home/mtok/dev.home/aca-learning

# 1) 実行用 env を作成（ローカルのみ）
awk -F= '/^[A-Z0-9_]+=/ {print $0}' .env > .env.vnet-runtime
awk -F= '/^[A-Z0-9_]+=/ {print $0}' .env.vnet-checklist >> .env.vnet-runtime

NEW_ACA_ENV_NAME=$(awk -F= '/^NEW_ACA_ENV_NAME=/{print $2}' .env.vnet-checklist | tail -n1)
NEW_GATEWAY_APP=$(awk -F= '/^NEW_GATEWAY_APP=/{print $2}' .env.vnet-checklist | tail -n1)
NEW_HELLO_APP=$(awk -F= '/^NEW_HELLO_APP=/{print $2}' .env.vnet-checklist | tail -n1)

{
  echo "ACA_ENV_NAME=${NEW_ACA_ENV_NAME}"
  echo "GATEWAY_APP=${NEW_GATEWAY_APP}"
  echo "HELLO_APP=${NEW_HELLO_APP}"
} >> .env.vnet-runtime

# 2) VNet 側 smoke/routes
ENV_FILE=.env.vnet-runtime ./scripts/smoke.sh
ENV_FILE=.env.vnet-runtime ./scripts/routes.sh

# 3) make ターゲット経由でも同様
ENV_FILE=.env.vnet-runtime make doctor
ENV_FILE=.env.vnet-runtime make smoke
ENV_FILE=.env.vnet-runtime make routes
```

補足:
- `.env.vnet-runtime` は `.env.*` で ignore される（Git未追跡）。
- 検証後は不要なら `rm -f .env.vnet-runtime` で削除する。
- 旧環境停止後の確認でも同じ `.env.vnet-runtime` を使う。

## Troubleshooting

### Token で 401/403 が返る

```bash
# 1. credentials 確認
echo "USERNAME: $APP_SECURITY_USERNAME"
echo "PASSWORD: $APP_SECURITY_PASSWORD"
echo "JWT_SECRET length: ${#APP_JWT_SECRET}"

# 2. login エンドポイント直接テスト
curl -v -X POST "https://$GATEWAY_FQDN/auth/login" \
  -H "Content-Type: application/json" \
  -d "{\"username\":\"$APP_SECURITY_USERNAME\",\"password\":\"$APP_SECURITY_PASSWORD\"}"

# 3. APISIX ルート確認（推奨: make routes）
make routes

# 4. ルート再投入（必要時）
make routes-apply

# 5. 直接確認（補助）
az containerapp exec \
  --name "$GATEWAY_APP" \
  --resource-group "$RESOURCE_GROUP" \
  --container route-loader \
  --command "curl -sS -H X-API-KEY:$APISIX_ADMIN_KEY http://127.0.0.1:9180/apisix/admin/routes"

# NOTE:
# make routes は exec のリトライと route-loader ログのフォールバック確認を実装済みです。
# まれに管理プレーン都合で即時一覧取得できない場合でも、ルート登録完了ログを確認できます。
# データプレーン疎通は make smoke を正として確認してください。
```

### hello-api が internal で外から見えない

これは想定動作です。以下で確認:

```bash
# 内部 FQDN
API_FQDN=$(az containerapp show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$HELLO_APP" \
  --query "properties.configuration.ingress.fqdn" -o tsv)

echo "API FQDN: $API_FQDN"
# Expected: *.internal.* (内部のみ)

# 外部からアクセス試行（失敗することを確認）
curl -v https://$API_FQDN/api/health 2>&1 | grep -E "Connection refused|Couldn't resolve|timed out" || echo "Unexpected: resolved from outside"
```

## Test Results Example

```
[1] Login /auth/login
    => token 133 chars OK

[2] GET /hello (with token)
    => {"message":"Hello from ACA Learning via Clojure control!","timestamp":"2026-04-03T22:53:02.378065525","service":"spring-clojure-hybrid-api","version":"1.0.0"}

[3] GET /hello/world (wildcard route)
    => {"message":"Hello world from Clojure on Spring Boot!","timestamp":"2026-04-03T22:53:02.538689946","service":"spring-clojure-hybrid-api"}

[4] GET /status
    => {"status":"UP","control":"clojure","base":"spring-boot","timestamp":"2026-04-03T22:53:02.742576998"}

[5] GET /hello without token (expect 401 or 403)
    => HTTP 403
    => unauthorized correctly rejected

=== All smoke tests passed ===
```

## Next Steps

- パフォーマンステスト: load test scripts
- セキュリティ監査: Azure Security Center scan
- スケール検証: 複数レプリカ時の動作
- 本番化前チェックリスト: `vnet-first-checklist.md` の Section 5 を更新
