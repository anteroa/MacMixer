.PHONY: app run install zip clean

app:
	./scripts/build-app.sh

run: app
	-pkill -x MacMixer
	open build/MacMixer.app

install: app
	-pkill -x MacMixer
	rm -rf /Applications/MacMixer.app
	cp -R build/MacMixer.app /Applications/
	open /Applications/MacMixer.app

zip: app
	ditto -c -k --keepParent build/MacMixer.app build/MacMixer.zip

clean:
	rm -rf .build build
