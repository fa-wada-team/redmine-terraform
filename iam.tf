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
# NAT インスタンス用 (SSM Session Manager のみ)
################################################################################

resource "aws_iam_role" "ssm" {
  name               = "${var.project}-nat-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.ssm.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ssm" {
  name = "${var.project}-nat-profile"
  role = aws_iam_role.ssm.name
}

################################################################################
# Redmine EC2 用 (SSM Session Manager + シークレット読み取り)
################################################################################

resource "aws_iam_role" "redmine" {
  name               = "${var.project}-ec2-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy_attachment" "redmine_ssm_core" {
  role       = aws_iam_role.redmine.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "redmine_params" {
  statement {
    actions = ["ssm:GetParameter", "ssm:GetParameters"]
    resources = [
      aws_ssm_parameter.db_password.arn,
      aws_ssm_parameter.secret_key_base.arn,
    ]
  }
}

resource "aws_iam_role_policy" "redmine_params" {
  name   = "read-redmine-secrets"
  role   = aws_iam_role.redmine.id
  policy = data.aws_iam_policy_document.redmine_params.json
}

resource "aws_iam_instance_profile" "redmine" {
  name = "${var.project}-ec2-profile"
  role = aws_iam_role.redmine.name
}
