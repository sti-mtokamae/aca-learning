.PHONY: smoke doctor routes routes-apply rotate-apisix-key vnet-poc

smoke:
	./scripts/smoke.sh

doctor:
	./scripts/doctor.sh

routes:
	./scripts/routes.sh

routes-apply:
	./apisix/register-routes.sh

rotate-apisix-key:
	./scripts/rotate-apisix-admin-key.sh

vnet-poc:
	./scripts/create-vnet-poc.sh
