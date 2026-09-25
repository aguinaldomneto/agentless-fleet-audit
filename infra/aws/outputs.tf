output "public_ip" {
  description = "IP público (muda a cada stop/start; atualize com terraform apply -refresh-only)"
  value       = aws_instance.lab.public_ip
}

output "ssh" {
  description = "Acesso SSH"
  value       = "ssh -i ${trimsuffix(pathexpand(var.ssh_public_key_path), ".pub")} ubuntu@${aws_instance.lab.public_ip}"
}

output "tunel" {
  description = "n8n em localhost:5678 e Grafana em localhost:3000, sem abrir porta na nuvem"
  value       = "ssh -i ${trimsuffix(pathexpand(var.ssh_public_key_path), ".pub")} -N -L 5678:127.0.0.1:5678 -L 3000:127.0.0.1:3000 ubuntu@${aws_instance.lab.public_ip}"
}

output "ami" {
  description = "Imagem usada"
  value       = data.aws_ami.ubuntu.name
}
