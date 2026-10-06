.PHONY: build test app run demo install uninstall clean

build:
	swift build

test:
	swift test

# build/Moonlet.app with the moonlet command inside.
app:
	scripts/build-app.sh

# Run the menu bar app from source.
run:
	swift run MoonletApp

# Run the app and play the one-minute demo.
demo:
	swift run MoonletApp --demo

# Copy the app to ~/Applications and link the command into ~/.local/bin.
install: app
	rm -rf ~/Applications/Moonlet.app
	mkdir -p ~/Applications ~/.local/bin
	cp -R build/Moonlet.app ~/Applications/
	ln -sf ~/Applications/Moonlet.app/Contents/Helpers/moonlet ~/.local/bin/moonlet
	@echo "Installed. Open ~/Applications/Moonlet.app, then choose Connect Claude Code… from the moon in the menu bar."

uninstall:
	-~/.local/bin/moonlet uninstall claude-code
	-~/.local/bin/moonlet uninstall codex
	rm -rf ~/Applications/Moonlet.app ~/.local/bin/moonlet

clean:
	rm -rf .build build
