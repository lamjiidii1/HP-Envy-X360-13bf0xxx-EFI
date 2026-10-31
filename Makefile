PYTHON ?= python3
IDENTITY ?= private/identity.plist
VERIFY_FLAGS ?=

.PHONY: all build verify variants inventory clean help

help:
	@echo "make build     - build the default EFI (wex061 + airportitlwm) into build/EFI"
	@echo "make verify    - run structural checks on build/EFI"
	@echo "make variants  - build all GPU/Wi-Fi combinations plus a debug EFI"
	@echo "make inventory - regenerate audit/payloads.tsv"
	@echo "make clean     - remove build/"

all: build verify

build:
	$(PYTHON) scripts/build_efi.py --identity $(IDENTITY) --force
	$(PYTHON) scripts/verify_efi.py $(VERIFY_FLAGS) build/EFI

verify:
	@test -d build/EFI || { echo "build/EFI not found: run 'make build' first" >&2; exit 1; }
	$(PYTHON) scripts/verify_efi.py $(VERIFY_FLAGS) build/EFI

variants:
	$(PYTHON) scripts/build_efi.py --identity $(IDENTITY) --gpu wex061 --wifi airportitlwm --out build/EFI --force
	$(PYTHON) scripts/build_efi.py --identity $(IDENTITY) --gpu wex061 --wifi itlwm --out build/EFI-itlwm --force
	$(PYTHON) scripts/build_efi.py --identity $(IDENTITY) --gpu hp-adlp-edp --wifi airportitlwm --out build/EFI-hp --force
	$(PYTHON) scripts/build_efi.py --identity $(IDENTITY) --gpu hp-adlp-edp --wifi itlwm --out build/EFI-hp-itlwm --force
	$(PYTHON) scripts/build_efi.py --identity $(IDENTITY) --debug --out build/EFI-debug --force
	@for dir in build/EFI build/EFI-itlwm build/EFI-hp build/EFI-hp-itlwm build/EFI-debug; do \
		$(PYTHON) scripts/verify_efi.py $(VERIFY_FLAGS) $$dir || exit 1; \
	done

inventory:
	$(PYTHON) scripts/payload_inventory.py > audit/payloads.tsv

clean:
	rm -rf build
