data "aws_ssm_parameter" "al2023_arm64" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

################################################################################
# シークレット (SSM Parameter Store / SecureString は標準パラメータなら無料)
################################################################################

resource "random_password" "db" {
  length  = 32
  special = false
}

resource "random_password" "secret_key_base" {
  length  = 64
  special = false
}

resource "aws_ssm_parameter" "db_password" {
  name  = "/${var.project}/db_password"
  type  = "SecureString"
  value = random_password.db.result
}

resource "aws_ssm_parameter" "secret_key_base" {
  name  = "/${var.project}/secret_key_base"
  type  = "SecureString"
  value = random_password.secret_key_base.result
}

################################################################################
# セキュリティグループ
################################################################################

# CloudFront VPC オリジンを作成すると、CloudFront が VPC 内に ENI と
# セキュリティグループ "CloudFront-VPCOrigins-Service-SG" を自動作成する。
# EC2 への通信はその ENI (プライベート IP) から届くため、このセキュリティグループからの
# 通信のみを許可し、それ以外 (VPC 内の他リソースを含む) からの直接アクセスは拒否する。
data "aws_security_group" "cloudfront_vpc_origin" {
  vpc_id = aws_vpc.main.id

  filter {
    name   = "group-name"
    values = ["CloudFront-VPCOrigins-Service-SG"]
  }

  depends_on = [aws_cloudfront_vpc_origin.redmine]
}

resource "aws_security_group" "redmine" {
  name        = "${var.project}-ec2-sg"
  description = "Redmine EC2 (HTTP from CloudFront VPC origin only)"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${var.project}-ec2-sg" }
}

resource "aws_vpc_security_group_ingress_rule" "redmine_http_from_cloudfront" {
  security_group_id            = aws_security_group.redmine.id
  description                  = "HTTP from CloudFront VPC origin"
  referenced_security_group_id = data.aws_security_group.cloudfront_vpc_origin.id
  from_port                    = 80
  to_port                      = 80
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "redmine_ssh_from_eice" {
  security_group_id            = aws_security_group.redmine.id
  description                  = "SSH from EC2 Instance Connect Endpoint"
  referenced_security_group_id = aws_security_group.eice.id
  from_port                    = 22
  to_port                      = 22
  ip_protocol                  = "tcp"
}

# アウトバウンドは VPC エンドポイント (HTTPS) のみ
resource "aws_vpc_security_group_egress_rule" "redmine_to_vpce" {
  security_group_id            = aws_security_group.redmine.id
  description                  = "HTTPS to interface VPC endpoints"
  referenced_security_group_id = aws_security_group.vpc_endpoint.id
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "redmine_to_s3" {
  security_group_id = aws_security_group.redmine.id
  description       = "HTTPS to S3 gateway endpoint"
  prefix_list_id    = aws_vpc_endpoint.s3.prefix_list_id
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

################################################################################
# データボリューム
# DB と添付ファイルはルートボリュームと分離し、インスタンス再作成時も保持する
################################################################################

resource "aws_ebs_volume" "data" {
  availability_zone = local.az
  size              = var.data_volume_size
  type              = "gp3"
  encrypted         = true

  tags = { Name = "${var.project}-data" }

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_volume_attachment" "data" {
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.data.id
  instance_id = aws_instance.redmine.id
}

################################################################################
# Redmine EC2
################################################################################

locals {
  data_volume_devname = "nvme-Amazon_Elastic_Block_Store_${replace(aws_ebs_volume.data.id, "-", "")}"
}

resource "aws_instance" "redmine" {
  ami           = data.aws_ssm_parameter.al2023_arm64.value
  instance_type = var.instance_type
  subnet_id     = aws_subnet.private.id
  # パブリック IP を付与せず、インターネットから直接到達できないようにする
  associate_public_ip_address = false
  vpc_security_group_ids      = [aws_security_group.redmine.id]
  iam_instance_profile        = aws_iam_instance_profile.redmine.name

  user_data = templatefile("${path.module}/templates/redmine_user_data.sh.tftpl", {
    region                = var.region
    data_volume_devname   = local.data_volume_devname
    db_password_param     = aws_ssm_parameter.db_password.name
    secret_key_base_param = aws_ssm_parameter.secret_key_base.name
    ecr_registry          = local.ecr_registry
    redmine_image         = "${local.ecr_cache_prefix}/${var.redmine_image}"
    postgres_image        = "${local.ecr_cache_prefix}/${var.postgres_image}"
    nginx_image           = "${local.ecr_cache_prefix}/${var.nginx_image}"
    docker_compose_s3_uri = "s3://${local.docker_compose_s3_bucket}/${local.docker_compose_s3_key}"
    upload_max_size_mb    = var.upload_max_size_mb
  })
  user_data_replace_on_change = false

  metadata_options {
    http_tokens = "required"
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = var.root_volume_size
    encrypted   = true
  }

  lifecycle {
    # AMI 更新やスクリプト変更で意図せずインスタンスが再作成されないようにする
    ignore_changes = [ami, user_data]
  }

  # 初期化スクリプトが利用する VPC エンドポイント / 配布物を先に用意する
  depends_on = [
    aws_route_table_association.private,
    aws_vpc_endpoint.s3,
    aws_vpc_endpoint.interface,
    aws_vpc_security_group_egress_rule.redmine_to_vpce,
    aws_vpc_security_group_egress_rule.redmine_to_s3,
    aws_vpc_security_group_ingress_rule.vpc_endpoint_https,
    aws_ecr_pull_through_cache_rule.ecr_public,
    aws_s3_object.docker_compose,
  ]

  tags = { Name = "${var.project}-ec2" }
}
