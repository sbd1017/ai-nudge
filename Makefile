build:
	./build.sh

install: build
	-pkill -x AINudge
	rm -rf "$(HOME)/Applications/AI Nudge.app"
	mkdir -p "$(HOME)/Applications"
	cp -R "build/AI Nudge.app" "$(HOME)/Applications/"
	open "$(HOME)/Applications/AI Nudge.app"

.PHONY: build install
