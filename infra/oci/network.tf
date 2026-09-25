locals {
  compartment = var.compartment_ocid != "" ? var.compartment_ocid : var.tenancy_ocid
  name        = "fleet-audit"
}

resource "oci_core_vcn" "lab" {
  compartment_id = local.compartment
  cidr_blocks    = ["10.20.0.0/16"]
  display_name   = "${local.name}-vcn"
  dns_label      = "fleetaudit"
}

resource "oci_core_internet_gateway" "lab" {
  compartment_id = local.compartment
  vcn_id         = oci_core_vcn.lab.id
  display_name   = "${local.name}-igw"
  enabled        = true
}

resource "oci_core_route_table" "lab" {
  compartment_id = local.compartment
  vcn_id         = oci_core_vcn.lab.id
  display_name   = "${local.name}-rt"

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.lab.id
  }
}

# Só SSH, só do IP informado. n8n (5678) e Grafana (3000) NÃO são expostos:
# o acesso é por túnel SSH, igual ao laboratório local (portas em 127.0.0.1).
resource "oci_core_security_list" "lab" {
  compartment_id = local.compartment
  vcn_id         = oci_core_vcn.lab.id
  display_name   = "${local.name}-sl"

  egress_security_rules {
    destination = "0.0.0.0/0"
    protocol    = "all"
  }

  ingress_security_rules {
    protocol = "6" # TCP
    source   = var.allowed_ssh_cidr

    tcp_options {
      min = 22
      max = 22
    }
  }

  ingress_security_rules {
    protocol = "1" # ICMP 3/4: descoberta de MTU (sem isso, conexões podem travar)
    source   = "0.0.0.0/0"

    icmp_options {
      type = 3
      code = 4
    }
  }
}

resource "oci_core_subnet" "lab" {
  compartment_id             = local.compartment
  vcn_id                     = oci_core_vcn.lab.id
  cidr_block                 = "10.20.1.0/24"
  display_name               = "${local.name}-subnet"
  dns_label                  = "lab"
  route_table_id             = oci_core_route_table.lab.id
  security_list_ids          = [oci_core_security_list.lab.id]
  prohibit_public_ip_on_vnic = false
}
