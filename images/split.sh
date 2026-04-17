#!/bin/bash
set -e

if [ $# -lt 1 ]; then
    echo "Usage: $0 <tar.gz_file> [chunk_size_mb]"
    echo "Example: $0 imx-image-full-imx8mp-lpddr4-frdm.rootfs-20260411135245.tar.gz 100"
    echo "Default chunk size is 100MB"
    exit 1
fi

INPUT_FILE="$1"
CHUNK_SIZE_MB="${2:-100}"
CHUNK_SIZE=$((CHUNK_SIZE_MB * 1024 * 1024))

if [ ! -f "$INPUT_FILE" ]; then
    echo "Error: File '$INPUT_FILE' not found"
    exit 1
fi

BASENAME=$(basename "$INPUT_FILE")
OUTPUT_DIR="${INPUT_FILE%.tar.gz}.chunks"

echo "Splitting $INPUT_FILE into ${CHUNK_SIZE_MB}MB chunks..."
echo "Output directory: $OUTPUT_DIR"

mkdir -p "$OUTPUT_DIR"

split -b "$CHUNK_SIZE" "$INPUT_FILE" "$OUTPUT_DIR/chunk_"

echo "Computing checksums..."
md5sum "$INPUT_FILE" > "$OUTPUT_DIR/original.md5"
md5sum "$OUTPUT_DIR"/chunk_* > "$OUTPUT_DIR/chunks.md5"

echo "Done! Split into:"
ls -lh "$OUTPUT_DIR"/chunk_* | wc -l | xargs echo "Number of chunks:"
du -sh "$OUTPUT_DIR"

echo ""
echo "To combine chunks later, run:"
echo "  ./combine.sh $OUTPUT_DIR"
