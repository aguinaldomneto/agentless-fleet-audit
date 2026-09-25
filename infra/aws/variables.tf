variable "region" {
  description = "Região. us-east-1 é a mais barata (os créditos rendem mais); sa-east-1 tem menos latência"
  type        = string
  default     = "us-east-1"
}

variable "aws_profile" {
  description = "Perfil do AWS CLI com as credenciais do usuário IAM"
  type        = string
  default     = "fleet-audit"
}

variable "allowed_ssh_cidr" {
  description = "Único endereço liberado na porta 22, no formato x.x.x.x/32 (curl -s ifconfig.me)"
  type        = string

  validation {
    condition     = can(cidrhost(var.allowed_ssh_cidr, 0)) && var.allowed_ssh_cidr != "0.0.0.0/0"
    error_message = "Informe um CIDR válido e restrito (ex.: 200.1.2.3/32). 0.0.0.0/0 não é aceito."
  }
}

variable "ssh_public_key_path" {
  description = "Chave pública SSH que entra na VM (usuário ubuntu)"
  type        = string
  default     = "~/.ssh/oci_lab.pub"
}

variable "instance_type" {
  description = "Tipo da VM. m7i-flex.large (2 vCPU, 8 GB) é elegível ao plano gratuito de contas novas"
  type        = string
  default     = "m7i-flex.large"

  validation {
    condition     = contains(["m7i-flex.large", "c7i-flex.large"], var.instance_type)
    error_message = "Use m7i-flex.large (8 GB) ou c7i-flex.large (4 GB): elegíveis ao free tier e com memória para o laboratório."
  }
}

variable "disk_gb" {
  description = "Disco gp3 em GB"
  type        = number
  default     = 30
}

variable "instance_state" {
  description = "running ou stopped. Parada, a VM não gasta crédito de CPU (só o disco)"
  type        = string
  default     = "running"

  validation {
    condition     = contains(["running", "stopped"], var.instance_state)
    error_message = "Use running ou stopped."
  }
}

variable "repo_url" {
  description = "Repositório clonado na VM"
  type        = string
  default     = "https://github.com/aguinaldomneto/agentless-fleet-audit.git"
}

variable "repo_ref" {
  description = "Branch ou tag"
  type        = string
  default     = "main"
}
