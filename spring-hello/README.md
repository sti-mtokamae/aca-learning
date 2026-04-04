# ACA Learning - Spring Boot + Clojure Hybrid API with JWT Auth

## Build and Deploy

### 1. ローカルビルド・テスト
```bash
cd /home/mtok/dev.home/aca-learning/spring-hello

# アプリケーションビルド
./build.sh

# ローカルテスト
docker run -p 8080:8080 aca-hello-api:latest

# 別ターミナルでテスト

# ログイン（トークン取得）
TOKEN=$(curl -s -X POST http://localhost:8080/api/auth/login \
  -H "Content-Type: application/json" \
  -d '{"username":"acauser","password":"REPLACE_ME_STRONG_PASSWORD"}' | jq -r '.token')

# トークン使用でAPI呼び出し
curl -H "Authorization: Bearer $TOKEN" http://localhost:8080/api/hello
curl -H "Authorization: Bearer $TOKEN" http://localhost:8080/api/hello/yourname

# ヘルスチェック（認証不要）
curl http://localhost:8080/actuator/health
```

### 2. ACA へデプロイ（推奨: スクリプト）
```bash
# 事前に /home/mtok/dev.home/aca-learning/.env を作成
# cp ../.env.example ../.env

# 必須: ACR_NAME, APP_SECURITY_PASSWORD, APP_JWT_SECRET
set -a
source ../.env
set +a

# 必要に応じて ACR_NAME だけ上書き
ACR_NAME=yourregistry \
./deploy-aca.sh
```

### 3. ACA 上の JWT 動作確認
```bash
APP_URL=https://hello-api.<your-fqdn> \
APP_SECURITY_USERNAME=acauser \
APP_SECURITY_PASSWORD=REPLACE_ME_STRONG_PASSWORD \
./verify-jwt-aca.sh
```

## API エンドポイント

### 公開エンドポイント
- `GET /actuator/health` - ヘルスチェック
- `GET /actuator/info` - アプリ情報

### 認証が必要なエンドポイント（Bearer token）
- `POST /api/auth/login` - ログイン、トークン取得
- `GET /api/hello` - Clojure制御のHello World
- `GET /api/hello/{name}` - Clojure制御のパーソナライズされた挨拶
- `GET /api/status` - ハイブリッドアプリの状態

## 認証方式：JWT（Bearer Token）

### ログインしてトークン取得
```bash
curl -X POST http://localhost:8080/api/auth/login \
  -H "Content-Type: application/json" \
  -d '{"username":"acauser","password":"REPLACE_ME_STRONG_PASSWORD"}'
```

応答例:
```json
{
  "token": "eyJhbGciOiJIUzI1NiJ9...",
  "username": "acauser",
  "type": "Bearer"
}
```

### トークンを使ってAPI呼び出し
```bash
curl -H "Authorization: Bearer <token>" http://localhost:8080/api/hello
```

## 構成メモ
- **Spring Boot**: 起動基盤、JWT 認証処理、既存 Java 資産接続の土台
- **Clojure**: `src/main/resources/com/example/acahello/hello_service.clj` で業務ロジック担当
- **JWT**: HS256 署名、秘密鍵は環境変数 `APP_JWT_SECRET` で指定
- **Java 側**: HTTP 入口と Clojure 呼び出しの薄いブリッジ

## トークン失効時間
デフォルト: 1 時間（3600000ms）  
環境変数 `APP_JWT_EXPIRATION` で調整可能

## 追加スクリプト
- `deploy-aca.sh`: ビルド、ACR push、Container App create/update を一括実行
- `verify-jwt-aca.sh`: ACA 上で login -> Bearer 呼び出し -> 未認証拒否まで確認