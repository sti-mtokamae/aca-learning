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
    "openjdk"              ; Java（バージョン指定なし）
    "maven"                ; Maven（バージョン指定なし）
    "docker"               ; Docker CLI
    "git"                  ; Git
    "jq"                   ; JSON parser（ログ整形用）
  ))
```

**注:** バージョン指定なし（`openjdk` ではなく `openjdk@21` など）により、ローカルと GitHub runner 間での環境差分を最小化。

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

詳細は **Phase 0** の「GitHub Secrets & OIDC セットアップ」を参照してください。

**概要:**
- GitHub Secrets で秘密情報を管理（CI/CD workflows で `${{ secrets.* }}` として参照）
- Azure OIDC で GitHub → Azure 認証（Service Principal 不要）
- ACR push 権限を GitHub Managed Identity に付与

これらはすべて Phase 0 で一度だけ設定します。

## 実装フェーズ

### Phase 0: GitHub Secrets & OIDC セットアップ（初回のみ）

このセクションは **最初に一度だけ実行** してください。Azure OIDC連携と GitHub Secrets登録は workflow実行の前提です。

#### 0-1. 前提条件

- GitHub リポジトリへのアクセス権（Settings 可能）
- Azure `az` CLI でログイン済み
- `gh` CLI インストール済み

#### 0-2. GitHub CLI でログイン

```bash
# 初回のみ
gh auth login

# リポジトリ確認
gh repo view --json name
```

#### 0-3. GitHub Secrets 登録

ローカル `.env` から値を読み込み、`gh` CLI で登録します：

```bash
cd /home/mtok/dev.home/aca-learning

# .env をロード
set -a
source .env
set +a

# Secrets を登録（上書き可能）
gh secret set AZURE_CLIENT_ID --body "$AZURE_CLIENT_ID"
gh secret set AZURE_TENANT_ID --body "$AZURE_TENANT_ID"
gh secret set AZURE_SUBSCRIPTION_ID --body "$AZURE_SUBSCRIPTION_ID"
gh secret set RESOURCE_GROUP --body "$RESOURCE_GROUP"
gh secret set ACR_NAME --body "$ACR_NAME"
gh secret set APP_SECURITY_USERNAME --body "$APP_SECURITY_USERNAME"
gh secret set APP_SECURITY_PASSWORD --body "$APP_SECURITY_PASSWORD"
gh secret set APP_JWT_SECRET --body "$APP_JWT_SECRET"
gh secret set APISIX_ADMIN_KEY --body "$APISIX_ADMIN_KEY"
gh secret set ACA_ENV_NAME --body "$ACA_ENV_NAME"

# 登録確認
gh secret list
```

**注意:**
- Secrets は GitHub UI でも確認可能（Settings → Secrets and variables → Actions）
- 一度登録後は値は読み出し不可（Masked される）
- 変更時は `gh secret set` で上書き

#### 0-4. Azure OIDC 連携設定

GitHub Actions で Azure に OIDC で認証するため、Azure 側に Federated Credential を登録：

```bash
# Azure で Managed Identity を作成（未作成の場合）
az identity create \
  --resource-group "$RESOURCE_GROUP" \
  --name github-ci-identity

# Federated Credential を登録（main ブランチ）
az identity federated-credential create \
  --resource-group "$RESOURCE_GROUP" \
  --identity-name github-ci-identity \
  --issuer "https://token.actions.githubusercontent.com" \
  --subject "repo:$(gh repo view --json nameWithOwner -q):ref:refs/heads/main" \
  --audience "api://AzureADTokenExchange"

# 確認
az identity federated-credential list \
  --resource-group "$RESOURCE_GROUP" \
  --identity-name github-ci-identity
```

#### 0-5. ACR push 権限付与

GitHub Actions の Identity に ACR push 権限を付与：

```bash
# Managed Identity のクライアント ID を取得
CLIENT_ID=$(az identity show \
  --resource-group "$RESOURCE_GROUP" \
  --name github-ci-identity \
  --query clientId -o tsv)

# ACR リソース ID を取得
ACR_RESOURCE_ID=$(az acr show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$ACR_NAME" \
  --query id -o tsv)

# Role assignment: ACR push
az role assignment create \
  --role AcrPush \
  --assignee "$CLIENT_ID" \
  --scope "$ACR_RESOURCE_ID"

# 確認
az role assignment list \
  --assignee "$CLIENT_ID" \
  --scope "$ACR_RESOURCE_ID"
```

#### 0-5a. Container App 読み取り/更新権限付与

**重要:** GitHub Actions から Container App を更新（`az containerapp update`）するには、Managed Identity に RBAC ロールが必要です。

```bash
# Managed Identity の PrincipalId を取得
PRINCIPAL_ID=$(az identity show \
  --resource-group "$RESOURCE_GROUP" \
  --name github-ci-identity \
  --query principalId -o tsv)

# Subscription ID を取得
SUBSCRIPTION_ID=$(az account show --query id -o tsv)

# リソースグループへの Contributor ロール割り当て
# （Container App read/write 権限を含む）
az role assignment create \
  --role "Contributor" \
  --assignee-object-id "$PRINCIPAL_ID" \
  --scope "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP"

# または、より最小権限の場合は特定スコープを指定：
# --scope "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.App/containerApps"

# 確認
az role assignment list \
  --assignee-object-id "$PRINCIPAL_ID" \
  --resource-group "$RESOURCE_GROUP"
```

**理由:**
- `az containerapp update` は `Microsoft.App/containerApps/write` 権限が必要
- Federated Credential だけでは権限不足 → RBAC ロール割り当てが必須
- CI/CD パイプラインが "无可用权限" エラーで失敗する原因の多くがこの漏れ

#### 0-7. Environment protection rule（本番用）

GitHub の environment protection を設定（主に production デプロイ保護）:

**GitHub UI から:**
1. Settings → Environments → Create environment
2. Environment name: `production`
3. Required reviewers: チェック（2以上推奨）
4. Deployment branches: 制限対象ブランチ（main のみなど）
5. Secrets: このリポジトリの secrets を使用可能

**確認:**
```bash
gh api repos/{owner}/{repo}/environments/production
```

#### 0-8. セットアップ確認チェックリスト

```bash
# すべてが完了したか確認
echo "=== GitHub Secrets ===" 
gh secret list

echo ""
echo "=== Azure Managed Identity ==="
az identity show \
  --resource-group "$RESOURCE_GROUP" \
  --name github-ci-identity

echo ""
echo "=== Federated Credentials ==="
az identity federated-credential list \
  --resource-group "$RESOURCE_GROUP" \
  --identity-name github-ci-identity

echo ""
echo "=== ACR Role Assignments ==="
CLIENT_ID=$(az identity show \
  --resource-group "$RESOURCE_GROUP" \
  --name github-ci-identity \
  --query clientId -o tsv)
az role assignment list \
  --assignee "$CLIENT_ID"
```

すべてが揃ったら **Phase 1 に進みます。**

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

### Java バージョン不一致エラー

**症状:**
```
ERROR: OpenJDK Runtime Environment (build 25.0.2...)
```

**原因:**
- guix manifest で `openjdk@21` や `openjdk@17` を指定したが、runner 環境では異なるバージョン利用
- Dockerfile で固定バージョン（e.g., `FROM eclipse-temurin:17-jre-jammy`）を指定しており guix と不一致

**対策:**
```scheme
;; guix-manifest.scm - バージョン指定なし
(specifications->manifest
  '(
    "openjdk"    ; ← バージョンを指定しない
    "maven"
    "docker"
  ))
```

```dockerfile
# spring-hello/Dockerfile
FROM eclipse-temurin:latest    # ← :latest を使用
```

**理由:**
- 異なる環境間での互換性が高い
- 細粒度のバージョン固定が必要な場合は pom.xml で指定するだけで十分

### Azure CLI コマンドフラグエラー

**症状:**
```
ERROR: unrecognized arguments: -q
```

**原因:**
- GitHub Actions の Azure CLI では一部フラグが未サポート
- 特に `-q`（quiet）オプションは runner で使用できないことがある

**対策:**
```bash
# ❌ これは失敗
az acr login --name "$ACR_NAME" -q
az containerapp update --resource-group "$RG" --name "$APP" --image "$IMG" -q

# ✅ これは動作
az acr login --name "$ACR_NAME"
az containerapp update --resource-group "$RG" --name "$APP" --image "$IMG"
```

### RBAC 認可エラー（Container App 更新失敗）

**症状:**
```
ERROR: (AuthorizationFailed) The client '...' does not have authorization to perform action 
'Microsoft.App/containerApps/read' over scope '...'
```

**原因:**
- Managed Identity は作成済み
- Federated Credential は設定済み
- **RBAC ロール割り当てが漏れている** ← 最大の原因

**対策（必須）:**

```bash
# Managed Identity の PrincipalId を取得
PRINCIPAL_ID=$(az identity show \
  --resource-group "$RESOURCE_GROUP" \
  --name github-ci-identity \
  --query principalId -o tsv)

# Contributor ロールをリソースグループへ割り当て
az role assignment create \
  --role "Contributor" \
  --assignee-object-id "$PRINCIPAL_ID" \
  --scope "/subscriptions/$(az account show --query id -o tsv)/resourceGroups/$RESOURCE_GROUP"
```

**重要:**
- この RBAC セットアップは **初回セットアップ時に一度だけ実行**
- workflow には含めない（Azure リソース層の設定）

### Java Module System エラー（cglib compatibility）

**症状:**
```
ERROR: ... error: cannot find symbol: class EnhancedConfigurationComparator ...
```

**原因:**
- Spring Boot + cglib + Java 9+ の module system 互換性問題

**対策:**
```bash
# scripts/ci-pipeline.sh 内で設定
export MAVEN_OPTS="--add-opens java.base/java.lang=ALL-UNNAMED"
mvn clean package -DskipTests
```

### Docker build が失敗

```bash
# guix shell 内では stdin が限定されるため、
# Dockerfile が stdin から入力を期待していると失敗することがある
# 対策：Dockerfile 内の RUN コマンドで non-interactive にする
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
