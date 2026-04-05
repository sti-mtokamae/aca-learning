# CI/CD パイプライン - Guix + GitHub Actions

## 概要

ビルド・テスト・デプロイを再現可能な環境で実行。

```
ローカル開発           CI/CD パイプライン
guix shell
  ↓                   GitHub Actions
guix-manifest.scm → Ubuntu runner
  ↓                      ↓
scripts/ci-pipeline.sh → guix shell
  ↓                      ↓
Maven build          Maven build
Docker build         Docker build
  ↓                      ↓
ACR push ← ← ← ← ← ACR push
  ↓
az containerapp update
  ↓
ACA デプロイ完了
```

**デザイン原則:**
- 環境差分をなくす（ローカルと CI で同じ build）
- YAML は宣言的（構成 + trigger）、ロジックは shell script に
- Guix で再現可能性を確保

## ローカル開発

### 1. Guix マニフェスト作成

```scheme
;; guix-manifest.scm
(specifications->manifest
  '(
    "openjdk@21"           ; Java
    "maven@3.8"            ; Maven
    "docker@20"            ; Docker CLI
    "git@2"                ; Git
    "jq@1"                 ; JSON parser（ログ整形用）
  ))
```

### 2. ビルド環境起動

```bash
# 初回のみ（依存をダウンロード）
guix shell -m guix-manifest.scm

# 環境内で実行
mvn -v
docker --version
az --version
```

### 3. CI パイプラインスクリプト

```bash
# scripts/ci-pipeline.sh （新規作成）
#!/bin/bash
set -euo pipefail

# 前提：guix shell 内で実行
# 用途：ローカル開発と GitHub Actions の両方

TARGET_ENV="${1:-dev}"  # dev / staging / prod
BUILD_NUMBER="${2:-0}"

echo "=== Build Pipeline: $TARGET_ENV ==="

# 前提チェック
if [[ ! -f .env ]]; then
  echo "ERROR: .env not found"
  exit 1
fi

set -a
source .env
set +a

# Phase 1: Maven ビルド
echo "[1/4] Maven build..."
cd spring-hello
mvn clean package -DskipTests
cd ..

# Phase 2: Docker イメージ作成
echo "[2/4] Docker build..."
cd spring-hello
docker build -t aca-hello-api:$BUILD_NUMBER .
cd ..

# Phase 3: ACR にログイン＆ push
echo "[3/4] ACR login & push..."
REGISTRY="${ACR_NAME}.azurecr.io"
docker tag aca-hello-api:$BUILD_NUMBER $REGISTRY/aca-hello-api:$BUILD_NUMBER
docker tag aca-hello-api:$BUILD_NUMBER $REGISTRY/aca-hello-api:latest

# ACR ログイン（環境変数から自動）
az acr login --name "$ACR_NAME"

# Push
docker push $REGISTRY/aca-hello-api:$BUILD_NUMBER
docker push $REGISTRY/aca-hello-api:latest

# Phase 4: ACA へデプロイ
echo "[4/4] ACA deploy..."

case "$TARGET_ENV" in
  dev)
    # dev/test 環境: hello-api-vnet へ
    APP_NAME="hello-api-vnet"
    ENV_NAME="aca-test-env-vnet"
    ;;
  prod)
    # 本番: 手動 approval 後のみ実行
    # （GitHub Actions の環境保護ルール参照）
    APP_NAME="hello-api"
    ENV_NAME="aca-test-env"
    ;;
  *)
    echo "ERROR: Unknown environment $TARGET_ENV"
    exit 1
    ;;
esac

az containerapp update \
  --resource-group "$RESOURCE_GROUP" \
  --name "$APP_NAME" \
  --image $REGISTRY/aca-hello-api:$BUILD_NUMBER

echo "✅ Deploy complete to $APP_NAME in $ENV_NAME"
```

### 4. ローカルテスト実行

```bash
cd /home/mtok/dev.home/aca-learning

# 環境確認
set -a
source .env
set +a

# guix shell 内でスクリプト実行
guix shell -m guix-manifest.scm -- \
  ./scripts/ci-pipeline.sh dev "$(date +%s)"

# 実行中は ACR login, docker push, containerapp update が一気通貫で実行
```

## CI/CD パイプライン実装

### GitHub Actions Workflow

最小 YAML（ロジックは script 側）:

```yaml
# .github/workflows/build-and-deploy.yml
name: Build and Deploy to ACA

on:
  push:
    branches:
      - main
      - develop
  pull_request:
    branches:
      - main

jobs:
  build-and-deploy:
    runs-on: ubuntu-latest
    
    permissions:
      contents: read
      id-token: write  # OIDC
    
    environment:
      name: ${{ github.ref == 'refs/heads/main' && 'production' || 'development' }}
    
    steps:
      - name: Checkout
        uses: actions/checkout@v4
      
      - name: Setup Guix
        run: |
          # Ubuntu に Guix インストール（簡略版）
          sudo apt-get update
          sudo apt-get install -y guix
      
      - name: Azure login (OIDC)
        uses: azure/login@v1
        with:
          client-id: ${{ secrets.AZURE_CLIENT_ID }}
          tenant-id: ${{ secrets.AZURE_TENANT_ID }}
          subscription-id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}
      
      - name: Build and Deploy
        env:
          ACR_NAME: ${{ secrets.ACR_NAME }}
          RESOURCE_GROUP: ${{ secrets.RESOURCE_GROUP }}
          # その他の .env 値は secrets から
        run: |
          # .env を構築（secrets から）
          cat > .env << 'EOF'
          RESOURCE_GROUP=${{ secrets.RESOURCE_GROUP }}
          ACR_NAME=${{ secrets.ACR_NAME }}
          APP_SECURITY_USERNAME=${{ secrets.APP_SECURITY_USERNAME }}
          APP_SECURITY_PASSWORD=${{ secrets.APP_SECURITY_PASSWORD }}
          APP_JWT_SECRET=${{ secrets.APP_JWT_SECRET }}
          APISIX_ADMIN_KEY=${{ secrets.APISIX_ADMIN_KEY }}
          EOF
          
          # 環境判定
          TARGET_ENV="dev"
          if [[ "${{ github.ref }}" == "refs/heads/main" ]]; then
            TARGET_ENV="prod"
          fi
          
          # guix shell で実行
          guix shell -m guix-manifest.scm -- \
            ./scripts/ci-pipeline.sh "$TARGET_ENV" "${{ github.run_number }}"
```

### デプロイ戦略

| トリガー | ターゲット環境 | 自動/手動 | 備考 |
|---------|---------------|---------|------|
| push to `develop` | VNet test env (`hello-api-vnet`) | 自動 | 開発・検証用 |
| push to `main` | 本番 (`hello-api`) | **要承認** | RBAC + environment protection rule |
| PR | テストのみ | N/A | デプロイなし |

### 環境保護ルール

GitHub の Environment protection を設定（本番のみ）:

```
Settings → Environments → production
  ├─ Required reviewers: 2+ 
  ├─ Deployment branches: main only
  └─ Secrets: ACR_NAME, RESOURCE_GROUP, etc.
```

## セキュリティ / 認証

### GitHub Secrets 登録（必須）

GitHub Actions で使用する秘密情報を GitHub Secrets に登録：

```bash
cd /home/mtok/dev.home/aca-learning

# .env から値を読む（ローカルのみ、公開しない）
source .env

# gh CLI で登録（または GitHub UI から手入力）
gh secret set AZURE_CLIENT_ID --body "$AZURE_CLIENT_ID"
gh secret set AZURE_TENANT_ID --body "$AZURE_TENANT_ID"
gh secret set AZURE_SUBSCRIPTION_ID --body "$AZURE_SUBSCRIPTION_ID"
gh secret set ACR_NAME --body "$ACR_NAME"
gh secret set RESOURCE_GROUP --body "$RESOURCE_GROUP"
gh secret set APP_SECURITY_USERNAME --body "$APP_SECURITY_USERNAME"
gh secret set APP_SECURITY_PASSWORD --body "$APP_SECURITY_PASSWORD"
gh secret set APP_JWT_SECRET --body "$APP_JWT_SECRET"
gh secret set APISIX_ADMIN_KEY --body "$APISIX_ADMIN_KEY"

# 確認
gh secret list
```

**注意:**
- `.env` 値は絶対に Git に commit しない（`.gitignore` 対象）
- GitHub Secrets に登録された値は、Actions のログには出力されません
- Secrets 変更後は新しい Actions run から反映

### GitHub × Azure 連携（OIDC）

Azure 側設定（1回のみ）:

```bash
# Federated credential を登録
az identity federated-credential create \
  --resource-group "$RESOURCE_GROUP" \
  --identity-name "github-ci-identity" \
  --issuer "https://token.actions.githubusercontent.com" \
  --subject "repo:USERNAME/aca-learning:ref:refs/heads/main" \
  --audience "api://AzureADTokenExchange"
```

### ACR アクセス権限

```bash
# GitHub Actions の Managed Identity に ACR push 権限を付与
az role assignment create \
  --role AcrPush \
  --assignee <CLIENT_ID> \
  --scope <ACR_RESOURCE_ID>
```

## 実装フェーズ

### Phase 0: GitHub Secrets セットアップ（初回のみ）
- [ ] `gh auth login` で GitHub CLI ログイン
- [ ] `gh secret set` で全 secrets 登録（`.env` より）
- [ ] `gh secret list` で確認
- [ ] Azure OIDC 設定
- [ ] ACR push 権限付与

### Phase 1: ローカル確認（今週）
- [ ] `guix-manifest.scm` 作成
- [ ] `scripts/ci-pipeline.sh` 実装
- [ ] ローカルで `guix shell -m guix-manifest.scm -- ./scripts/ci-pipeline.sh dev` テスト
- [ ] 動作確認後、コミット

### Phase 2: GitHub Actions セットアップ（本番化前） 
- [ ] `.github/workflows/build-and-deploy.yml` 作成
- [ ] Environment protection rule 設定
- [ ] PR から test run で疎通確認

### Phase 3: 本番運用（安定化後）
- [ ] 承認フロー確立
- [ ] デプロイ履歴・ロールバック手順ドキュメント化
- [ ] 監視・アラート連携

## トラブルシューティング

### Guix shell が遅い

```bash
# 初回は依存ダウンロードで時間がかかる
# 2回目以降はキャッシュが効く
# GitHub Actions では runner イメージの中で毎回新規なので、
# 高速化のため guix packages を .tar.gz でキャッシュする検討も可能
```

### Docker build が失敗

```bash
# guix shell 内では stdin が限定されるため、
# Dockerfile が stdin から入力を期待していると失敗することがある
# 対策：Dockerfile 内の RUN コマンドで明示的に入力を指定
```

### ACR login エラー

```bash
# .env に ACR_NAME が設定されているか確認
# az acr login コマンドの前に `set -a; source .env; set +a` が実行されているか確認
```

## 参考資料

- [Guix Manual - Invoking guix shell](https://guix.gnu.org/manual/en/html_node/Invoking-guix-shell.html)
- [GitHub Actions - Using OpenID Connect](https://docs.github.com/en/actions/deployment/security-hardening-your-deployments/about-security-hardening-with-openid-connect)
- [Azure Container Registry - Authentication and authorization](https://learn.microsoft.com/en-us/azure/container-registry/container-registry-authentication)
