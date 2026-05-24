#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/load_config.sh
source "${ROOT_DIR}/lib/load_config.sh"

# =============================================================================
# SRE Playground — GCP 初期セットアップスクリプト
# 使い方: ./setup_gcp.sh [--config ./.sre_playground.env] [--project sre-playground-xxxx] [--region asia-northeast1] [--repository sre-playground]
# 冪等: 既に存在するリソースはスキップします
# =============================================================================

# --- デフォルト値 ---
CONFIG_FILE="${ROOT_DIR}/.sre_playground.env"
PROJECT_ID=""
REGION="asia-northeast1"
SA_NAME="terraform-runner"
CREDENTIALS_DIR="${ROOT_DIR}/credentials"
REPOSITORY_NAME="sre-playground"
SERVICE_NAME="sre-playground"

# --- カラー出力 ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
skip()  { echo -e "${YELLOW}[SKIP]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# --- 引数パース ---
usage() {
  echo "使い方: $0 [--config <FILE>] [--project <PROJECT_ID>] [--region <REGION>] [--repository <REPOSITORY_NAME>]"
  echo ""
  echo "  --config    設定ファイル（デフォルト: ./.sre_playground.env）"
  echo "  --project   GCP プロジェクト ID（設定ファイルでも指定可）"
  echo "  --region    リージョン（デフォルト: asia-northeast1）"
  echo "  --repository Artifact Registry リポジトリ名（デフォルト: sre-playground）"
  exit 1
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --config) CONFIG_FILE="$2"; shift 2 ;;
    *) break ;;
  esac
done

load_sre_playground_config "${CONFIG_FILE}"

while [[ $# -gt 0 ]]; do
  case $1 in
    --project) PROJECT_ID="$2"; shift 2 ;;
    --region)  REGION="$2";     shift 2 ;;
    --repository) REPOSITORY_NAME="$2"; shift 2 ;;
    --service-name) SERVICE_NAME="$2"; shift 2 ;;
    *) usage ;;
  esac
done

[[ -z "$PROJECT_ID" ]] && usage

SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
KEY_FILE="${CREDENTIALS_DIR}/gcp-key.json"

# =============================================================================
echo ""
echo "=================================================="
echo "  SRE Playground — GCP セットアップ"
echo "  Project : $PROJECT_ID"
echo "  Region  : $REGION"
echo "  Repo    : $REPOSITORY_NAME"
echo "  Service : $SERVICE_NAME"
echo "=================================================="
echo ""

# --- gcloud が使えるか確認 ---
command -v gcloud &>/dev/null || error "gcloud CLI が見つかりません。インストールしてください: https://cloud.google.com/sdk/docs/install"

# =============================================================================
# Step 1: プロジェクトの存在確認 & 設定
# =============================================================================
info "Step 1: プロジェクト確認"

if gcloud projects describe "$PROJECT_ID" &>/dev/null; then
  skip "プロジェクト '$PROJECT_ID' は既に存在します"
else
  info "プロジェクト '$PROJECT_ID' を作成します..."
  gcloud projects create "$PROJECT_ID" --name="SRE Playground"
  ok "プロジェクトを作成しました"
fi

gcloud config set project "$PROJECT_ID"
ok "アクティブプロジェクトを '$PROJECT_ID' に設定"

# =============================================================================
# Step 2: 必要な API の有効化（冪等: 既に有効なら何もしない）
# =============================================================================
info "Step 2: API の有効化"

REQUIRED_APIS=(
  "run.googleapis.com"
  "compute.googleapis.com"
  "cloudresourcemanager.googleapis.com"
  "iam.googleapis.com"
  "artifactregistry.googleapis.com"
  "iamcredentials.googleapis.com"
  "cloudbuild.googleapis.com"
)

for api in "${REQUIRED_APIS[@]}"; do
  state=$(gcloud services list --filter="name:$api" --format="value(state)" 2>/dev/null || echo "")
  if [[ "$state" == "ENABLED" ]]; then
    skip "$api は有効済み"
  else
    info "$api を有効化中..."
    gcloud services enable "$api"
    ok "$api を有効化しました"
  fi
done

# =============================================================================
# Step 3: Artifact Registry リポジトリ作成
# =============================================================================
info "Step 3: Artifact Registry リポジトリ確認"

if gcloud artifacts repositories describe "$REPOSITORY_NAME" --location="$REGION" &>/dev/null; then
  skip "Artifact Registry '$REPOSITORY_NAME' は既に存在します"
else
  info "Artifact Registry '$REPOSITORY_NAME' を作成します..."
  gcloud artifacts repositories create "$REPOSITORY_NAME" \
    --repository-format=docker \
    --location="$REGION" \
    --description="SRE Playground Docker images"
  ok "Artifact Registry を作成しました"
fi

info "Docker 認証を設定します..."
gcloud auth configure-docker "${REGION}-docker.pkg.dev" --quiet
ok "Docker 認証を設定しました"

# =============================================================================
# Step 4: サービスアカウントの作成
# =============================================================================
info "Step 4: サービスアカウント確認"

if gcloud iam service-accounts describe "$SA_EMAIL" &>/dev/null; then
  skip "サービスアカウント '$SA_EMAIL' は既に存在します"
else
  info "サービスアカウント '$SA_NAME' を作成します..."
  gcloud iam service-accounts create "$SA_NAME" \
    --display-name="Terraform Runner" \
    --project="$PROJECT_ID"
  ok "サービスアカウントを作成しました"
fi

# =============================================================================
# Step 5: IAM ロールの付与（冪等: 既にバインド済みならスキップ）
# =============================================================================
info "Step 5: IAM ロールの付与"

REQUIRED_ROLES=(
  "roles/run.admin"
  "roles/compute.admin"
  "roles/iam.serviceAccountUser"
  "roles/artifactregistry.admin"
  "roles/resourcemanager.projectIamAdmin"
)

CURRENT_ROLES=$(gcloud projects get-iam-policy "$PROJECT_ID" \
  --flatten="bindings[].members" \
  --filter="bindings.members:serviceAccount:$SA_EMAIL" \
  --format="value(bindings.role)" 2>/dev/null || echo "")

for role in "${REQUIRED_ROLES[@]}"; do
  if echo "$CURRENT_ROLES" | grep -qF "$role"; then
    skip "$role は付与済み"
  else
    info "$role を付与中..."
    gcloud projects add-iam-policy-binding "$PROJECT_ID" \
      --member="serviceAccount:$SA_EMAIL" \
      --role="$role" \
      --quiet
    ok "$role を付与しました"
  fi
done

# =============================================================================
# Step 6: 認証キーの生成（既にファイルがあればスキップ）
# =============================================================================
info "Step 6: 認証キーの生成"

mkdir -p "$CREDENTIALS_DIR"

if [[ -f "$KEY_FILE" ]]; then
  skip "認証キー '$KEY_FILE' は既に存在します（再生成したい場合は削除してください）"
else
  info "認証キーを生成します..."
  gcloud iam service-accounts keys create "$KEY_FILE" \
    --iam-account="$SA_EMAIL"
  chmod 600 "$KEY_FILE"
  ok "認証キーを '$KEY_FILE' に保存しました"
fi

# =============================================================================
# Step 7: .gitignore に credentials/ が含まれているか確認
# =============================================================================
info "Step 7: .gitignore チェック"

GITIGNORE="${ROOT_DIR}/.gitignore"
if [[ ! -f "$GITIGNORE" ]]; then
  info ".gitignore が見つかりません。作成します..."
  cat > "$GITIGNORE" <<'EOF'
# GCP credentials
credentials/
*.json

# Terraform
**/.terraform/
*.tfstate
*.tfstate.backup
.terraform.lock.hcl
*.tfvars
EOF
  ok ".gitignore を作成しました"
else
  if grep -qE "^credentials/" "$GITIGNORE"; then
    skip ".gitignore に credentials/ は記載済み"
  else
    echo "credentials/" >> "$GITIGNORE"
    ok ".gitignore に credentials/ を追加しました"
    echo -e "${RED}[WARN]${NC}  credentials/ がコミットされないよう確認してください"
  fi
fi

# =============================================================================
# 完了サマリー
# =============================================================================
echo ""
echo "=================================================="
echo -e "${GREEN}  セットアップ完了！${NC}"
echo "=================================================="
echo ""
echo "  Project ID : $PROJECT_ID"
echo "  Region     : $REGION"
echo "  Repository : $REPOSITORY_NAME"
echo "  SA Email   : $SA_EMAIL"
echo "  Key File   : $KEY_FILE"
echo ""
echo "  次のステップ:"
echo "  1. 以下を .env または shell に設定してください:"
echo ""
echo "     export GOOGLE_APPLICATION_CREDENTIALS=\"${KEY_FILE}\""
echo "     export TF_VAR_project_id=\"${PROJECT_ID}\""
echo "     export TF_VAR_region=\"${REGION}\""
echo "     export ARTIFACT_REGISTRY_REPOSITORY=\"${REPOSITORY_NAME}\""
echo ""
echo "  2. 初回デプロイ:"
echo "     ./deploy_blue_green.sh --project ${PROJECT_ID} --region ${REGION} --repository ${REPOSITORY_NAME} --service-name ${SERVICE_NAME} --blue-weight 100 --green-weight 0"
echo ""
