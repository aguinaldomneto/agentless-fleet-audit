# Estado remoto: pré-requisito pra rodar terraform apply a partir do GitHub
# Actions (aws-deploy.yml) sem perder o rastro do que já existe — sem isso,
# a run efêmera do runner cria/perde o .tfstate a cada execução e o próximo
# apply (seu, local, ou o do CI) tentaria recriar tudo do zero.
#
# Bloco de backend não aceita variável: configure com -backend-config (ou
# um backend.hcl, veja backend.hcl.example) na primeira vez:
#
#   terraform init -reconfigure \
#     -backend-config="bucket=SEU-BUCKET-UNICO-GLOBALMENTE" \
#     -backend-config="key=fleet-audit/terraform.tfstate" \
#     -backend-config="region=us-east-1" \
#     -backend-config="use_lockfile=true"   # lock nativo do S3, sem DynamoDB
#
# O bucket é criado por você, uma vez, FORA deste Terraform (README, seção
# Nuvem): não dá pra este código gerenciar o próprio backend (problema
# clássico do ovo e da galinha). O usuário/perfil IAM que roda o apply
# precisa de GetObject/PutObject/ListBucket nesse bucket — é permissão a
# mais além do "só EC2" original, então concedida à parte (README).
terraform {
  backend "s3" {}
}
