.PHONY: all compile get-deps generate_tgz clean

PKG_NAME = mns_py

all:

generate_tgz:
	mkdir -p pkgroot/${PKG_NAME}
	cp -R src/* pkgroot/${PKG_NAME}/
	
	cd pkgroot && tar czf ../${PKG_NAME}.tgz ./${PKG_NAME} && cd ..
	rm -rf pkgroot

clean:
	rm -rf pkgroot
	rm -f *.tgz
	rm -f src/*.pyc
