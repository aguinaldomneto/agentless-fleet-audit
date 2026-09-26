# Atalhos do Terraform desta nuvem. Não substituem plan/apply manual (README
# tem o passo a passo completo) — só evitam repetir "pega o IP novo, cola no
# ssh, entra e sobe tudo" toda vez que a VM liga.
.PHONY: up down destroy ssh bootstrap

up:              ## sobe/liga a VM (pede confirmação do terraform) e mostra os comandos prontos
	terraform apply
	@echo
	@echo "SSH:    $$(terraform output -raw ssh)"
	@echo "Túnel:  $$(terraform output -raw tunel)"

down:            ## pausa a VM (não destrói; some o crédito de CPU, IP muda ao religar)
	terraform apply -var instance_state=stopped

destroy:         ## remove a VM e a VPC de vez
	terraform destroy

ssh:             ## conecta por SSH (IP lido do state atual, sem copiar/colar)
	@eval "$$(terraform output -raw ssh)"

bootstrap: up    ## liga a VM e já sobe o laboratório inteiro nela (make up + fleet-up + legacy-up)
	@ip=$$(terraform output -raw public_ip); \
	key=$$(terraform output -raw ssh_key_path); \
	echo "Aguardando SSH em $$ip..."; \
	i=0; until ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
	  -i "$$key" ubuntu@"$$ip" true 2>/dev/null; do \
	    i=$$((i+1)); [ $$i -lt 30 ] || { echo "SSH não respondeu em 2 min"; exit 1; }; sleep 4; \
	done; \
	echo "Subindo o ambiente (env, docker compose, n8n, frota e legados)..."; \
	ssh -i "$$key" ubuntu@"$$ip" 'cd agentless-fleet-audit && make up && make fleet-up && make legacy-up'; \
	echo; echo "Pronto. Túnel: $$(terraform output -raw tunel)"
