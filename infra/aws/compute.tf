# Ubuntu 24.04 x86 mais recente publicado pela Canonical (dona oficial 099720109477)
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_key_pair" "lab" {
  key_name   = "${local.name}-lab"
  public_key = file(pathexpand(var.ssh_public_key_path))
}

resource "aws_instance" "lab" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.lab.id
  vpc_security_group_ids = [aws_security_group.lab.id]
  key_name               = aws_key_pair.lab.key_name

  # IMDSv2 obrigatório: metadados só com token (bloqueia SSRF clássico)
  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = var.disk_gb
    encrypted   = true
  }

  # Segredos NÃO passam por aqui: user_data fica legível para quem acessa a
  # instância e o tfstate guarda tudo em texto. O .env é gerado dentro da VM.
  user_data = templatefile("${path.module}/../cloud-init.yaml", {
    repo_url = var.repo_url
    repo_ref = var.repo_ref
  })

  tags = { Name = "${local.name}-lab" }

  lifecycle {
    # AMI nova publicada pela Canonical não deve recriar a VM (e apagar os dados)
    ignore_changes = [ami, user_data]
  }
}

# Liga/desliga pelo Terraform: terraform apply -var instance_state=stopped
resource "aws_ec2_instance_state" "lab" {
  instance_id = aws_instance.lab.id
  state       = var.instance_state
}
