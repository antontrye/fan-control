#!/usr/bin/env bash

# Script to package the fan control project into a clean tarball
# Uses git to track only the relevant files, excluding rootfs archives and the pack script itself

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_NAME="fan_control"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
OUTPUT_FILE="${PROJECT_NAME}_${TIMESTAMP}.tar.gz"

echo "Fan Control Project Packager"
echo "============================"
echo ""

# Parse command line arguments
CUSTOM_OUTPUT=""
while [[ $# -gt 0 ]]; do
    case $1 in
        -o|--output)
            CUSTOM_OUTPUT="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  -o, --output NAME    Custom output filename (default: ${PROJECT_NAME}_TIMESTAMP.tar.gz)"
            echo "  -h, --help          Show this help message"
            echo ""
            echo "Creates a clean tarball of the project, excluding:"
            echo "  - This pack.sh script"
            echo "  - Alpine rootfs archives (*.tar.gz)"
            echo "  - Temporary files"
            echo "  - Git repository metadata"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use -h or --help for usage information"
            exit 1
            ;;
    esac
done

# Use custom output name if provided
if [ -n "$CUSTOM_OUTPUT" ]; then
    OUTPUT_FILE="$CUSTOM_OUTPUT"
    # Add .tar.gz extension if not present
    if [[ ! "$OUTPUT_FILE" =~ \.tar\.gz$ ]]; then
        OUTPUT_FILE="${OUTPUT_FILE}.tar.gz"
    fi
fi

cd "$SCRIPT_DIR"

# Check if git repo exists, if not initialize it
if [ ! -d .git ]; then
    echo "Initializing git repository..."
    git init
    
    # Create a comprehensive .gitignore
    cat > .gitignore << 'EOF'
# Pack script itself
pack.sh

# Alpine rootfs archives
alpine-minirootfs-*.tar.gz
*.tar.gz

# Extracted directories
alpine-minirootfs-*/
rootfs/
minirootfs/

# Temporary files
*.tmp
*.swp
*.bak
*~
.DS_Store

# Environment files with secrets
.env

# IDE directories
.vscode/
.idea/

# Log files
*.log

# Temporary ipmi config files
/tmp/ipmi.conf.*
EOF
    
    echo "Created .gitignore file"
fi

# Add all files to git (respecting .gitignore)
echo "Adding files to git index..."
git add .

# Check if there are any files to commit
if git diff --cached --quiet 2>/dev/null; then
    echo "No new changes to stage"
else
    # Commit the files (needed for git archive to work)
    git commit -m "Packaging snapshot at $TIMESTAMP" --quiet || true
fi

# Ensure pack.sh is not in the archive even if it was committed before
echo "Creating archive: $OUTPUT_FILE"

# Get list of files from git, excluding pack.sh
git ls-files | grep -v '^pack\.sh$' > /tmp/pack_files_$$.txt

# Create the tarball using the file list
tar -czf "$OUTPUT_FILE" -T /tmp/pack_files_$$.txt 2>/dev/null

# Clean up temp file
rm -f /tmp/pack_files_$$.txt

# Calculate archive size
SIZE=$(ls -lh "$OUTPUT_FILE" | awk '{print $5}')

echo ""
echo "✓ Archive created successfully!"
echo ""
echo "Details:"
echo "  Output file: $OUTPUT_FILE"
echo "  Size: $SIZE"
echo "  Files included: $(git ls-files | grep -v '^pack\.sh$' | wc -l)"
echo ""

# List contents summary
echo "Archive contents:"
git ls-files | grep -v '^pack\.sh$' | head -20
TOTAL_FILES=$(git ls-files | grep -v '^pack\.sh$' | wc -l)
if [ $TOTAL_FILES -gt 20 ]; then
    echo "  ... and $((TOTAL_FILES - 20)) more files"
fi

echo ""
echo "To extract: tar -xzf $OUTPUT_FILE"