all: system-file-magic depcheck 

buildapp:
	sbcl --no-userinit --no-sysinit --non-interactive \
		--load $(HOME)/quicklisp/setup.lisp \
		--eval '(ql:quickload "buildapp")' \
		--eval '(buildapp:build-buildapp "buildapp")'

depcheck: asdf.lisp depcheck.lisp buildapp
	./buildapp --dynamic-space-size 4000 --output depcheck --require asdf --entry depcheck:main --load depcheck.lisp

system-file-magic: asdf.lisp system-file-magic.lisp buildapp
	./buildapp --dynamic-space-size 4000 --output system-file-magic --require asdf --load system-file-magic.lisp --entry system-file-magic:main

install: system-file-magic depcheck
	mkdir -p $(HOME)/bin
	install -c -m 555 system-file-magic $(HOME)/bin
	install -c -m 555 depcheck $(HOME)/bin

clean:
	rm -f system-file-magic depcheck
