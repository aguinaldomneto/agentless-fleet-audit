# --- autenticação na API da OCI ---------------------------------------------
variable "tenancy_ocid" {
  description = "OCID da tenancy (Perfil > Tenancy)"
  type        = string
}

variable "user_ocid" {
  description = "OCID do usuário dono da chave de API"
  type        = string
}

variable "fingerprint" {
  description = "Fingerprint da chave de API cadastrada no usuário"
  type        = string
}

variable "private_key_path" {
  description = "Caminho da chave privada da API (PEM), fora do repositório"
  type        = string
}

variable "region" {
  description = "Região HOME da tenancy (Always Free só vale nela). Ex.: sa-saopaulo-1"
  type        = string
}

variable "compartment_ocid" {
  description = "Compartimento onde tudo é criado. Vazio = raiz da tenancy"
  type        = string
  default     = ""
}

# --- acesso ------------------------------------------------------------------
variable "ssh_public_key_path" {
  description = "Chave pública SSH que entra na VM (usuário ubuntu)"
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}

variable "allowed_ssh_cidr" {
  description = "Único endereço liberado na porta 22, no formato x.x.x.x/32 (curl -s ifconfig.me)"
  type        = string

  validation {
    condition     = can(cidrhost(var.allowed_ssh_cidr, 0)) && var.allowed_ssh_cidr != "0.0.0.0/0"
    error_message = "Informe um CIDR válido e restrito (ex.: 200.1.2.3/32). 0.0.0.0/0 não é aceito."
  }
}

# --- dimensionamento (limites Always Free desde 06/2026: 2 OCPU / 12 GB no total) --
variable "ocpus" {
  description = "OCPUs Ampere A1"
  type        = number
  default     = 2

  validation {
    condition     = var.ocpus >= 1 && var.ocpus <= 2
    error_message = "O Always Free permite no máximo 2 OCPUs Ampere A1."
  }
}

variable "memory_gbs" {
  description = "Memória em GB"
  type        = number
  default     = 12

  validation {
    condition     = var.memory_gbs >= 6 && var.memory_gbs <= 12
    error_message = "Use entre 6 e 12 GB (o laboratório precisa de ~4 GB; o Always Free vai até 12)."
  }
}

variable "boot_volume_gbs" {
  description = "Disco de boot em GB (Always Free: 200 GB somando todos os volumes)"
  type        = number
  default     = 100
}

variable "availability_domain_index" {
  description = "Índice do AD. Troque se aparecer 'Out of host capacity'"
  type        = number
  default     = 0
}

# --- o que a VM clona --------------------------------------------------------
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
