#!/bin/zsh
#
# NCS Australia - Zscaler & Development Environment Setup Script
#
# Author: Emile Hofsink
# Version: 2.6.0
#
# This script automates the configuration of a development environment
# to work seamlessly behind the NCS Zscaler proxy. It automatically
# discovers and fetches the required Zscaler CA certificates.
#
# It performs the following actions:
# 1.  Checks for and downloads the latest version of itself.
# 2.  Checks for dependencies (gum, gcloud, openssl, etc.) and offers to install them.
# 3.  Auto-discovers the Zscaler certificate chain, with retries for reliability.
# 4.  Validates that the fetched certificate is issued by Zscaler and contains no garbage characters.
# 5.  Creates a 'golden bundle' by combining the system certs and the discovered Zscaler chain.
# 6.  Detects the user's shell (bash, zsh, fish) and uses the correct syntax.
# 7.  Idempotently adds the configuration to the user's shell profile to prevent duplicates.
# 8.  Provides an '--out-file' option to write env vars to a separate, sourceable file for modularity.
#
# Usage:
#   ./zscaler.sh
#   ./zscaler.sh --out-file ~/.config/zscaler.env
#
# One-liner:
#   curl -sSL "https://raw.githubusercontent.com/withriley/engineer-enablement/main/tools/zscaler.sh?_=$(date +%s)" -o /tmp/zscaler.sh && zsh /tmp/zscaler.sh
#

# --- Self-Update Mechanism ---
# This ensures the user is always running the latest version of the script.
SCRIPT_URL="https://raw.githubusercontent.com/withriley/engineer-enablement/main/tools/zscaler.sh"
CURRENT_VERSION="2.6.0" # This must match the version in this header

self_update() {
    # Use plain echo since gum may not be installed yet.
    echo "Checking for script updates..."
    
    local ca_bundle="$HOME/certs/ncs_golden_bundle.pem"
    local curl_opts=("-sSL")

    if [ -f "$ca_bundle" ]; then
        curl_opts+=("--cacert" "$ca_bundle")
    fi

    LATEST_VERSION=$(curl "${curl_opts[@]}" "${SCRIPT_URL}?_=$(date +%s)" | grep -m 1 "Version:" | awk '{print $3}')

    if [ -z "$LATEST_VERSION" ]; then
        echo "Warning: Could not check for script updates. Proceeding with the current version."
        return
    fi

    if [ "$LATEST_VERSION" != "$CURRENT_VERSION" ]; then
        echo "A new version ($LATEST_VERSION) is available. The script will now update and re-launch."
        
        local script_path="$0"
        if [ -z "$script_path" ] || [[ ! -f "$script_path" ]]; then
            echo "Error: Cannot self-update when run from a pipe. Please use the recommended one-liner."
            exit 1
        fi

        if curl "${curl_opts[@]}" "${SCRIPT_URL}?_=$(date +%s)" -o "$script_path.tmp"; then
            mv "$script_path.tmp" "$script_path"
            chmod +x "$script_path"
            echo "Update complete. Re-executing the script..."
            exec "$script_path" "$@"
        else
            echo "Error: Script update failed. Please try again later."
            exit 1
        fi
    fi
}

# --- Global Helper function for styled error messages ---
print_error() {
    if command -v gum &> /dev/null; then
        gum style --foreground 9 "✖ Error: $1"
    else
        echo "✖ Error: $1"
    fi
}

# --- 1. Dependency Check & Installation ---
check_dependencies() {
    if ! command -v gum &> /dev/null; then
        echo "--- Dependency Check ---"
        echo "This script uses 'gum' for a better user experience, but it's not installed."
        printf "Would you like to attempt to install it via Homebrew (macOS) or Go? [y/N] "
        read -r response < /dev/tty
        if [[ "$response" =~ ^([yY][eE][sS]|[yY])$ ]]; then
            if command -v brew &> /dev/null; then
                echo "--> Found Homebrew. Attempting to install 'gum'..."
                brew install gum
            elif command -v go &> /dev/null; then
                echo "--> Found Go. Attempting to install 'gum'..."
                go install github.com/charmbracelet/gum@latest
            else
                print_error "Could not find Homebrew or Go. Please install 'gum' manually."
                echo "   Visit: https://github.com/charmbracelet/gum"
                exit 1
            fi
            
            if ! command -v gum &> /dev/null; t
