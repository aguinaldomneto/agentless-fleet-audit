data "oci_identity_availability_domains" "ads" {
  compartment_id = var.tenancy_ocid
}

# Ubuntu 24.04 ARM mais recente publicado pela Oracle para o shape A1
data "oci_core_images" "ubuntu" {
  compartment_id           = local.compartment
  operating_system         = "Canonical Ubuntu"
  operating_system_version = "24.04"
  shape                    = "VM.Standard.A1.Flex"
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
}

resource "oci_core_instance" "lab" {
  compartment_id      = local.compartment
  availability_domain = data.oci_identity_availability_domains.ads.availability_domains[var.availability_domain_index].name
  display_name        = "${local.name}-lab"
  shape               = "VM.Standard.A1.Flex"

  shape_config {
    ocpus         = var.ocpus
    memory_in_gbs = var.memory_gbs
  }

  source_details {
    source_type             = "image"
    source_id               = data.oci_core_images.ubuntu.images[0].id
    boot_volume_size_in_gbs = var.boot_volume_gbs
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.lab.id
    assign_public_ip = true
  }

  # Só o endpoint de metadados v2 (exige header), como IMDSv2 na AWS
  instance_options {
    are_legacy_imds_endpoints_disabled = true
  }

  metadata = {
    ssh_authorized_keys = file(pathexpand(var.ssh_public_key_path))

    # Segredos NÃO passam por aqui: user_data fica legível nos metadados e o
    # tfstate guarda tudo em texto. O .env é gerado dentro da VM (make env).
    user_data = base64encode(templatefile("${path.module}/cloud-init.yaml", {
      repo_url = var.repo_url
      repo_ref = var.repo_ref
    }))
  }

  lifecycle {
    # Imagem nova publicada pela Oracle não deve recriar a VM (e apagar os dados)
    ignore_changes = [source_details[0].source_id, metadata["user_data"]]
  }
}
