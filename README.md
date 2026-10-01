# redmine-terraform

Redmine を AWS に構築する Terraform です。利用者 10 人以下・低コスト運用を前提にしています。

## 構成

```
インターネット
   │  HTTPS (*.cloudfront.net もしくは独自ドメイン)
   ▼
CloudFront
   │  HTTP (CloudFront VPC オリジン / AWS 内部ネットワーク)
   ▼
┌──────────────────── VPC ────────────────────┐
│  Private Subnet                              │
│   EC2 (t4g.small / Amazon Linux 2023)        │
│    └ docker compose                          │
│        nginx :80 → Redmine :3000 → PostgreSQL│
│    └ データ用 EBS (/data: DB・添付ファイル)  │
│                  │ アウトバウンドのみ        │
│  Public Subnet   ▼                           │
│   NAT インスタンス (t4g.nano) → IGW          │
└──────────────────────────────────────────────┘
```

| 項目 | 採用 | 理由 |
| --- | --- | --- |
| CloudFront → EC2 接続 | **CloudFront VPC オリジン** | ALB 不要 (約 $20/月 削減)。EC2 にパブリック IP・公開ポート不要 |
| 外向き通信 | **NAT インスタンス (t4g.nano)** | NAT Gateway (約 $45/月) の 1/10 以下 |
| DB | **EC2 上の PostgreSQL (Docker)** | RDS (最小でも約 $15〜/月) を省略 |
| CPU アーキテクチャ | **Graviton (arm64)** | 同性能の x86 より約 20% 安い |
| 管理アクセス | **SSM Session Manager** | SSH 鍵・踏み台不要。22 番ポートは開けない |
| シークレット | **SSM Parameter Store (SecureString)** | 標準パラメータは無料 |
| TLS | **CloudFront のデフォルト証明書 / ACM** | 証明書は無料 |

### EC2 への直接アクセスの遮断

- EC2 はプライベートサブネットに配置し、パブリック IP は付与しません (インターネットから到達不可)。
- EC2 のセキュリティグループは、CloudFront VPC オリジン作成時に CloudFront が自動作成する
  セキュリティグループ `CloudFront-VPCOrigins-Service-SG` からの 80 番のみ許可します。
  VPC 内の他リソース (NAT インスタンス等) からも直接アクセスできません。
- SSH (22 番) は開けず、管理は SSM Session Manager で行います。

## 概算コスト (東京リージョン / 月額)

| リソース | 金額 (USD) |
| --- | --- |
| EC2 t4g.small (24h 稼働) | 約 15.8 |
| NAT インスタンス t4g.nano | 約 3.9 |
| パブリック IPv4 (NAT 用 1 個) | 約 3.6 |
| EBS gp3 38GB (root 10 + data 20 + NAT 8) | 約 3.6 |
| CloudFront (無料枠: 1TB 転送 / 1,000 万リクエスト) | 約 0 |
| **合計** | **約 27** |

- `enable_schedule = true` (平日 8:00〜21:00 のみ稼働) にすると EC2 分が約 6 割減り、**約 $17/月** 程度になります。
- 24 時間稼働させる場合は Compute Savings Plans (1 年) でさらに約 3 割削減できます。

## 前提

- Terraform >= 1.6
- AWS 認証情報 (AdministratorAccess 相当)
- (SSM でログインする場合) AWS CLI と Session Manager プラグイン

## デプロイ

```bash
cp terraform.tfvars.example terraform.tfvars   # 必要に応じて編集
terraform init
terraform apply
```

CloudFront VPC オリジンの作成に 10〜15 分程度かかります。
`apply` 完了後、EC2 の初期化 (Docker イメージ取得・DB 初期化) に 5 分程度かかります。

```bash
terraform output redmine_url
```

### 初期設定 (必須)

1. `redmine_url` にアクセスし、`admin` / `admin` でログインしてパスワードを変更
2. 「管理」→「設定」→「全般」で以下を設定 (通知メール内のリンクに使われます)
   - ホスト名とパス: CloudFront のドメイン名 (または独自ドメイン)
   - プロトコル: `HTTPS`
3. 「管理」→「設定」→「認証」で「認証が必要」を ON にする (外部公開する場合は強く推奨)

## 運用

### サーバーへのログイン

```bash
$(terraform output -raw ssm_session_command)
sudo -i
cd /opt/redmine
docker compose ps
docker compose logs -f redmine
```

初期化ログは `/var/log/redmine-setup.log` にあります。

### Redmine のバージョンアップ

`/opt/redmine/compose.yml` のイメージタグを変更して、以下を実行します。
(`user_data` の変更はインスタンス再作成を避けるため無視する設定にしています)

```bash
cd /opt/redmine
docker compose pull && docker compose up -d
```

### プラグイン

`/data/redmine/plugins` に配置し、`docker compose restart redmine` を実行します。

### データの保持

DB と添付ファイルはデータ用 EBS (`/data`) に保存しており、EC2 を再作成してもデータは残ります。
バックアップは取得しないため、必要に応じて手動で EBS スナップショットを取得してください。

データボリュームには `prevent_destroy` を設定しているため、`terraform destroy` では削除されません。
完全に削除する場合は `ec2.tf` の `prevent_destroy` を外してから実行してください。

## 追加で検討をおすすめする事項

| 提案 | 内容 | 本リポジトリでの対応 |
| --- | --- | --- |
| **独自ドメイン** | `redmine.example.com` 等でアクセス | `custom_domain` / `acm_certificate_arn` / `route53_zone_id` で対応 |
| **夜間・休日停止** | 利用時間外の EC2 停止でコスト削減 | `enable_schedule` で対応 (EventBridge Scheduler) |
| **OS セキュリティ更新** | 日次で `dnf upgrade --security` | 対応済み |
| **メール通知** | チケット更新通知を送る場合は Amazon SES の SMTP を利用 (月 3,000 通まで実質無料)。`/opt/redmine` に `configuration.yml` をマウントして設定 | 未対応 (要望があれば追加可能) |
| **AWS WAF** | ボット・攻撃対策。約 $6〜/月 の追加費用 | 未対応 |
| **監視・通知** | EC2 ステータスチェック失敗時の自動復旧・通知 (CloudWatch アラーム / SNS) | 未対応 (t4g は既定で簡易自動復旧あり) |
| **予算アラート** | AWS Budgets で月額上限を超えたら通知 | 未対応 |
| **tfstate の保管** | 複数人で運用する場合は S3 バックエンドを利用 | `versions.tf` にサンプルあり |
| **SSO 連携** | Google / Microsoft アカウントでログイン (Redmine プラグイン) | 未対応 |

## ファイル構成

| ファイル | 内容 |
| --- | --- |
| `network.tf` | VPC / サブネット / ルートテーブル / S3 ゲートウェイエンドポイント |
| `nat.tf` | NAT インスタンス |
| `ec2.tf` | Redmine EC2 / データ用 EBS / セキュリティグループ / シークレット |
| `iam.tf` | EC2 用 IAM ロール |
| `cloudfront.tf` | CloudFront ディストリビューション / VPC オリジン |
| `scheduler.tf` | 稼働スケジュール (任意) |
| `templates/` | EC2 の user_data |
