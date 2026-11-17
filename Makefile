PYTHON ?= python3
OUT ?= dist

.PHONY: all build test check checksums clean

all: build

build:
	$(PYTHON) tools/build-script.py
	mkdir -p $(OUT)
	cp reos.sh $(OUT)/reos.sh
	chmod 755 $(OUT)/reos.sh

checksums: build
	cd $(OUT) && sha256sum reos.sh > sha256sums.txt

test:
	$(PYTHON) tests/test_script.py

check:
	$(PYTHON) tools/build-script.py --check
	bash -n reos.sh
	bash -n tests/live-download.sh
	sh -n install.sh
	shellcheck -S warning reos.sh install.sh tests/live-download.sh

clean:
	rm -rf $(OUT)
