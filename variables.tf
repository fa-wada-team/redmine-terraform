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

variable "public_subnet_cidr" {
  description = "パブリックサブネット (NAT インスタンス用) の CIDR"
  type        = string
  default     = "10.0.0.0/24"
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

variable "nat_instance_type" {
  description = "NAT インスタンスのインスタンスタイプ (Graviton / arm64)"
  type        = string
  default     = "t4g.nano"
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
  description = "Redmine の Docker イメージ"
  type        = string
  default     = "redmine:6.0"
}

variable "postgres_image" {
  description = "PostgreSQL の Docker イメージ"
  type        = string
  default     = "postgres:16-alpine"
}

variable "nginx_image" {
  description = "リバースプロキシ (nginx) の Docker イメージ"
  type        = string
  default     = "nginx:1.27-alpine"
}

variable "docker_compose_version" {
  description = "インストールする Docker Compose プラグインのバージョン"
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
