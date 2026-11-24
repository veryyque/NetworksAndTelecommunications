#!/bin/sh
set -eu

project=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
schema=${1:-"$project/Protocol/snakes.proto"}
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
cp "$schema" "$scratch/snakes.proto"

if ! command -v protoc-gen-swift >/dev/null; then
    git clone -q --depth 1 --branch 1.30.0 https://github.com/apple/swift-protobuf.git "$scratch/generator"
    swift build --package-path "$scratch/generator" -c release --product protoc-gen-swift
    PATH="$(swift build --package-path "$scratch/generator" -c release --show-bin-path):$PATH"
    export PATH
fi

protoc -I "$scratch" --swift_out="$scratch" --swift_opt=Visibility=Public "$scratch/snakes.proto"
cp "$scratch/snakes.proto" "$project/Protocol/snakes.proto"
cp "$scratch/snakes.pb.swift" "$project/Protocol/Sources/SnakesWire/"
