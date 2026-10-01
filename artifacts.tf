data "aws_caller_identity" "current" {}

################################################################################
# ECR プルスルーキャッシュ
# Docker Hub 公式イメージのミラーである ECR Public (public.ecr.aws/docker/library/*) を
# 自アカウントの ECR 経由で取得する。EC2 は ECR の VPC エンドポイントにのみアクセスする。
################################################################################

resource "aws_ecr_pull_through_cache_rule" "ecr_public" {
  ecr_repository_prefix = "${var.project}-ecr-public"
  upstream_registry_url = "public.ecr.aws"
}

locals {
  ecr_registry     = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.region}.amazonaws.com"
  ecr_cache_prefix = "${local.ecr_registry}/${aws_ecr_pull_through_cache_rule.ecr_public.ecr_repository_prefix}"
}

################################################################################
# Docker Compose バイナリ
# terraform apply を実行する端末で GitHub から取得 (SHA256 検証) し、S3 に配置する。
# EC2 は S3 ゲートウェイエンドポイント経由で取得する。
################################################################################

resource "aws_s3_bucket" "artifacts" {
  bucket        = "${var.project}-artifacts-${data.aws_caller_identity.current.account_id}"
  force_destroy = true

  tags = { Name = "${var.project}-artifacts" }
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

locals {
  docker_compose_file      = "docker-compose-linux-aarch64"
  docker_compose_local     = "${path.module}/.cache/docker-compose/${var.docker_compose_version}/${local.docker_compose_file}"
  docker_compose_s3_key    = "docker-compose/${var.docker_compose_version}/${local.docker_compose_file}"
  docker_compose_s3_bucket = aws_s3_bucket.artifacts.id
}

resource "terraform_data" "docker_compose_download" {
  input = var.docker_compose_version

  provisioner "local-exec" {
    command     = "bash ${path.module}/scripts/fetch-docker-compose.sh '${var.docker_compose_version}' '${local.docker_compose_local}'"
    interpreter = ["/bin/sh", "-c"]
  }
}

resource "aws_s3_object" "docker_compose" {
  bucket = aws_s3_bucket.artifacts.id
  key    = local.docker_compose_s3_key
  source = local.docker_compose_local

  depends_on = [terraform_data.docker_compose_download]
}
