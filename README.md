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
┌──────────────────────── VPC ────────────────────────┐
│  Private Subnet (インターネットへの経路なし)          │
│   EC2 (t4g.small / Amazon Linux 2023)                │
│    └ docker compose                                  │
│        nginx :80 → Redmine :3000 → PostgreSQL        │
│    └ データ用 EBS (/data: DB・添付ファイル)          │
│        │ アウトバウンドは VPC エンドポイントのみ     │
│        ├ S3 ゲートウェイ   … dnf / Docker Compose    │
│        ├ ecr.api / ecr.dkr … Docker イメージ         │
│        └ ssm               … Parameter Store         │
│                                                      │
│   EC2 Instance Connect エンドポイント ← 管理者の SSH │
└──────────────────────────────────────────────────────┘
```

| 項目 | 採用 | 理由 |
| --- | --- | --- |
| CloudFront → EC2 接続 | **CloudFront VPC オリジン** | ALB 不要 (約 $20/月 削減)。EC2 にパブリック IP・公開ポート不要 |
| 外向き通信 | **VPC エンドポイントのみ (NAT なし)** | インターネットへの経路を持たず、AWS サービスとだけ通信する |
| Docker イメージ | **ECR プルスルーキャッシュ (上流: ECR Public)** | Docker Hub 公式イメージのミラー (`public.ecr.aws/docker/library/*`) を自アカウントの ECR 経由で取得。認証情報不要 |
| Docker Compose | **S3 に配置** | `apply` 実行端末で GitHub から取得・SHA256 検証し、S3 にアップロード |
| DB | **EC2 上の PostgreSQL (Docker)** | RDS (最小でも約 $15〜/月) を省略 |
| CPU アーキテクチャ | **Graviton (arm64)** | 同性能の x86 より約 20% 安い |
| 管理アクセス | **EC2 Instance Connect エンドポイント** | 無料。踏み台・パブリック IP 不要。SSH 鍵は接続時に一時的に送り込むため管理不要 |
| シークレット | **SSM Parameter Store (SecureString)** | 標準パラメータは無料 |
| TLS | **CloudFront のデフォルト証明書 / ACM** | 証明書は無料 |

### EC2 への直接アクセスの遮断

- EC2 はプライベートサブネットに配置し、パブリック IP は付与しません (インターネットから到達不可)。
- EC2 のセキュリティグループは、CloudFront VPC オリジン作成時に CloudFront が自動作成する
  セキュリティグループ `CloudFront-VPCOrigins-Service-SG` からの 80 番のみ許可します。
  VPC 内の他リソースからも直接アクセスできません。
- SSH (22 番) は EC2 Instance Connect エンドポイントのセキュリティグループからのみ許可します。
  エンドポイントの利用には IAM 認証 (`ec2-instance-connect:OpenTunnel`) が必要です。
- EC2 のアウトバウンドは VPC エンドポイント宛ての HTTPS (443) のみ許可しています。

## 概算コスト (東京リージョン / 月額)

| リソース | 金額 (USD) |
| --- | --- |
| EC2 t4g.small (24h 稼働) | 約 15.8 |
| インターフェイス VPC エンドポイント × 3 (ssm / ecr.api / ecr.dkr) | 約 30.7 |
| EBS gp3 30GB (root 10 + data 20) | 約 2.9 |
| S3 ゲートウェイエンドポイント / EC2 Instance Connect エンドポイント | 0 |
| ECR (キャッシュしたイメージ約 1GB) / S3 (Docker Compose) | 約 0.1 |
| CloudFront (無料枠: 1TB 転送 / 1,000 万リクエスト) | 約 0 |
| **合計** | **約 50** |

- インターフェイスエンドポイントは 1 個あたり約 $10/月 (24 時間課金) かかります。
- `enable_schedule = true` (平日 8:00〜21:00 のみ稼働) にすると EC2 分が約 6 割減り、**約 $40/月** 程度になります
  (エンドポイントは停止できないため削減対象外)。
- 24 時間稼働させる場合は Compute Savings Plans (1 年) でさらに約 3 割削減できます。

## 前提

- Terraform >= 1.6
- AWS 認証情報 (AdministratorAccess 相当)
- `bash` / `curl` / `sha256sum` (または `shasum`) — `apply` 時に Docker Compose を GitHub から取得するため
- (EC2 にログインする場合) AWS CLI v2

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
$(terraform output -raw ssh_command)
sudo -i
cd /opt/redmine
docker compose ps
docker compose logs -f redmine
```

初期化ログは `/var/log/redmine-setup.log` にあります。

ログインする IAM ユーザー / ロールには `ec2-instance-connect:OpenTunnel` と
`ec2-instance-connect:SendSSHPublicKey` の権限が必要です。

### Redmine のバージョンアップ

`/opt/redmine/compose.yml` のイメージタグ (例: `.../docker/library/redmine:6.0` → `:6.1`) を変更して、以下を実行します。
イメージは ECR プルスルーキャッシュ経由で取得されます (インターネット接続は不要)。
(`user_data` の変更はインスタンス再作成を避けるため無視する設定にしています)

```bash
cd /opt/redmine
docker compose pull && docker compose up -d
```

### プラグイン

`/data/redmine/plugins` に配置し、`docker compose restart redmine` を実行します。
EC2 はインターネットに出られないため、プラグインは手元でダウンロードして `scp` 等で転送してください。
追加の gem が必要なプラグインは、そのままではインストールできません (カスタムイメージを ECR に push する等の対応が必要です)。

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
| `network.tf` | VPC / サブネット / VPC エンドポイント / EC2 Instance Connect エンドポイント |
| `artifacts.tf` | ECR プルスルーキャッシュ / Docker Compose 配置用 S3 バケット |
| `ec2.tf` | Redmine EC2 / データ用 EBS / セキュリティグループ / シークレット |
| `iam.tf` | EC2 用 IAM ロール |
| `cloudfront.tf` | CloudFront ディストリビューション / VPC オリジン |
| `scheduler.tf` | 稼働スケジュール (任意) |
| `templates/` | EC2 の user_data |
| `scripts/` | Docker Compose 取得スクリプト (`apply` 時に実行) |
