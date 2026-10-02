.PHONY: run-mobile

# Example:
#   make run-mobile
#   make run-mobile ARGS="-d emulator-5554"
run-mobile:
	flutter run --no-enable-dart-profiling --dart-define=flutter.flutter_map.unblockOSM=Our tile servers are not. $(ARGS)
