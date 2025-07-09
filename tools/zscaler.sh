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
            
            if ! command -v gum &> /dev/null; then
                print_error "'gum' installation failed. Please check the output above."
                exit 1
            else
                echo "✔ 'gum' installed successfully. Please re-run this script to continue."
                exit 0
            fi
        else
            print_error "'gum' is required to proceed. Please install it and re-run the script."
            exit 1
        fi
    fi

    gum style --bold --padding "0 1" "Checking remaining dependencies..."
    local missing_deps=()
    for cmd in git openssl python3 gcloud; do
        if ! command -v "$cmd" &> /dev/null; then
            missing_deps+=("$cmd")
        fi
    done

    if [ ${#missing_deps[@]} -gt 0 ]; then
        gum style --foreground 212 "The following required tools are missing: ${missing_deps[*]}"
        if ! gum confirm "Attempt to install them now?" < /dev/tty; then
            print_error "Aborting. Please install the missing dependencies and re-run."
            exit 1
        fi

        local deps_installed=false
        for dep in "${missing_deps[@]}"; do
            gum style "--- Installing '$dep' ---"
            case "$dep" in
                gcloud)
                    gum style "The Google Cloud SDK requires manual installation steps." \
                        "Please follow the official guide:" \
                        "https://cloud.google.com/sdk/docs/install"
                    gum style "After installation, please re-run this script."
                    exit 0
                    ;;
                *)
                    if command -v brew &> /dev/null; then
                        brew install "$dep"
                        deps_installed=true
                    elif command -v apt-get &> /dev/null; then
                        sudo apt-get update && sudo apt-get install -y "$dep"
                        [ "$dep" = "python3" ] && sudo apt-get install -y python3-pip
                        deps_installed=true
                    else
                        print_error "Could not find a known package manager (brew, apt-get). Please install '$dep' manually."
                        exit 1
                    fi
                    ;;
            esac
        done

        if [ "$deps_installed" = true ]; then
            gum style --foreground 10 "✔ Dependencies installed. Please re-run this script to continue."
            exit 0
        fi
    fi
    if ! command -v pip &> /dev/null && ! command -v pip3 &> /dev/null; then
        print_error "'pip' is not installed. Please ensure your Python installation includes pip."
        exit 1
    fi
    gum style --foreground 10 "✔ All dependencies are satisfied."
}


# --- Main Logic ---
main() {
    # Parse command-line arguments
    local output_file=""
    if [[ "$1" == "--out-file" ]]; then
        if [ -z "$2" ]; then
            print_error "--out-file requires a file path argument."
            exit 1
        fi
        output_file=$(eval echo "$2") # Expand tilde
    elif [ -n "$1" ]; then
        print_error "Unknown argument: $1"
        gum style "Usage: ./zscaler.sh [--out-file <path>]"
        exit 1
    fi

    gum style --border normal --margin "1" --padding "1 2" --border-foreground "#0077B6" "NCS Australia - Zscaler & Development Environment Setup"

    CERT_DIR="$HOME/certs"
    ZSCALER_CHAIN_FILE="$CERT_DIR/zscaler_chain.pem"
    GOLDEN_BUNDLE_FILE="$CERT_DIR/ncs_golden_bundle.pem"
    SHELL_PROFILE=""
    SHELL_TYPE=""

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
            LC_ALL=C echo | openssl s_client -showcerts -connect google.com:443 2>/dev/null | awk '/-----BEGIN CERTIFICATE-----/{p=1}; p; /-----END CERTIFICATE-----/{p=0}' > "$ZSCALER_CHAIN_FILE"
            if [ -s "$ZSCALER_CHAIN_FILE" ]; then
                if grep -qP '[^\x00-\x7F]' "$ZSCALER_CHAIN_FILE"; then > "$ZSCALER_CHAIN_FILE"; 
                elif openssl x509 -in "$ZSCALER_CHAIN_FILE" -noout -issuer | grep -q "Zscaler"; then return 0;
                else > "$ZSCALER_CHAIN_FILE"; fi
            fi
            if [ "$i" -lt "$retries" ]; then sleep 1; fi
        done
        return 1
    }

    gum spin --spinner dot --title "Discovering and fetching Zscaler certificate chain..." -- bash -c "$(declare -f fetch_certs_with_retry); fetch_certs_with_retry"
    
    if ! openssl x509 -in "$ZSCALER_CHAIN_FILE" -noout -issuer 2>/dev/null | grep -q "Zscaler"; then
        print_error "Failed to fetch a valid Zscaler certificate. Please ensure you are on the NCS network."
        exit 1
    fi
    
    gum style "✔ Zscaler chain discovered and saved to $(gum style --foreground '#00B4D8' "$ZSCALER_CHAIN_FILE")"

    CERTIFI_PATH=$(python3 -m certifi 2>/dev/null)
    if [ -z "$CERTIFI_PATH" ]; then
        print_error "Could not find 'certifi' package. Please ensure it is installed (`pip install --upgrade certifi`)."
        exit 1
    fi

    gum spin --spinner dot --title "Creating the 'Golden Bundle'..." -- cat "$CERTIFI_PATH" "$ZSCALER_CHAIN_FILE" > "$GOLDEN_BUNDLE_FILE"
    gum style "✔ Golden Bundle created at $(gum style --foreground '#00B4D8' "$GOLDEN_BUNDLE_FILE")"

    local ZSCALER_MARKER="# --- Zscaler & NCS Certificate Configuration (added by zscaler.sh) ---"
    
    # Generate the configuration block based on shell type
    local ENV_CONFIG_BLOCK=""
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

    # Decide where to write the configuration
    if [ -n "$output_file" ]; then
        mkdir -p "$(dirname "$output_file")"
        echo "$ENV_CONFIG_BLOCK" > "$output_file"
        gum style "✔ Zscaler environment configuration written to $(gum style --foreground '#00B4D8' "$output_file")"
        
        local source_command="source $output_file"
        if ! grep -q "$source_command" "$SHELL_PROFILE"; then
            if gum confirm "Add 'source $output_file' to your '$SHELL_PROFILE'?" < /dev/tty; then
                echo -e "\n# Source Zscaler environment\n$source_command" >> "$SHELL_PROFILE"
                gum style "✔ Source command added to '$SHELL_PROFILE'."
            fi
        else
             gum style "✔ Your '$SHELL_PROFILE' already sources this file. No changes needed."
        fi
    else
        if ! grep -q "$ZSCALER_MARKER" "$SHELL_PROFILE"; then
            if gum confirm "Append Zscaler configuration to '$SHELL_PROFILE'?" < /dev/tty; then
                gum style "$ENV_CONFIG_BLOCK" --padding "1 2" --border rounded --border-foreground "#90E0EF"
                cp "$SHELL_PROFILE" "${SHELL_PROFILE}.bak.$(date +%F-%T)"
                touch "$SHELL_PROFILE"
                echo -e "\n$ENV_CONFIG_BLOCK" >> "$SHELL_PROFILE"
                gum style "✔ Environment variables added to your shell profile."
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
