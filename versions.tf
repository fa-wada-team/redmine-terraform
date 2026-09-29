terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # aws_cloudfront_vpc_origin / vpc_origin_config のタイムアウト設定を利用するため 6.x 系
      version = ">= 6.0.0, < 7.0.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.6.0"
    }
  }

  # 複数人で運用する場合は S3 バックエンドの利用を推奨
  # backend "s3" {
  #   bucket       = "your-tfstate-bucket"
  #   key          = "redmine/terraform.tfstate"
  #   region       = "ap-northeast-1"
  #   use_lockfile = true
  #   encrypt      = true
  # }
}
