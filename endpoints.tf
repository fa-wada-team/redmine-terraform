################################################################################
# インターフェイス VPC エンドポイントの自動作成 / 自動削除
#
# インターフェイスエンドポイントは 1 個あたり約 $10/月 かかるため常設せず、
# 必要なとき (初回構築 / EC2 再作成 / バージョンアップ作業) だけ Lambda が作成し、
# 期限 (既定 60 分) を過ぎたら自動で削除する。
#
#  [自動作成] EventBridge ルール : Redmine EC2 が新規に起動 (running) → Lambda "create"
#             ※ 停止 → 起動 (日次スケジュール等) では作成しない
#  [手動作成] aws lambda invoke ... '{"action":"create","ttl_minutes":120}'
#  [自動削除] EventBridge Scheduler (定期実行) → Lambda "cleanup" で期限切れを削除
#  [destroy ] terraform destroy 時に Lambda で全削除してから VPC 等を削除
################################################################################

locals {
  endpoint_manager_name     = "${var.project}-endpoint-manager"
  endpoint_instance_tag_key = "EndpointManager"
  endpoint_service_names    = [for s in local.interface_endpoints : "com.amazonaws.${var.region}.${s}"]
}

data "archive_file" "endpoint_manager" {
  type        = "zip"
  source_dir  = "${path.module}/lambda/endpoint_manager"
  output_path = "${path.module}/.cache/endpoint_manager.zip"
}

################################################################################
# Lambda
################################################################################

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "endpoint_manager" {
  name               = "${local.endpoint_manager_name}-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy_attachment" "endpoint_manager_logs" {
  role       = aws_iam_role.endpoint_manager.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "aws_iam_policy_document" "endpoint_manager" {
  statement {
    sid       = "Describe"
    actions   = ["ec2:DescribeVpcEndpoints", "ec2:DescribeInstances"]
    resources = ["*"]
  }

  statement {
    sid     = "CreateEndpoint"
    actions = ["ec2:CreateVpcEndpoint"]
    resources = [
      aws_vpc.main.arn,
      aws_subnet.private.arn,
      aws_security_group.vpc_endpoint.arn,
      "arn:aws:ec2:${var.region}:${data.aws_caller_identity.current.account_id}:vpc-endpoint/*",
    ]
  }

  statement {
    sid       = "TagOnCreate"
    actions   = ["ec2:CreateTags"]
    resources = ["arn:aws:ec2:${var.region}:${data.aws_caller_identity.current.account_id}:vpc-endpoint/*"]

    condition {
      test     = "StringEquals"
      variable = "ec2:CreateAction"
      values   = ["CreateVpcEndpoint"]
    }
  }

  statement {
    sid       = "ManageOwnEndpoints"
    actions   = ["ec2:CreateTags", "ec2:DeleteVpcEndpoints"]
    resources = ["arn:aws:ec2:${var.region}:${data.aws_caller_identity.current.account_id}:vpc-endpoint/*"]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/EndpointManager"
      values   = [var.project]
    }
  }

  # プライベート DNS を有効にしたエンドポイントの作成 / 削除に必要
  statement {
    sid       = "PrivateDns"
    actions   = ["route53:AssociateVPCWithHostedZone", "route53:DisassociateVPCFromHostedZone"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "endpoint_manager" {
  name   = "manage-interface-endpoints"
  role   = aws_iam_role.endpoint_manager.id
  policy = data.aws_iam_policy_document.endpoint_manager.json
}

resource "aws_cloudwatch_log_group" "endpoint_manager" {
  name              = "/aws/lambda/${local.endpoint_manager_name}"
  retention_in_days = 14
}

resource "aws_lambda_function" "endpoint_manager" {
  function_name    = local.endpoint_manager_name
  description      = "Create / delete interface VPC endpoints on demand"
  role             = aws_iam_role.endpoint_manager.arn
  runtime          = "python3.12"
  architectures    = ["arm64"]
  handler          = "index.handler"
  filename         = data.archive_file.endpoint_manager.output_path
  source_code_hash = data.archive_file.endpoint_manager.output_base64sha256
  timeout          = 600
  memory_size      = 128

  environment {
    variables = {
      VPC_ID                      = aws_vpc.main.id
      SUBNET_ID                   = aws_subnet.private.id
      SECURITY_GROUP_ID           = aws_security_group.vpc_endpoint.id
      SERVICE_NAMES               = join(",", local.endpoint_service_names)
      MANAGED_TAG_VALUE           = var.project
      INSTANCE_TAG_KEY            = local.endpoint_instance_tag_key
      INSTANCE_TAG_VALUE          = var.project
      DEFAULT_TTL_MINUTES         = tostring(var.endpoint_ttl_minutes)
      NEW_INSTANCE_WINDOW_MINUTES = "30"
      NAME_PREFIX                 = var.project
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.endpoint_manager,
    aws_iam_role_policy_attachment.endpoint_manager_logs,
    aws_iam_role_policy.endpoint_manager,
  ]
}

################################################################################
# 自動作成: EC2 の新規起動を検知 (EventBridge ルール)
# インスタンス ID は再作成で変わるため全インスタンスの running を受け、
# Lambda 側でタグと作成時刻 (新規起動かどうか) を判定する
################################################################################

resource "aws_cloudwatch_event_rule" "endpoint_on_launch" {
  name        = "${var.project}-endpoint-on-launch"
  description = "Create interface VPC endpoints when the Redmine EC2 is newly launched"

  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["EC2 Instance State-change Notification"]
    detail = {
      state = ["running"]
    }
  })
}

resource "aws_cloudwatch_event_target" "endpoint_on_launch" {
  rule = aws_cloudwatch_event_rule.endpoint_on_launch.name
  arn  = aws_lambda_function.endpoint_manager.arn
}

resource "aws_lambda_permission" "eventbridge" {
  statement_id  = "AllowEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.endpoint_manager.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.endpoint_on_launch.arn
}

################################################################################
# 自動削除: 期限切れエンドポイントを定期的に削除 (EventBridge Scheduler)
################################################################################

data "aws_iam_policy_document" "endpoint_scheduler_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "endpoint_scheduler" {
  name               = "${var.project}-endpoint-scheduler-role"
  assume_role_policy = data.aws_iam_policy_document.endpoint_scheduler_assume.json
}

data "aws_iam_policy_document" "endpoint_scheduler" {
  statement {
    actions   = ["lambda:InvokeFunction"]
    resources = [aws_lambda_function.endpoint_manager.arn]
  }
}

resource "aws_iam_role_policy" "endpoint_scheduler" {
  name   = "invoke-endpoint-manager"
  role   = aws_iam_role.endpoint_scheduler.id
  policy = data.aws_iam_policy_document.endpoint_scheduler.json
}

resource "aws_scheduler_schedule" "endpoint_cleanup" {
  name                = "${var.project}-endpoint-cleanup"
  description         = "Delete expired interface VPC endpoints"
  schedule_expression = var.endpoint_cleanup_rate

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = aws_lambda_function.endpoint_manager.arn
    role_arn = aws_iam_role.endpoint_scheduler.arn
    input    = jsonencode({ action = "cleanup" })
  }
}

################################################################################
# terraform destroy 時: Lambda が作成したエンドポイントを全削除してから
# サブネット / セキュリティグループ / VPC を削除する
################################################################################

resource "aws_lambda_invocation" "endpoint_cleanup_on_destroy" {
  function_name   = aws_lambda_function.endpoint_manager.function_name
  input           = jsonencode({})
  lifecycle_scope = "CRUD"

  depends_on = [
    aws_vpc.main,
    aws_subnet.private,
    aws_security_group.vpc_endpoint,
    aws_iam_role_policy.endpoint_manager,
    aws_iam_role_policy_attachment.endpoint_manager_logs,
  ]
}
