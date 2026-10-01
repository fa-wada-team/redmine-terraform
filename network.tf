data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  az = var.availability_zone != "" ? var.availability_zone : data.aws_availability_zones.available.names[0]
}

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${var.project}-vpc" }
}

# CloudFront VPC オリジンを利用するには VPC に IGW がアタッチされている必要がある
# (サブネットのルートには追加しないため、EC2 はインターネットへ出られない)
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = { Name = "${var.project}-igw" }
}

################################################################################
# プライベートサブネット (Redmine EC2)
# インターネットへの経路は持たず、AWS サービスへは VPC エンドポイント経由で通信する
################################################################################

resource "aws_subnet" "private" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnet_cidr
  availability_zone = local.az

  tags = { Name = "${var.project}-private" }
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  tags = { Name = "${var.project}-private-rt" }
}

resource "aws_route_table_association" "private" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private.id
}

################################################################################
# VPC エンドポイント
################################################################################

# S3 ゲートウェイエンドポイント (無料)
#  - dnf (Amazon Linux 2023 のリポジトリは S3 上にある)
#  - ECR のイメージレイヤー
#  - Docker Compose バイナリ (S3 バケットに配置)
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]

  tags = { Name = "${var.project}-s3-endpoint" }
}

# インターフェイスエンドポイント
#  - ssm     : Parameter Store からのパスワード読み取り
#  - ecr.api : ECR 認証 / プルスルーキャッシュ
#  - ecr.dkr : Docker イメージの取得
locals {
  interface_endpoints = toset(["ssm", "ecr.api", "ecr.dkr"])
}

resource "aws_security_group" "vpc_endpoint" {
  name        = "${var.project}-vpce-sg"
  description = "Interface VPC endpoints (HTTPS from Redmine EC2)"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${var.project}-vpce-sg" }
}

resource "aws_vpc_security_group_ingress_rule" "vpc_endpoint_https" {
  security_group_id            = aws_security_group.vpc_endpoint.id
  description                  = "HTTPS from Redmine EC2"
  referenced_security_group_id = aws_security_group.redmine.id
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
}

resource "aws_vpc_endpoint" "interface" {
  for_each = local.interface_endpoints

  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.region}.${each.key}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.private.id]
  security_group_ids  = [aws_security_group.vpc_endpoint.id]
  private_dns_enabled = true

  tags = { Name = "${var.project}-${replace(each.key, ".", "-")}-endpoint" }
}

################################################################################
# EC2 Instance Connect エンドポイント (無料)
# パブリック IP / 踏み台なしでプライベートサブネットの EC2 に SSH 接続する
################################################################################

resource "aws_security_group" "eice" {
  name        = "${var.project}-eice-sg"
  description = "EC2 Instance Connect Endpoint"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${var.project}-eice-sg" }
}

resource "aws_vpc_security_group_egress_rule" "eice_ssh" {
  security_group_id            = aws_security_group.eice.id
  description                  = "SSH to Redmine EC2"
  referenced_security_group_id = aws_security_group.redmine.id
  from_port                    = 22
  to_port                      = 22
  ip_protocol                  = "tcp"
}

resource "aws_ec2_instance_connect_endpoint" "main" {
  subnet_id          = aws_subnet.private.id
  security_group_ids = [aws_security_group.eice.id]
  preserve_client_ip = false

  tags = { Name = "${var.project}-eice" }
}
