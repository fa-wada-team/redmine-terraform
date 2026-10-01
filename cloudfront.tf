################################################################################
# CloudFront VPC オリジン
# プライベートサブネットの EC2 へ直接接続する (ALB 不要 / EC2 にパブリック IP 不要)
################################################################################

resource "aws_cloudfront_vpc_origin" "redmine" {
  vpc_origin_endpoint_config {
    name                   = "${var.project}-ec2"
    arn                    = aws_instance.redmine.arn
    http_port              = 80
    https_port             = 443
    origin_protocol_policy = "http-only"

    origin_ssl_protocols {
      items    = ["TLSv1.2"]
      quantity = 1
    }
  }
}

################################################################################
# ポリシー
################################################################################

data "aws_cloudfront_cache_policy" "disabled" {
  name = "Managed-CachingDisabled"
}

data "aws_cloudfront_cache_policy" "optimized" {
  name = "Managed-CachingOptimized"
}

# Host ヘッダー・Cookie・クエリ文字列をすべてオリジンへ転送
data "aws_cloudfront_origin_request_policy" "all_viewer" {
  name = "Managed-AllViewer"
}

data "aws_cloudfront_response_headers_policy" "security_headers" {
  name = "Managed-SecurityHeadersPolicy"
}

################################################################################
# ディストリビューション
################################################################################

locals {
  origin_id         = "redmine-ec2"
  use_custom_domain = var.custom_domain != "" && var.acm_certificate_arn != ""
}

resource "aws_cloudfront_distribution" "redmine" {
  enabled         = true
  comment         = "${var.project} Redmine"
  price_class     = var.cloudfront_price_class
  http_version    = "http2and3"
  is_ipv6_enabled = true
  aliases         = local.use_custom_domain ? [var.custom_domain] : []

  origin {
    origin_id   = local.origin_id
    domain_name = aws_instance.redmine.private_dns

    vpc_origin_config {
      vpc_origin_id            = aws_cloudfront_vpc_origin.redmine.id
      origin_read_timeout      = 60
      origin_keepalive_timeout = 5
    }
  }

  # Redmine は動的コンテンツのためキャッシュしない
  default_cache_behavior {
    target_origin_id           = local.origin_id
    viewer_protocol_policy     = "redirect-to-https"
    allowed_methods            = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods             = ["GET", "HEAD"]
    compress                   = true
    cache_policy_id            = data.aws_cloudfront_cache_policy.disabled.id
    origin_request_policy_id   = data.aws_cloudfront_origin_request_policy.all_viewer.id
    response_headers_policy_id = data.aws_cloudfront_response_headers_policy.security_headers.id
  }

  # 静的アセット (ファイル名にダイジェストを含む) はキャッシュしてオリジン負荷を下げる
  ordered_cache_behavior {
    path_pattern               = "/assets/*"
    target_origin_id           = local.origin_id
    viewer_protocol_policy     = "redirect-to-https"
    allowed_methods            = ["GET", "HEAD"]
    cached_methods             = ["GET", "HEAD"]
    compress                   = true
    cache_policy_id            = data.aws_cloudfront_cache_policy.optimized.id
    response_headers_policy_id = data.aws_cloudfront_response_headers_policy.security_headers.id
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = !local.use_custom_domain
    acm_certificate_arn            = local.use_custom_domain ? var.acm_certificate_arn : null
    ssl_support_method             = local.use_custom_domain ? "sni-only" : null
    minimum_protocol_version       = local.use_custom_domain ? "TLSv1.2_2021" : "TLSv1"
  }

  tags = { Name = "${var.project}-cf" }
}

resource "aws_route53_record" "redmine" {
  for_each = local.use_custom_domain && var.route53_zone_id != "" ? toset(["A", "AAAA"]) : toset([])

  zone_id = var.route53_zone_id
  name    = var.custom_domain
  type    = each.key

  alias {
    name                   = aws_cloudfront_distribution.redmine.domain_name
    zone_id                = aws_cloudfront_distribution.redmine.hosted_zone_id
    evaluate_target_health = false
  }
}
