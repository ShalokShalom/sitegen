
.PHONY: build local install

local: build
	luarocks make --local

install: build
	sudo luarocks make

build::
	moonc sitegen

