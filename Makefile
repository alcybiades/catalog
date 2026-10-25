# Link with the current SDK when full Xcode is installed, even if xcode-select
# still points at older Command Line Tools. AppKit gates Tahoe styling on this.
ifneq ($(wildcard /Applications/Xcode.app/Contents/Developer),)
export DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer
endif

APP    := Write
SOURCES := $(shell find Sources/Write -name '*.swift')
BUNDLE := dist/$(APP).app
BIN    := .build/release/$(APP)

.PHONY: build app run install clean test benchmark-gallery

test:
	@mkdir -p .build/tests
	@xcrun swiftc -D WRITE_TESTING -o .build/tests/behavior \
		Sources/Write/AppState.swift \
		Sources/Write/Theme.swift \
		Sources/Write/Workspace.swift \
		Sources/Write/ReferencePicker.swift \
		Sources/Write/MarkdownHighlighter.swift \
		Sources/Write/ImageLoader.swift \
		Sources/Write/EditorTextView.swift \
		Support/BehaviorTests/main.swift
	@.build/tests/behavior
	@xcrun swiftc -D WRITE_TESTING -o .build/tests/workspace $(filter-out Sources/Write/main.swift,$(SOURCES)) Support/WorkspaceTests/main.swift
	@.build/tests/workspace
	@xcrun swiftc -o .build/tests/images Sources/Write/ImageLoader.swift Support/ImageTests/main.swift
	@.build/tests/images

benchmark-gallery:
	@mkdir -p .build/tests
	@xcrun swiftc -D WRITE_TESTING -O -whole-module-optimization -o .build/tests/gallery-benchmark $(filter-out Sources/Write/main.swift,$(SOURCES)) Support/GalleryBenchmark/main.swift
	@.build/tests/gallery-benchmark "$(GALLERY)"

build:
	xcrun swift build -c release

app: build
	rm -rf $(BUNDLE)
	mkdir -p $(BUNDLE)/Contents/MacOS $(BUNDLE)/Contents/Resources
	cp $(BIN) $(BUNDLE)/Contents/MacOS/$(APP)
	cp Support/Info.plist $(BUNDLE)/Contents/Info.plist
	cp Support/AppIcon.icns $(BUNDLE)/Contents/Resources/AppIcon.icns
	codesign --force --sign - $(BUNDLE)

run: app
	open $(BUNDLE)

install: app
	rm -rf /Applications/$(APP).app
	cp -R $(BUNDLE) /Applications/

clean:
	rm -rf .build dist
