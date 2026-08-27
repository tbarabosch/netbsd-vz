SHELL := /bin/sh

DISK ?= $(CURDIR)/.build/out/netbsd-vz.raw

.DEFAULT_GOAL := help

.PHONY: help build disk run run-network smoke smoke-network \
	smoke-persistence smoke-repeat clean

help:
	@printf '%s\n' \
	  'make build              Build stock NetBSD 11.0 GENERIC64 with three Virtio fixes' \
	  'make disk               Build the EFI/GPT/FAT32/FFS disk' \
	  'make run                Boot a disposable clone through EFI/ACPI' \
	  'make run-network        Boot with opt-in Virtio NAT' \
	  'make smoke              Prove EFI/ACPI, login, storage, and poweroff' \
	  'make smoke-network      Add DHCP, gateway, and public network proof' \
	  'make smoke-persistence  Prove disk and EFI-variable-state persistence' \
	  'make smoke-repeat       Prove five consecutive cold EFI boots' \
	  'make clean              Remove objects and outputs, preserving expensive caches'

build:
	./scripts/build.sh

disk:
	./scripts/build-disk.sh

run:
	./scripts/run.sh --disk "$(DISK)"

run-network:
	./scripts/run.sh --disk "$(DISK)" --network

smoke:
	./scripts/run.sh --disk "$(DISK)" --smoke

smoke-network:
	./scripts/run.sh --disk "$(DISK)" --network --smoke

smoke-persistence:
	./scripts/test-persistence.sh

smoke-repeat:
	./scripts/test-repeat.sh

clean:
	./scripts/clean.sh
