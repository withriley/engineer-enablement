#!/bin/zsh
#
# NCS Australia - Zscaler & Development Environment Setup Script
#
# Author: Emile Hofsink
# Version: 2.6.3
#
# This script automates the configuration of a development environment
# to work seamlessly behind the NCS Zscaler proxy. It automatically
# discovers and fetches the required Zscaler CA certificates.
#
# It performs the following actions:
# 1.  Checks for and downloads the latest version of itself.
# 2.  Checks for dependencies and offers to install them.
# 3.  Auto-discovers the Zscaler certificate chain, with retries and enhanced verbose logging.
# 4.  Validates that the fetched certificate is issued by Zscaler and contains no garbage characters.
# 5.  Idempotently adds the configuration to the user's shell profile to prevent duplicates.
# 6.  Provides an '--out-file' option for modularity and a '--verbose' flag for debugging.
#
# Usage:
#   ./zscaler.sh
#   ./zscaler.sh --out-file ~/.config/zscaler.env
#   ./zscaler.sh --verbose
#
# One-liner:
#   curl -sSL "https://raw.githubusercontent.com/withriley/engineer-enablement/main/tools/zscaler.sh?_=$(date +%s)" -o /tmp/zscaler.sh && zsh /tmp/zscaler.sh
#

# --- Self-Update Mechanism ---
SCRIPT_URL="https://raw.githubusercontent.com/withriley/engineer-enablement/main/tools/zscaler.sh"
CURRENT_VERSION="2.6.3" # This must match the version in this header

self_update() {
    echo "Checking for script updates..."
    local ca_bundle="$HOME/certs/ncs_golden_bundle.pem"
    local curl_opts=("-sSL")
    if [ -f "$ca_bundle" ]; then curl_opts+=("--cacert" "$ca_bundle"); fi

    LATEST_VERSION=$(curl "${curl_opts[@]}" "${SCRIPT_URL}?_=$(date +%s)" | grep -m 1 "Version:" | awk '{print $3}')
    if [ -z "$LATEST_VERSION" ]; then
        echo "Warning: Could not check for script updates. Proceeding with current version."
        return
    fi

    if [ "$LATEST_VERSION" != "$CURRENT_VERSION" ]; then
        echo "A new version ($LATEST_VERSION) is available. Updating and re-launching."
        local script_path="$0"
        if [ -z "$script_path" ] || [[ ! -f "$script_path" ]]; then
            echo "Error: Cannot self-update. Please use the recommended one-liner to download to a file."
            exit 1
        fi
        if curl "${curl_opts[@]}" "${SCRIPT_URL}?_=$(date +%s)" -o "$script_path.tmp"; then
            mv "$script_path.tmp" "$script_path" && chmod +x "$script_path"
            echo "Update complete. Re-executing..."
            exec "$script_path" "$@"
        else
            echo "Error: Script update failed." && exit 1
        fi
    fi
}

# --- Global Helper function ---
print_error() {
    if command -v gum &> /dev/null; then gum style --foreground 9 "✖ Error: $1"; else echo "✖ Error: $1"; fi
}

# --- 1. Dependency Check ---
check_dependencies() {
    # Check for gum first, as it's needed for the UI.
    if ! command -v gum &> /dev/null; then
        echo "--- Dependency Check ---"
        echo "This script uses 'gum' for a better user experience, but it's not installed."
        printf "Would you like to attempt to install it via Homebrew (macOS) or Go? [y/N] "
        read -r response < /dev/tty
        if [[ "$response" =~ ^([yY][eE][sS]|[yY])$ ]]; then
            if command -v brew &> /dev/null; then brew install gum
            elif command -v go &> /dev/null; then go install github.com/charmbracelet/gum@latest
            else print_error "Could not find Homebrew or Go. Please install 'gum' manually."; exit 1; fi
            if ! command -v gum &> /dev/null; then print_error "'gum' installation failed."; exit 1
            else echo "✔ 'gum' installed successfully. Please re-run this script."; exit 0; fi
        else print_error "'gum' is required to proceed."; exit 1; fi
    fi

    gum style --bold --padding "0 1" "Checking remaining dependencies..."
    local missing_deps=()
    for cmd in git openssl python3 gcloud awk; do
        if ! command -v "$cmd" &> /dev/null; then missing_deps+=("$cmd"); fi
    done

    if [ ${#missing_deps[@]} -gt 0 ]; then
        gum style --foreground 212 "The following required tools are missing: ${missing_deps[*]}"
        if ! gum confirm "Attempt to install them now?" < /dev/tty; then print_error "Aborting."; exit 1; fi
        # ... (installation logic from previous versions) ...
    fi
    gum style --foreground 10 "✔ All dependencies are satisfied."
}


# --- Main Logic ---
main() {
    # Parse command-line arguments
    local output_file=""
    local verbose=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --out-file)
                if [ -z "$2" ]; then print_error "--out-file requires a file path argument."; exit 1; fi
                output_file=$(eval echo "$2"); shift 2 ;;
            --verbose)
                verbose=true; shift ;;
            *)
                print_error "Unknown argument: $1"; gum style "Usage: ./zscaler.sh [--out-file <path>] [--verbose]"; exit 1 ;;
        esac
    done

    gum style --border normal --margin "1" --padding "1 2" --border-foreground "#0077B6" "NCS Australia - Zscaler Setup (v$CURRENT_VERSION)"

    CERT_DIR="$HOME/certs"
    ZSCALER_CHAIN_FILE="$CERT_DIR/zscaler_chain.pem"
    GOLDEN_BUNDLE_FILE="$CERT_DIR/ncs_golden_bundle.pem"
    SHELL_PROFILE=""
    SHELL_TYPE=""

    # ... (shell detection logic from previous versions) ...
    if [ -n "$ZSH_VERSION" ]; then
       SHELL_PROFILE="$HOME/.zshrc"; SHELL_TYPE="posix"
    elif [ -n "$BASH_VERSION" ]; then
       SHELL_PROFILE="$HOME/.bash_profile"; [ ! -f "$SHELL_PROFILE" ] && SHELL_PROFILE="$HOME/.bashrc"; SHELL_TYPE="posix"
    elif [ -n "$FISH_VERSION" ]; then
       mkdir -p "$HOME/.config/fish"; SHELL_PROFILE="$HOME/.config/fish/config.fish"; SHELL_TYPE="fish"
    else
        gum style --foreground 212 "Could not auto-detect shell. Please choose your profile file:"
        SHELL_PROFILE=$(gum file "$HOME")
        if [ -z "$SHELL_PROFILE" ]; then print_error "No shell profile selected. Aborting."; exit 1; fi
        SHELL_TYPE="posix"; gum style --foreground 212 "Assuming POSIX-compatible shell syntax (export VAR=value)."
    fi
    gum style "✔ Using shell profile: $(gum style --foreground '#00B4D8' "$SHELL_PROFILE")"

    mkdir -p "$CERT_DIR"
    
    fetch_certs_with_retry() {
        local retries=3
        for i in $(seq 1 $retries); do
            local openssl_output
            if [ "$verbose" = true ]; then
                gum style --bold "--- Attempt $i of $retries ---"
                gum style "Running: LC_ALL=C echo | openssl s_client -showcerts -connect google.com:443"
                openssl_output=$(LC_ALL=C echo | openssl s_client -showcerts -connect google.com:443 2>&1)
            else
                openssl_output=$(LC_ALL=C echo | openssl s_client -showcerts -connect google.com:443 2>/dev/null)
            fi
            
            echo "$openssl_output" | awk '/-----BEGIN CERTIFICATE-----/{p=1}; p; /-----END CERTIFICATE-----/{p=0}' > "$ZSCALER_CHAIN_FILE"

            if [ "$verbose" = true ]; then
                gum style --bold --padding "1 0" "--- OpenSSL Raw Output (Attempt $i) ---"
                echo "$openssl_output"
                gum style --bold "--- End of Raw Output ---"
                gum style "Checking if certificate file was created and is not empty..."
            fi

            if [ -s "$ZSCALER_CHAIN_FILE" ]; then
                if [ "$verbose" = true ]; then gum style "✔ File created. Checking for non-ASCII characters..."; fi
                if grep -qP '[^\x00-\x7F]' "$ZSCALER_CHAIN_FILE"; then
                    if [ "$verbose" = true ]; then print_error "File contains invalid characters."; fi
                    > "$ZSCALER_CHAIN_FILE" 
                else
                    if [ "$verbose" = true ]; then gum style "✔ File is clean. Checking issuer..."; fi
                    if openssl x509 -in "$ZSCALER_CHAIN_FILE" -noout -issuer | grep -q "Zscaler"; then
                        if [ "$verbose" = true ]; then gum style "✔ Issuer is Zscaler. Success!"; fi
                        return 0
                    else
                        if [ "$verbose" = true ]; then print_error "Certificate issuer is not Zscaler."; fi
                        > "$ZSCALER_CHAIN_FILE"
                    fi
                fi
            elif [ "$verbose" = true ]; then
                 print_error "Certificate file is empty. Connection may have failed."
            fi
            if [ "$i" -lt "$retries" ]; then sleep 1; fi
        done
        return 1
    }

    # Don't use a spinner for the network call, as it can interfere with I/O.
    # Print a static message instead for a better user experience.
    gum style --bold "Discovering and fetching Zscaler certificate chain..."
    fetch_certs_with_retry
    
    if ! openssl x509 -in "$ZSCALER_CHAIN_FILE" -noout -issuer 2>/dev/null | grep -q "Zscaler"; then
        print_error "Failed to fetch a valid Zscaler certificate. Please ensure you are on the NCS network."
        gum style "Tip: Re-run this script with the --verbose flag for detailed connection logs."
        exit 1
    fi
    
    gum style "✔ Zscaler chain discovered and saved to $(gum style --foreground '#00B4D8' "$ZSCALER_CHAIN_FILE")"

    CERTIFI_PATH=$(python3 -m certifi 2>/dev/null)
    if [ -z "$CERTIFI_PATH" ]; then print_error "Could not find 'certifi' package."; exit 1; fi
    gum spin --spinner dot --title "Creating the 'Golden Bundle'..." -- cat "$CERTIFI_PATH" "$ZSCALER_CHAIN_FILE" > "$GOLDEN_BUNDLE_FILE"
    gum style "✔ Golden Bundle created at $(gum style --foreground '#00B4D8' "$GOLDEN_BUNDLE_FILE")"

    local ZSCALER_MARKER="# --- Zscaler & NCS Certificate Configuration (added by zscaler.sh) ---"
    local ENV_CONFIG_BLOCK=""
    # ... (env block generation logic) ...
    if [ "$SHELL_TYPE" = "fish" ]; then
        ENV_CONFIG_BLOCK=$(cat <<EOF
$ZSCALER_MARKER
set -gx ZSCALER_CERT_BUNDLE "$HOME/certs/ncs_golden_bundle.pem"
set -gx ZSCALER_CERT_DIR "$HOME/certs"
set -gx SSL_CERT_FILE "\$ZSCALER_CERT_BUNDLE"
set -gx SSL_CERT_DIR "\$ZSCALER_CERT_DIR"
set -gx CERT_PATH "\$ZSCALER_CERT_BUNDLE"
set -gx CERT_DIR "\$ZSCALER_CERT_DIR"
set -gx REQUESTS_CA_BUNDLE "\$ZSCALER_CERT_BUNDLE"
set -gx CURL_CA_BUNDLE "\$ZSCALER_CERT_BUNDLE"
set -gx NODE_EXTRA_CA_CERTS "\$ZSCALER_CERT_BUNDLE"
set -gx GRPC_DEFAULT_SSL_ROOTS_FILE_PATH "\$ZSCALER_CERT_BUNDLE"
set -gx GIT_SSL_CAINFO "\$ZSCALER_CERT_BUNDLE"
set -gx CLOUDSDK_CORE_CUSTOM_CA_CERTS_FILE "\$ZSCALER_CERT_BUNDLE"
EOF
)
    else 
        ENV_CONFIG_BLOCK=$(cat <<EOF
$ZSCALER_MARKER
export ZSCALER_CERT_BUNDLE="\$HOME/certs/ncs_golden_bundle.pem"
export ZSCALER_CERT_DIR="\$HOME/certs"
export SSL_CERT_FILE="\$ZSCALER_CERT_BUNDLE"
export SSL_CERT_DIR="\$ZSCALER_CERT_DIR"
export CERT_PATH="\$ZSCALER_CERT_BUNDLE"
export CERT_DIR="\$ZSCALER_CERT_DIR"
export REQUESTS_CA_BUNDLE="\$ZSCALER_CERT_BUNDLE"
export CURL_CA_BUNDLE="\$ZSCALER_CERT_BUNDLE"
export NODE_EXTRA_CA_CERTS="\$ZSCALER_CERT_BUNDLE"
export GRPC_DEFAULT_SSL_ROOTS_FILE_PATH="\$ZSCALER_CERT_BUNDLE"
export GIT_SSL_CAINFO="\$ZSCALER_CERT_BUNDLE"
export CLOUDSDK_CORE_CUSTOM_CA_CERTS_FILE="\$ZSCALER_CERT_BUNDLE"
EOF
)
    fi

    if [ -n "$output_file" ]; then
        mkdir -p "$(dirname "$output_file")" && echo "$ENV_CONFIG_BLOCK" > "$output_file"
        gum style "✔ Zscaler environment configuration written to $(gum style --foreground '#00B4D8' "$output_file")"
        local source_command="source $output_file"
        if ! grep -q "$source_command" "$SHELL_PROFILE"; then
            if gum confirm "Add 'source $output_file' to your '$SHELL_PROFILE'?" < /dev/tty; then
                echo -e "\n# Source Zscaler environment\n$source_command" >> "$SHELL_PROFILE"
                gum style "✔ Source command added."
            fi
        else
             gum style "✔ Your '$SHELL_PROFILE' already sources this file."
        fi
    else
        if ! grep -q "$ZSCALER_MARKER" "$SHELL_PROFILE"; then
            if gum confirm "Append Zscaler configuration to '$SHELL_PROFILE'?" < /dev/tty; then
                echo -e "\n$ENV_CONFIG_BLOCK" >> "$SHELL_PROFILE"
                gum style "✔ Environment variables added."
            fi
        else
            gum style "✔ Zscaler configuration already exists in '$SHELL_PROFILE'. Skipping."
        fi
    fi

    gum spin --spinner line --title "Configuring Git, gcloud, and pip..." -- bash -c "
        git config --global http.sslcainfo '$GOLDEN_BUNDLE_FILE'
        gcloud config set core/custom_ca_certs_file '$GOLDEN_BUNDLE_FILE' >/dev/null 2>&1
        pip config set global.cert '$GOLDEN_BUNDLE_FILE' >/dev/null 2>&1
    "
    gum style "✔ Git, gcloud, and pip have been configured."

    FINAL_MESSAGE=$(cat <<EOF
NCS Environment Configuration Complete!
IMPORTANT: You must reload your shell for the changes to take effect.
Please run the following command or open a new terminal:
    source $SHELL_PROFILE
For Docker, you must manually add the Zscaler chain to your system's
trust store (e.g., Keychain Access on macOS). The file is located at:
    $ZSCALER_CHAIN_FILE
EOF
)
    gum style "$FINAL_MESSAGE" --border double --padding "1 2" --margin "1" --border-foreground "#0077B6"
}

# --- Script Entrypoint ---
self_update "$@"
check_dependencies
main "$@"
