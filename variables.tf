################################################################################
# 共通
################################################################################

variable "project" {
  description = "リソース名のプレフィックス"
  type        = string
  default     = "redmine"
}

variable "region" {
  description = "デプロイ先リージョン"
  type        = string
  default     = "ap-northeast-1"
}

variable "tags" {
  description = "全リソースに付与する追加タグ"
  type        = map(string)
  default     = {}
}

################################################################################
# ネットワーク
################################################################################

variable "vpc_cidr" {
  description = "VPC の CIDR"
  type        = string
  default     = "10.0.0.0/16"
}

variable "private_subnet_cidr" {
  description = "プライベートサブネット (Redmine 用) の CIDR"
  type        = string
  default     = "10.0.10.0/24"
}

variable "availability_zone" {
  description = <<-EOT
    サブネットを作成する AZ。空の場合はリージョンの先頭 AZ を使用。
    CloudFront VPC オリジンは一部の AZ (例: apne1-az3) に対応していないため、
    エラーになる場合は別の AZ を指定してください。
  EOT
  type        = string
  default     = ""
}

################################################################################
# Redmine EC2
################################################################################

variable "instance_type" {
  description = "Redmine EC2 のインスタンスタイプ (Graviton / arm64)。10 人以下なら t4g.small で十分"
  type        = string
  default     = "t4g.small"
}

variable "root_volume_size" {
  description = "ルートボリュームサイズ (GiB)"
  type        = number
  default     = 10
}

variable "data_volume_size" {
  description = "データボリューム (DB / 添付ファイル) のサイズ (GiB)"
  type        = number
  default     = 20
}

variable "redmine_image" {
  description = "Redmine の Docker イメージ (ECR Public 上のパス。ECR プルスルーキャッシュ経由で取得)"
  type        = string
  default     = "docker/library/redmine:6.0"
}

variable "postgres_image" {
  description = "PostgreSQL の Docker イメージ (ECR Public 上のパス。ECR プルスルーキャッシュ経由で取得)"
  type        = string
  default     = "docker/library/postgres:16-alpine"
}

variable "nginx_image" {
  description = "リバースプロキシ (nginx) の Docker イメージ (ECR Public 上のパス。ECR プルスルーキャッシュ経由で取得)"
  type        = string
  default     = "docker/library/nginx:1.27-alpine"
}

variable "docker_compose_version" {
  description = "インストールする Docker Compose プラグインのバージョン (apply 実行端末で GitHub から取得し S3 に配置)"
  type        = string
  default     = "v2.29.7"
}

variable "upload_max_size_mb" {
  description = "添付ファイルの最大アップロードサイズ (MB)"
  type        = number
  default     = 50
}

################################################################################
# CloudFront
################################################################################

variable "cloudfront_price_class" {
  description = "CloudFront の価格クラス。PriceClass_200 は日本のエッジを含む"
  type        = string
  default     = "PriceClass_200"
}

variable "custom_domain" {
  description = "独自ドメイン (例: redmine.example.com)。空の場合は *.cloudfront.net を使用"
  type        = string
  default     = ""
}

variable "acm_certificate_arn" {
  description = "独自ドメイン用 ACM 証明書の ARN (us-east-1 で発行したもの)"
  type        = string
  default     = ""
}

variable "route53_zone_id" {
  description = "独自ドメインの Route 53 ホストゾーン ID。指定すると ALIAS レコードを作成"
  type        = string
  default     = ""
}

################################################################################
# 稼働スケジュール (コスト削減)
################################################################################

variable "enable_schedule" {
  description = "平日日中のみ EC2 を稼働させるスケジュールを有効化する"
  type        = bool
  default     = false
}

variable "schedule_timezone" {
  description = "スケジュールのタイムゾーン"
  type        = string
  default     = "Asia/Tokyo"
}

variable "schedule_start_cron" {
  description = "起動スケジュール (EventBridge Scheduler の cron 式)"
  type        = string
  default     = "cron(0 8 ? * MON-FRI *)"
}

variable "schedule_stop_cron" {
  description = "停止スケジュール (EventBridge Scheduler の cron 式)"
  type        = string
  default     = "cron(0 21 ? * MON-FRI *)"
}

################################################################################
# インターフェイス VPC エンドポイントの自動作成 / 削除
################################################################################

variable "endpoint_ttl_minutes" {
  description = "自動作成したインターフェイスエンドポイントを削除するまでの時間 (分)"
  type        = number
  default     = 60
}

variable "endpoint_cleanup_rate" {
  description = "期限切れエンドポイントの削除チェック間隔 (EventBridge Scheduler の rate 式)"
  type        = string
  default     = "rate(10 minutes)"
}
