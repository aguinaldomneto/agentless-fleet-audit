terraform {
  required_version = ">= 1.6"
  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 8.0"
    }
  }
}

# Credenciais da API da OCI: ficam no terraform.tfvars (fora do Git) ou em
# variáveis TF_VAR_*. A chave privada da API é lida do disco, nunca do repositório.
provider "oci" {
  tenancy_ocid     = var.tenancy_ocid
  user_ocid        = var.user_ocid
  fingerprint      = var.fingerprint
  private_key_path = pathexpand(var.private_key_path)
  region           = var.region
}
