#!/bin/bash -e

echo "Running system configuration..."

# Automatically execute all numbered scripts in the directory (excluding this script)
# This will run scripts like 01-*.sh, 02-*.sh, etc. in numerical order
for script in $(find "${STAGE_DIR}" -name "[0-9][0-9]-*.sh" -not -name "00-run.sh" | sort); do
    script_name=$(basename "$script")
    echo "Executing ${script_name}..."
    bash "$script"
done

echo "System configuration complete."
