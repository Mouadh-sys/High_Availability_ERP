SHELL := /bin/bash
ANSIBLE_DIR := ansible
PLAY := cd $(ANSIBLE_DIR) && ansible-playbook

.DEFAULT_GOAL := help

.PHONY: help preflight net vms bootstrap site verify db-status db-failover db-rejoin test test-fast teardown syntax reset

help: ## Show available targets
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

preflight: ## Check host prerequisites and download the Debian cloud image
	./scripts/00-host-preflight.sh

net: ## Create the ha-erp-net libvirt network
	./scripts/01-create-network.sh

vms: ## Create and boot the four VMs
	./scripts/02-create-vms.sh

bootstrap: ## Base OS, users, firewall, SSH, time sync
	$(PLAY) playbooks/bootstrap.yml

site: ## Full infrastructure deployment (NFS, PG, Odoo, HAProxy, Keepalived)
	$(PLAY) playbooks/site.yml

verify: ## Health report of every layer -> evidence/
	$(PLAY) playbooks/verify.yml

db-status: ## Show PostgreSQL role / replication state through the DB VIP
	PGPASSWORD="$${PGPASSWORD:-}" psql -h 192.168.50.30 -U odoo -d ha_erp -c \
	  "select pg_is_in_recovery() as in_recovery, now()-pg_last_xact_replay_timestamp() as replay_lag;"

db-failover: ## Controlled promotion of erp02 (fences erp01 by default)
	$(PLAY) playbooks/db-failover.yml -e confirm_fence=yes

db-rejoin: ## Rebuild the former primary as a standby
	$(PLAY) playbooks/db-rejoin.yml -e confirm_rebootstrap=yes

test: ## Run the full T01–T09 failure-injection suite
	./tests/run-all.sh

test-fast: ## Run only baseline + application failover (T01–T03)
	./tests/t01-baseline.sh && ./tests/t02-app-failover.sh && ./tests/t03-app-failover-reverse.sh

syntax: ## Ansible syntax check of all playbooks
	cd $(ANSIBLE_DIR) && ansible-playbook playbooks/bootstrap.yml --syntax-check && \
	  ansible-playbook playbooks/site.yml --syntax-check && \
	  ansible-playbook playbooks/verify.yml --syntax-check && \
	  ansible-playbook playbooks/db-failover.yml --syntax-check && \
	  ansible-playbook playbooks/db-rejoin.yml --syntax-check

teardown: ## Destroy VMs and the network (keeps the Debian image)
	./scripts/99-teardown.sh

reset: ## Teardown + recreate network and VMs
	./scripts/99-teardown.sh -y && ./scripts/01-create-network.sh && ./scripts/02-create-vms.sh
