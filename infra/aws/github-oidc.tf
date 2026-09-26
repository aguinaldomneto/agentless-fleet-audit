# Permite ao workflow aws-deploy.yml (GitHub Actions) assumir um papel na AWS
# sem chave de longa duração — nenhum access key fica guardado em lugar
# nenhum, nem como secret do GitHub. O provedor OIDC é único por conta AWS:
# se você já tiver um de outro projeto, importe em vez de duplicar
# (terraform import aws_iam_openid_connect_provider.github <arn>).
resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
  # Thumbprint documentado pela própria AWS para o provedor da GitHub Actions.
  # A AWS não valida mais este valor na prática (a cadeia é verificada pelo
  # certificado apresentado em tempo real), mas o argumento continua
  # obrigatório no schema do provider.
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

# Só este repositório, só a branch configurada (var.github_ref). "sub" com
# curinga de repo inteiro (repo:owner/repo:*) aceitaria PR de fork e tag —
# não use: é o erro mais comum de configurar OIDC do GitHub frouxo demais.
data "aws_iam_policy_document" "github_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repo}:ref:refs/heads/${var.github_ref}"]
    }
  }
}

resource "aws_iam_role" "github_actions" {
  name               = "${local.name}-github-actions"
  assume_role_policy = data.aws_iam_policy_document.github_trust.json
}

# Só as ações de EC2/VPC que este Terraform usa (compute.tf, network.tf).
# A maioria das ações do EC2 não aceita restrição por ARN de recurso — é
# limitação do próprio serviço, não deste código: por isso "resources = [*]"
# aqui não significa "acesso total à conta", significa "só estas ações,
# em qualquer recurso EC2/VPC" (nunca S3, IAM, RDS etc.).
data "aws_iam_policy_document" "github_actions" {
  statement {
    sid    = "TerraformEC2eVPC"
    effect = "Allow"
    actions = [
      "ec2:Describe*",
      "ec2:RunInstances",
      "ec2:TerminateInstances",
      "ec2:StartInstances",
      "ec2:StopInstances",
      "ec2:ModifyInstanceAttribute",
      "ec2:ModifyInstanceMetadataOptions",
      "ec2:CreateTags",
      "ec2:DeleteTags",
      "ec2:CreateVpc",
      "ec2:DeleteVpc",
      "ec2:ModifyVpcAttribute",
      "ec2:CreateSubnet",
      "ec2:DeleteSubnet",
      "ec2:CreateInternetGateway",
      "ec2:DeleteInternetGateway",
      "ec2:AttachInternetGateway",
      "ec2:DetachInternetGateway",
      "ec2:CreateRouteTable",
      "ec2:DeleteRouteTable",
      "ec2:CreateRoute",
      "ec2:DeleteRoute",
      "ec2:AssociateRouteTable",
      "ec2:DisassociateRouteTable",
      "ec2:ReplaceRouteTableAssociation",
      "ec2:CreateSecurityGroup",
      "ec2:DeleteSecurityGroup",
      "ec2:AuthorizeSecurityGroupIngress",
      "ec2:AuthorizeSecurityGroupEgress",
      "ec2:RevokeSecurityGroupIngress",
      "ec2:RevokeSecurityGroupEgress",
      "ec2:ImportKeyPair",
      "ec2:DeleteKeyPair",
    ]
    resources = ["*"]
  }

  # Estado remoto (backend.tf): ler/gravar o .tfstate e o lock.
  statement {
    sid    = "TerraformStateS3"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:ListBucket",
    ]
    resources = [
      "arn:aws:s3:::${var.tfstate_bucket}",
      "arn:aws:s3:::${var.tfstate_bucket}/*",
    ]
  }

  statement {
    sid       = "TerraformStateLock"
    effect    = "Allow"
    actions   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:DeleteItem"]
    resources = ["arn:aws:dynamodb:*:*:table/${var.tfstate_lock_table}"]
  }
}

resource "aws_iam_role_policy" "github_actions" {
  name   = "${local.name}-terraform"
  role   = aws_iam_role.github_actions.id
  policy = data.aws_iam_policy_document.github_actions.json
}

output "github_actions_role_arn" {
  description = "Configure como variável de repositório AWS_ROLE_ARN (Settings > Secrets and variables > Actions > Variables). Não é segredo: é só um identificador, quem pode usá-lo é decidido pelo assume_role_policy acima, não por quem lê este ARN."
  value       = aws_iam_role.github_actions.arn
}
