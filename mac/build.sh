#!/bin/zsh
# Builds PenRelay (needs Xcode command line tools).
cd "${0:A:h}" && swiftc -O penrelay.swift -o penrelay && echo "built mac/penrelay"
