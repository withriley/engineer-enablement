#!/bin/bash
#
# NCS Australia - Zscaler & Development Environment Setup Script
#
# Author: Emile Hofsink (Updated by Google's Gemini)
# Contributors: Benjamin Western
# Version: 3.0.0
#
# This script automates the configuration of a development environment
# to work seamlessly behind the NCS Zscaler proxy. It automatically
# discovers, validates, and installs the required Zscaler CA certificates.
#
# It can perform the following actions via flags:
# 1.  Checks for required dependencies (git, openssl, python3, gcloud).
# 2.  Auto-discovers the Zscaler certificate chain from a live connection.
# 3.  Validates the certificate issuer is 'Zscaler Inc.'.
# 4.  Creates a 'golden bundle' combining a standard CA bundle with the Zscaler chain.
# 5.  Updates shell profiles (.zshrc, .bash_profile, .bashrc, config.fish).
# 6.  Creates or updates a specified .env file.
# 7.  Configures tools like Git, gcloud, and pip to use the new certificate bundle.
#
# For usage instructions, run:
#   ./zscaler.sh --help
#

# --- 1. Initial Setup & Style Functions ---

# Using 'gum' for styled output if available, otherwise fallback to standard echo.
# This avoids making 'gum' a hard dependency.
style() {
    if command -v gum &> /dev/null; then
        gum style "$@"
    else
        # Simple fallback: print the main message without styling
        echo "$2"
    fi
}

print_error() {
    style --foreground 9 "✖ Error: $1"
}

print_success() {
    style --foreground 10 "✔ $1"
}

print_info() {
    style --bold --padding "0 1" "$1"
}

# --- 2. Core Logic Functions ---

# Detects the current Operating System
detect_os() {
    case "$(uname -s)" in
        Linux*)     OS="Linux";;
        Darwin*)    OS="macOS";;
        CYGWIN*|MINGW*|MSYS*) OS="Windows";;
        *)          OS="Unknown";;
    esac
    style "✔ Detected Operating System: $(style --foreground '#00B4D8' "$OS")"
}

# Checks for necessary command-line tools
check_dependencies() {
    print_info "Checking dependencies..."
    local missing_deps=()
    for cmd in git openssl python3 gcloud pip3; do
        if ! command -v "$cmd" &> /dev/null; then
            missing_deps+=("$cmd")
        fi
    done

    if [ ${#missing_deps[@]} -gt 0 ]; then
        style --foreground 212 "The following required tools are missing: ${missing_deps[*]}"
        echo "Please install them to continue."
        echo "Installation hints:"
        if [ "$OS" = "macOS" ]; then
            echo "  On macOS, use Homebrew: brew install git openssl python gcloud"
        elif [ "$OS" = "Linux" ]; then
            echo "  On Debian/Ubuntu, use apt: sudo apt-get install git openssl python3 python3-pip"
            echo "  For gcloud, follow the official Google Cloud SDK installation guide."
        elif [ "$OS" = "Windows" ]; then
            echo "  On Windows, ensure you are using Git Bash or WSL."
            echo "  Install Git for Windows, OpenSSL (often included with Git), Python from python.org, and the Google Cloud SDK."
        fi
        exit 1
    fi
    print_success "All dependencies are satisfied."
}

# Fetches and validates the Zscaler certificate chain
fetch_and_validate_certs() {
    local cert_dir="$1"
    local chain_file="$2"
    
    print_info "Discovering and fetching Zscaler certificate chain..."
    mkdir -p "$cert_dir"

    local retries=3
    for i in $(seq 1 $retries); do
        echo | openssl s_client -showcerts -connect google.com:443 2>/dev/null | sed -n '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/p' > "$chain_file"
        if [ -s "$chain_file" ]; then break; fi
        if [ "$i" -lt "$retries" ]; then sleep 1; fi
    done

    if [ ! -s "$chain_file" ]; then
        print_error "Failed to fetch certificates. Are you on the NCS network with Zscaler active?"
        exit 1
    fi

    print_info "Validating certificate issuer..."
    # Split the chain into individual certs in a temporary directory to validate them
    local tmp_cert_dir
    tmp_cert_dir=$(mktemp -d)
    # The '-p' flag is for BSD/macOS compatibility
    csplit -s -f "$tmp_cert_dir/cert" -b "%02d.pem" "$chain_file" '/-----BEGIN CERTIFICATE-----/' '{*}'

    local validated=false
    for cert_file in "$tmp_cert_dir"/*; do
        # Check if the file is not empty
        if [ -s "$cert_file" ]; then
            local issuer
            issuer=$(openssl x509 -noout -issuer -in "$cert_file" 2>/dev/null)
            local subject
            subject=$(openssl x509 -noout -subject -in "$cert_file" 2>/dev/null)

            # Check for the specific Zscaler issuer and intermediate CA common name
            if [[ "$issuer" == *"O = Zscaler Inc."* && "$subject" == *"CN = Zscaler Intermediate Root CA"* ]]; then
                validated=true
                break
            fi
        fi
    done

    rm -rf "$tmp_cert_dir" # Clean up temporary files

    if [ "$validated" = false ]; then
        print_error "Validation failed. Could not find a certificate issued by 'Zscaler Inc.' with the expected Common Name."
        print_error "The fetched chain may not be the correct Zscaler chain. Aborting."
        rm "$chain_file"
        exit 1
    fi

    print_success "Zscaler chain fetched and validated successfully."
}

# Creates the combined certificate bundle
build_golden_bundle() {
    local certifi_path
    certifi_path=$(python3 -m certifi 2>/dev/null)
    if [ -z "$certifi_path" ]; then
        print_error "Could not find 'certifi' package. Please run: pip3 install --upgrade certifi"
        exit 1
    fi

    print_info "Creating the 'Golden Bundle'..."
    cat "$certifi_path" "$ZSCALER_CHAIN_FILE" > "$GOLDEN_BUNDLE_FILE"
    print_success "Golden Bundle created at $GOLDEN_BUNDLE_FILE"
}

# Generates the block of environment variables
generate_env_block() {
    local shell_type="$1"
    local bundle_path="$2"

    if [ "$shell_type" = "fish" ]; then
        # Fish shell syntax
        cat <<EOF
# --- Zscaler & NCS Certificate Configuration (added by script) ---
set -gx SSL_CERT_FILE "$bundle_path"
set -gx REQUESTS_CA_BUNDLE "$bundle_path"
set -gx CURL_CA_BUNDLE "$bundle_path"
set -gx NODE_EXTRA_CA_CERTS "$bundle_path"
set -gx GRPC_DEFAULT_SSL_ROOTS_FILE_PATH "$bundle_path"
set -gx GIT_SSL_CAINFO "$bundle_path"
set -gx CLOUDSDK_CORE_CUSTOM_CA_CERTS_FILE "$bundle_path"
# --- End Zscaler Configuration ---
EOF
    elif [ "$shell_type" = "env" ]; then
        # .env file syntax (no 'export')
        cat <<EOF
# --- Zscaler & NCS Certificate Configuration (added by script) ---
SSL_CERT_FILE=$bundle_path
REQUESTS_CA_BUNDLE=$bundle_path
CURL_CA_BUNDLE=$bundle_path
NODE_EXTRA_CA_CERTS=$bundle_path
GRPC_DEFAULT_SSL_ROOTS_FILE_PATH=$bundle_path
GIT_SSL_CAINFO=$bundle_path
CLOUDSDK_CORE_CUSTOM_CA_CERTS_FILE=$bundle_path
EOF
    else
        # POSIX shell syntax (bash, zsh)
        cat <<'EOF'
# --- Zscaler & NCS Certificate Configuration (added by script) ---
export SSL_CERT_FILE="$HOME/certs/ncs_golden_bundle.pem"
export REQUESTS_CA_BUNDLE="$HOME/certs/ncs_golden_bundle.pem"
export CURL_CA_BUNDLE="$HOME/certs/ncs_golden_bundle.pem"
export NODE_EXTRA_CA_CERTS="$HOME/certs/ncs_golden_bundle.pem"
export GRPC_DEFAULT_SSL_ROOTS_FILE_PATH="$HOME/certs/ncs_golden_bundle.pem"
export GIT_SSL_CAINFO="$HOME/certs/ncs_golden_bundle.pem"
CLOUDSDK_CORE_CUSTOM_CA_CERTS_FILE="$HOME/certs/ncs_golden_bundle.pem"
# --- End Zscaler Configuration ---
EOF
    fi
}

# Updates the user's detected shell profile
update_shell_profile() {
    local shell_profile=""
    local shell_type="posix"

    if [ -n "$ZSH_VERSION" ]; then
       shell_profile="$HOME/.zshrc"
    elif [ -n "$BASH_VERSION" ]; then
       # Prefer .bash_profile for login shells, but fall back to .bashrc
       if [ -f "$HOME/.bash_profile" ]; then
         shell_profile="$HOME/.bash_profile"
       else
         shell_profile="$HOME/.bashrc"
       fi
    elif command -v fish &> /dev/null && [ -n "$FISH_VERSION" ]; then
       mkdir -p "$HOME/.config/fish"
       shell_profile="$HOME/.config/fish/config.fish"
       shell_type="fish"
    else
        print_error "Could not auto-detect shell (bash, zsh, or fish). Skipping shell profile update."
        return
    fi
    
    print_info "Configuring shell profile: $shell_profile"
    local env_block
    env_block=$(generate_env_block "$shell_type" "$GOLDEN_BUNDLE_FILE")

    # Create a backup and append the new configuration
    cp "$shell_profile" "${shell_profile}.bak.$(date +%F-%T)"
    touch "$shell_profile"
    # Remove any old block before appending the new one
    sed -i.bak '/# --- Zscaler & NCS Certificate Configuration/,/# --- End Zscaler Configuration ---/d' "$shell_profile"
    echo -e "\n$env_block" >> "$shell_profile"
    
    print_success "Shell profile updated. Please run 'source $shell_profile' or open a new terminal."
}

# Creates or updates a .env file
update_env_file() {
    local env_file_path="$1"
    print_info "Updating .env file: $env_file_path"

    if [ -z "$env_file_path" ]; then
        print_error "No path provided for --update-env-file flag."
        exit 1
    fi

    local env_block
    env_block=$(generate_env_block "env" "$GOLDEN_BUNDLE_FILE")

    # Ensure directory exists
    mkdir -p "$(dirname "$env_file_path")"
    touch "$env_file_path"
    # Remove any old block before appending the new one
    sed -i.bak '/# --- Zscaler & NCS Certificate Configuration/,/# --- End Zscaler Configuration ---/d' "$env_file_path"
    echo -e "\n$env_block" >> "$env_file_path"

    print_success ".env file has been created/updated."
}

# Configures Git to use the golden bundle
configure_git() {
    print_info "Configuring Git..."
    git config --global http.sslcainfo "$GOLDEN_BUNDLE_FILE"
    print_success "Git http.sslcainfo configured globally."
}

# Configures gcloud to use the golden bundle
configure_gcloud() {
    print_info "Configuring gcloud..."
    gcloud config set core/custom_ca_certs_file "$GOLDEN_BUNDLE_FILE" >/dev/null 2>&1
    print_success "Google Cloud SDK core/custom_ca_certs_file configured."
}

# Configures pip to use the golden bundle
configure_pip() {
    print_info "Configuring pip..."
    pip3 config set global.cert "$GOLDEN_BUNDLE_FILE"
    print_success "pip global.cert configured."
}

# Displays help message
show_help() {
    cat << EOF
NCS Zscaler & Dev Environment Setup Script (v3.0.0)

This script configures your environment to work with the Zscaler proxy.
You can control which actions to perform using the flags below.

Usage:
  ./zscaler.sh [FLAGS]

Actions:
  --build-bundle        Fetches, validates, and creates the 'ncs_golden_bundle.pem'.
                        This is the primary action required by all others.
  --update-shell        Detects your shell and adds the required environment
                        variables to your profile (~/.bashrc, ~/.zshrc, etc).
  --update-env-file <path> Creates or updates a .env file at the specified path.
                        Example: --update-env-file ~/my_project/.env
  --configure-git       Configures Git to use the certificate bundle.
  --configure-gcloud    Configures gcloud (Google Cloud SDK) to use the bundle.
  --configure-pip       Configures pip to use the certificate bundle.

Convenience Flags:
  --all                 Performs all actions: --build-bundle, --update-shell,
                        and configures all tools (git, gcloud, pip).
  -h, --help            Show this help message.

Example - Full Setup:
  ./zscaler.sh --all

Example - Only create bundle and update a project's .env file:
  ./zscaler.sh --build-bundle --update-env-file /path/to/my/project/.env
EOF
}

# --- 3. Main Execution ---
main() {
    # --- Global Paths ---
    CERT_DIR="$HOME/certs"
    ZSCALER_CHAIN_FILE="$CERT_DIR/zscaler_chain.pem"
    GOLDEN_BUNDLE_FILE="$CERT_DIR/ncs_golden_bundle.pem"
    
    # --- Argument Parsing ---
    if [ $# -eq 0 ]; then
        show_help
        exit 1
    fi

    ACTION_BUILD_BUNDLE=false
    ACTION_UPDATE_SHELL=false
    ACTION_CONFIGURE_GIT=false
    ACTION_CONFIGURE_GCLOUD=false
    ACTION_CONFIGURE_PIP=false
    ENV_FILE_PATH=""

    while [ "$1" != "" ]; do
        case $1 in
            --all )
                ACTION_BUILD_BUNDLE=true
                ACTION_UPDATE_SHELL=true
                ACTION_CONFIGURE_GIT=true
                ACTION_CONFIGURE_GCLOUD=true
                ACTION_CONFIGURE_PIP=true
                ;;
            --build-bundle )
                ACTION_BUILD_BUNDLE=true
                ;;
            --update-shell )
                ACTION_UPDATE_SHELL=true
                ;;
            --update-env-file )
                shift
                ENV_FILE_PATH=$1
                ;;
            --configure-git )
                ACTION_CONFIGURE_GIT=true
                ;;
            --configure-gcloud )
                ACTION_CONFIGURE_GCLOUD=true
                ;;
            --configure-pip )
                ACTION_CONFIGURE_PIP=true
                ;;
            -h | --help )
                show_help
                exit 0
                ;;
            * )
                print_error "Unknown parameter: $1"
                show_help
                exit 1
                ;;
        esac
        shift
    done

    style --border normal --margin "1" --padding "1 2" --border-foreground "#0077B6" \
        "NCS Australia - Zscaler & Development Environment Setup"

    detect_os

    # --- Execute Actions based on flags ---
    
    # Building the bundle is a prerequisite for all other actions
    if [ "$ACTION_BUILD_BUNDLE" = true ] || [ "$ACTION_UPDATE_SHELL" = true ] || [ -n "$ENV_FILE_PATH" ] || [ "$ACTION_CONFIGURE_GIT" = true ] || [ "$ACTION_CONFIGURE_GCLOUD" = true ] || [ "$ACTION_CONFIGURE_PIP" = true ]; then
      check_dependencies
      if [ "$ACTION_BUILD_BUNDLE" = true ] || [ ! -f "$GOLDEN_BUNDLE_FILE" ]; then
          fetch_and_validate_certs "$CERT_DIR" "$ZSCALER_CHAIN_FILE"
          build_golden_bundle
      else
          print_info "Skipping bundle build, '$GOLDEN_BUNDLE_FILE' already exists."
      fi
    fi

    if [ "$ACTION_UPDATE_SHELL" = true ]; then
        update_shell_profile
    fi

    if [ -n "$ENV_FILE_PATH" ]; then
        update_env_file "$ENV_FILE_PATH"
    fi

    if [ "$ACTION_CONFIGURE_GIT" = true ]; then
        configure_git
    fi

    if [ "$ACTION_CONFIGURE_GCLOUD" = true ]; then
        configure_gcloud
    fi

    if [ "$ACTION_CONFIGURE_PIP" = true ]; then
        configure_pip
    fi

    echo
    print_success "Script finished."
    style --border double --padding "1" --margin "1" --border-foreground "#0077B6" \
        "Remember to reload your shell ('source ~/.your_profile') or open a new terminal for changes to apply."
}

# --- Script Entrypoint ---
main "$@"