terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

# Credenciais: perfil do AWS CLI (aws configure --profile fleet-audit), de um
# usuário IAM só com EC2. Nunca a conta root, nunca chave no repositório.
provider "aws" {
  region  = var.region
  profile = var.aws_profile

  default_tags {
    tags = {
      Project   = "agentless-fleet-audit"
      ManagedBy = "terraform"
    }
  }
}
