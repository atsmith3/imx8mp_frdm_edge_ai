#!/bin/bash
set -e

if [ $# -lt 1 ]; then
    echo "Usage: $0 <chunks_directory> [output_file]"
    echo "Example: $0 imx-image-full-imx8mp-lpddr4-frdm.rootfs-20260411135245.chunks"
    exit 1
fi

CHUNKS_DIR="$1"
OUTPUT_FILE="${2:-}"

if [ ! -d "$CHUNKS_DIR" ]; then
    echo "Error: Directory '$CHUNKS_DIR' not found"
    exit 1
fi

if [ ! -f "$CHUNKS_DIR/original.md5" ]; then
    echo "Error: original.md5 not found in $CHUNKS_DIR"
    echo "Make sure this directory was created by split.sh"
    exit 1
fi

# Derive output filename from directory name if not provided
if [ -z "$OUTPUT_FILE" ]; then
    OUTPUT_FILE="${CHUNKS_DIR%.chunks}.tar.gz"
fi

echo "Combining chunks from: $CHUNKS_DIR"
echo "Output file: $OUTPUT_FILE"

# Check if output file already exists
if [ -f "$OUTPUT_FILE" ]; then
    echo "Warning: $OUTPUT_FILE already exists. Overwriting..."
    rm "$OUTPUT_FILE"
fi

echo "Concatenating chunks..."
cat "$CHUNKS_DIR"/chunk_* > "$OUTPUT_FILE"

echo "Verifying integrity..."
ORIGINAL_MD5=$(cat "$CHUNKS_DIR/original.md5" | awk '{print $1}')
COMPUTED_MD5=$(md5sum "$OUTPUT_FILE" | awk '{print $1}')

if [ "$ORIGINAL_MD5" = "$COMPUTED_MD5" ]; then
    echo "✓ Checksum verified! File is intact."
    echo "Original: $ORIGINAL_MD5"
    ls -lh "$OUTPUT_FILE"
else
    echo "✗ Checksum mismatch!"
    echo "Expected: $ORIGINAL_MD5"
    echo "Got:      $COMPUTED_MD5"
    rm "$OUTPUT_FILE"
    exit 1
fi
