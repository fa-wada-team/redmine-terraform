data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

################################################################################
# Redmine EC2 用 (シークレット読み取り / ECR からのイメージ取得 / S3 から Docker Compose 取得)
################################################################################

resource "aws_iam_role" "redmine" {
  name               = "${var.project}-ec2-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

data "aws_iam_policy_document" "redmine" {
  statement {
    actions = ["ssm:GetParameter", "ssm:GetParameters"]
    resources = [
      aws_ssm_parameter.db_password.arn,
      aws_ssm_parameter.secret_key_base.arn,
    ]
  }

  statement {
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  # プルスルーキャッシュ: 初回取得時にリポジトリ作成とアップストリームからの取り込みが必要
  statement {
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchImportUpstreamImage",
      "ecr:CreateRepository",
    ]
    resources = [
      "arn:aws:ecr:${var.region}:${data.aws_caller_identity.current.account_id}:repository/${aws_ecr_pull_through_cache_rule.ecr_public.ecr_repository_prefix}/*",
    ]
  }

  statement {
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.artifacts.arn}/${local.docker_compose_s3_key}"]
  }
}

resource "aws_iam_role_policy" "redmine" {
  name   = "redmine-ec2"
  role   = aws_iam_role.redmine.id
  policy = data.aws_iam_policy_document.redmine.json
}

resource "aws_iam_instance_profile" "redmine" {
  name = "${var.project}-ec2-profile"
  role = aws_iam_role.redmine.name
}
