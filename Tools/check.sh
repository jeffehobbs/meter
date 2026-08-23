#!/bin/zsh
# Compile the engine (everything that is not the interface) together with the
# check harness and run it. Kept out of the app target on purpose: this is a
# command-line program, and the point of it is to exercise the composition and
# the rack without a window in the way.
set -e
cd "$(dirname "$0")/.."
mkdir -p build
swiftc -O -o build/check \
  Sources/Shared/Support/*.swift Sources/Shared/Model/*.swift \
  Sources/Shared/Composition/*.swift \
  Sources/Shared/Audio/DrumSynth.swift Sources/Shared/Audio/AudioOutput.swift \
  Tools/main.swift \
  -framework AVFoundation
./build/check
