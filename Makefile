SHELL := /bin/sh

DISK ?= $(CURDIR)/.build/out/netbsd-vz.raw
AGENT_DISK ?= $(CURDIR)/.build/out/netbsd-vz-agent.raw

.DEFAULT_GOAL := build

.PHONY: build disk agent agent-disk platform-kit oci-base publish-oci-base runtime runtime-deps install-runtime run run-agent run-network protocol-test agent-test runtime-test test clean

build:
	./scripts/build.sh

disk:
	./scripts/build-disk.sh

agent:
	./scripts/build-agent.sh

agent-disk: agent
	NETBSD_VZ_AGENT_DISK=1 ./scripts/build-disk.sh

platform-kit: build
	./scripts/build-platform-kit.sh

oci-base: runtime
	./scripts/build-oci-base.sh

publish-oci-base: oci-base
	./scripts/publish-oci-base.sh --push

runtime:
	./scripts/build-runtime.sh

runtime-deps:
	./scripts/prepare-runtime-dependencies.sh

install-runtime: runtime agent platform-kit
	./scripts/install-runtime.sh

run:
	./scripts/run.sh --disk "$(DISK)"

run-agent:
	./scripts/run.sh --disk "$(AGENT_DISK)"

run-network:
	./scripts/run.sh --disk "$(DISK)" --network

protocol-test:
	cc -std=c11 -Wall -Wextra -Werror -pedantic protocol/c/nvza_protocol.c protocol/c/tests/protocol_test.c -o /tmp/nvza-protocol-test
	/tmp/nvza-protocol-test
	cd protocol && swift test

agent-test:
	$(MAKE) -C agent test

runtime-test: runtime-deps
	cd runtime && swift test

test: protocol-test agent-test runtime-test

clean:
	./scripts/clean.sh
