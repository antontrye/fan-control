#!/usr/bin/env bash

# Script to package the fan control project into a clean tarball
# Creates archive from git-tracked files, excluding pack.sh itself

set -euo pipefail

PROJECT_NAME="fan-control"

# Determine version from git
if git describe --tags --exact-match HEAD 2>/dev/null; then
    # We're on a tag - use tag name
    VERSION=$(git describe --tags --exact-match HEAD)
else
    # Use short commit hash
    VERSION=$(git rev-parse --short HEAD)
fi

OUTPUT_FILE="${PROJECT_NAME}-${VERSION}.tar.gz"

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -o|--output)
            OUTPUT_FILE="$2"
            # Add .tar.gz extension if not present
            [[ ! "$OUTPUT_FILE" =~ \.tar\.gz$ ]] && OUTPUT_FILE="${OUTPUT_FILE}.tar.gz"
            shift 2
            ;;
        -h|--help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  -o, --output NAME    Custom output filename (default: ${PROJECT_NAME}-{VERSION}.tar.gz)"
            echo "  -h, --help          Show this help message"
            echo ""
            echo "Creates tarball from git-tracked files, excluding pack.sh"
            echo "Version is determined from git tags or commit hash"
            echo "Default output: ${OUTPUT_FILE}"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

echo "Creating archive: $OUTPUT_FILE"

# Get list of files from git, excluding pack.sh
git ls-files | grep -v '^pack\.sh$' > /tmp/pack_files_$$.txt

# Create the tarball using the file list
tar -czf "$OUTPUT_FILE" -T /tmp/pack_files_$$.txt

# Clean up temp file
rm -f /tmp/pack_files_$$.txt

# Show results
SIZE=$(ls -lh "$OUTPUT_FILE" | awk '{print $5}')
FILE_COUNT=$(git ls-files | grep -v '^pack\.sh$' | wc -l)

echo "✓ Archive created: $OUTPUT_FILE (${SIZE}, ${FILE_COUNT} files)"