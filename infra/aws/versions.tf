terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

# Credenciais: perfil do AWS CLI (aws configure --profile fleet-audit) na sua
# máquina, de um usuário IAM só com EC2. Nunca a conta root, nunca chave no
# repositório. No GitHub Actions (workflow aws-deploy.yml) aws_profile vem
# vazio de propósito: as credenciais são as que o OIDC (github-oidc.tf)
# injeta no ambiente, sem chave de longa duração guardada em lugar nenhum.
provider "aws" {
  region  = var.region
  profile = var.aws_profile != "" ? var.aws_profile : null

  default_tags {
    tags = {
      Project   = "agentless-fleet-audit"
      ManagedBy = "terraform"
    }
  }
}
