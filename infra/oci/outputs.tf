output "public_ip" {
  description = "IP público da VM"
  value       = oci_core_instance.lab.public_ip
}

output "ssh" {
  description = "Acesso SSH"
  value       = "ssh ubuntu@${oci_core_instance.lab.public_ip}"
}

output "tunel" {
  description = "n8n em localhost:5678 e Grafana em localhost:3000, sem abrir porta na nuvem"
  value       = "ssh -N -L 5678:127.0.0.1:5678 -L 3000:127.0.0.1:3000 ubuntu@${oci_core_instance.lab.public_ip}"
}

output "imagem" {
  description = "Imagem usada"
  value       = data.oci_core_images.ubuntu.images[0].display_name
}
