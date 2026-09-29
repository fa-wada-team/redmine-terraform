# redmine-terraform

Redmine を AWS に構築する Terraform です。利用者 10 人以下・低コスト運用を前提にしています。

## 構成

```
インターネット
   │  HTTPS (*.cloudfront.net もしくは独自ドメイン)
   ▼
CloudFront ──(任意) CloudFront Functions による IP 制限
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
| バックアップ | **DLM による EBS 日次スナップショット + pg_dump** | 追加料金なし (スナップショット容量のみ) |
| TLS | **CloudFront のデフォルト証明書 / ACM** | 証明書は無料 |

EC2 のセキュリティグループは CloudFront のマネージドプレフィックスリスト
(`com.amazonaws.global.cloudfront.origin-facing`) からの 80 番のみ許可しています。

## 概算コスト (東京リージョン / 月額)

| リソース | 金額 (USD) |
| --- | --- |
| EC2 t4g.small (24h 稼働) | 約 15.8 |
| NAT インスタンス t4g.nano | 約 3.9 |
| パブリック IPv4 (NAT 用 1 個) | 約 3.6 |
| EBS gp3 38GB (root 10 + data 20 + NAT 8) | 約 3.6 |
| EBS スナップショット (差分) | 約 1〜2 |
| CloudFront (無料枠: 1TB 転送 / 1,000 万リクエスト) | 約 0 |
| **合計** | **約 28〜30** |

- `enable_schedule = true` (平日 8:00〜21:00 のみ稼働) にすると EC2 分が約 6 割減り、**約 $18/月** 程度になります。
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
/usr/local/bin/redmine-db-backup      # 事前に DB ダンプ
docker compose pull && docker compose up -d
```

### プラグイン

`/data/redmine/plugins` に配置し、`docker compose restart redmine` を実行します。

### バックアップとリストア

- 毎日 `backup_time_utc` (既定: JST 03:00) にデータボリュームの EBS スナップショットを取得し、`backup_retain_count` 世代保持
- その 30 分前に `pg_dump` を `/data/backup/` に出力 (7 日保持)。スナップショットにも含まれます

リストア手順 (概要):
1. 対象スナップショットから EBS ボリュームを作成
2. EC2 上で `docker compose down` → 既存ボリュームを デタッチ → 新ボリュームを `/dev/sdf` にアタッチ
3. `terraform import` / `terraform state rm` で `aws_ebs_volume.data` を新ボリュームに置き換え
4. EC2 を再起動 (fstab は UUID 指定のため、スナップショット由来のボリュームはそのままマウントされます)

データボリュームには `prevent_destroy` を設定しているため、`terraform destroy` では削除されません。
完全に削除する場合は `ec2.tf` の `prevent_destroy` を外してから実行してください。

## 追加で検討をおすすめする事項

| 提案 | 内容 | 本リポジトリでの対応 |
| --- | --- | --- |
| **IP アドレス制限** | 社内・自宅の固定 IP からのみ許可。Redmine を公開しないなら最も効果的な対策 | `allowed_ip_cidrs` で対応 (CloudFront Functions / ほぼ無料) |
| **独自ドメイン** | `redmine.example.com` 等でアクセス | `custom_domain` / `acm_certificate_arn` / `route53_zone_id` で対応 |
| **夜間・休日停止** | 利用時間外の EC2 停止でコスト削減 | `enable_schedule` で対応 (EventBridge Scheduler) |
| **バックアップ** | 日次スナップショット + DB ダンプ | 対応済み |
| **OS セキュリティ更新** | 日次で `dnf upgrade --security` | 対応済み |
| **メール通知** | チケット更新通知を送る場合は Amazon SES の SMTP を利用 (月 3,000 通まで実質無料)。`/opt/redmine` に `configuration.yml` をマウントして設定 | 未対応 (要望があれば追加可能) |
| **AWS WAF** | IP 制限できない場合のボット・攻撃対策。約 $6〜/月 の追加費用 | 未対応 |
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
| `cloudfront.tf` | CloudFront ディストリビューション / VPC オリジン / IP 制限関数 |
| `backup.tf` | DLM による EBS スナップショット |
| `scheduler.tf` | 稼働スケジュール (任意) |
| `templates/` | EC2 の user_data / CloudFront Functions のコード |
