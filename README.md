# SRE Playground

企画書ベースで構築した、GCP 上の Blue/Green デプロイメントと可視化ダッシュボードの実装です。  
ルートディレクトリに、初期構築・デプロイ・トラフィック切替をまとめたシェルスクリプトを置いています。

## 設定ファイル

毎回 `--project` を渡さなくて済むように、ルートの `.sre_playground.env` を読めるようにしています。  
まず [`.sre_playground.env.example`](/home/nagano/project/sre_playground/.sre_playground.env.example:1) をコピーして使ってください。

```bash
cp .sre_playground.env.example .sre_playground.env
```

例:

```bash
PROJECT_ID="your-gcp-project-id"
REGION="asia-northeast1"
REPOSITORY_NAME="sre-playground"
SERVICE_NAME="sre-playground"
BLUE_TAG="blue"
GREEN_TAG="green"
```

優先順位は `CLI オプション > .sre_playground.env > スクリプト内デフォルト` です。

## 追加したルートスクリプト

- `setup_gcp.sh`: GCP 初期セットアップ
- `bootstrap_local.sh`: ローカル依存の初期セットアップ
- `deploy_blue_green.sh`: Blue / Green イメージ build/push と Terraform apply
- `switch_traffic.sh`: 既存デプロイ済み環境のトラフィック切替

## 前提

ローカルで次が使えることを前提にしています。

- `gcloud`
- `terraform`
- `docker`
- `python3`
- `npm`

また、GCP 認証済みであることを前提にします。未認証なら先に `gcloud auth login` を実行してください。

## 1. ローカル初期構築

API、ダッシュボード、サンプルアプリの依存をまとめて入れるには次を実行します。

```bash
./bootstrap_local.sh
```

このスクリプトが行うこと:

- `apps/api/.venv` の作成
- FastAPI 依存のインストール
- `apps/dashboard` の `npm install`
- `apps/sample-app` の `npm install`

起動例:

```bash
source apps/api/.venv/bin/activate
uvicorn app.main:app --reload --app-dir apps/api
```

```bash
NEXT_PUBLIC_API_BASE_URL=http://localhost:8000 npm --prefix apps/dashboard run dev
```

```bash
npm --prefix apps/sample-app run dev
```

## 2. GCP 初期構築

GCP 側の初期セットアップは次です。

```bash
./setup_gcp.sh
```

設定ファイルを使わずに明示指定するなら:

```bash
./setup_gcp.sh --project <PROJECT_ID> --region asia-northeast1 --repository sre-playground
```

このスクリプトが行うこと:

- GCP プロジェクト確認
- 必要 API 有効化
- Artifact Registry 作成
- Docker 認証設定
- Terraform 実行用サービスアカウント作成
- 必要 IAM ロール付与
- `credentials/gcp-key.json` の生成

生成された鍵は自動では export しないので、必要なら次を設定してください。

```bash
export GOOGLE_APPLICATION_CREDENTIALS="$(pwd)/credentials/gcp-key.json"
```

## 3. 初回 Blue/Green デプロイ

Blue 100%、Green 0% で初回デプロイする例です。

```bash
./deploy_blue_green.sh --blue-weight 100 --green-weight 0
```

明示指定するなら:

```bash
./deploy_blue_green.sh \
  --project <PROJECT_ID> \
  --region asia-northeast1 \
  --repository sre-playground \
  --service-name sre-playground \
  --blue-weight 100 \
  --green-weight 0
```

このスクリプトが行うこと:

- `apps/sample-app` の Docker image を Blue / Green 用に build
- Artifact Registry へ push
- `gcloud auth configure-docker ${REGION}-docker.pkg.dev` の実行
- `infra/terraform` で `terraform init`
- 指定重みで `terraform apply`

主なオプション:

- `--skip-build`: build/push を飛ばして Terraform のみ実行
- `--blue-tag`: Blue イメージタグを変更
- `--green-tag`: Green イメージタグを変更

`Unauthenticated request` で push に失敗した場合:

- `gcloud auth login`
- `./setup_gcp.sh`
- その後 `./deploy_blue_green.sh` を再実行

例:

```bash
./deploy_blue_green.sh \
  --project <PROJECT_ID> \
  --blue-tag blue-v2 \
  --green-tag green-v2 \
  --blue-weight 50 \
  --green-weight 50
```

## 4. Blue/Green 切替

既存イメージのままトラフィックだけ切り替える場合は次です。

Green に全面切替:

```bash
./switch_traffic.sh --to green
```

Blue に戻す:

```bash
./switch_traffic.sh --to blue
```

段階切替:

```bash
./switch_traffic.sh \
  --blue-weight 20 \
  --green-weight 80
```

このスクリプトは Terraform を再適用して、ロードバランサの重みだけ更新します。

別の設定ファイルを使いたい場合は、どのスクリプトでも `--config <FILE>` を先頭で渡せます。

```bash
./deploy_blue_green.sh --config ./envs/staging.env --blue-weight 100 --green-weight 0
```

## 5. 企画書との対応

- Phase 1: `infra/terraform` と `deploy_blue_green.sh`
- Phase 2: `apps/dashboard`
- Phase 3: `apps/api` と `switch_traffic.sh` / `deploy_blue_green.sh`

## 6. 補足

- FastAPI の `/api/deploy` はローカル検証用に mock deploy も返せます。
- 実 GCP デプロイでは Terraform Provider / GCP 側仕様差分で追加調整が必要になる可能性があります。
- HTTPS、独自ドメイン、Cloud Build 化、Terraform state のリモート管理は未実装です。
