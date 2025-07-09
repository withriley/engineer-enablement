#!/bin/zsh
#
# NCS Australia - Zscaler & Development Environment Setup Script
#
# Author: Emile Hofsink
# Version: 2.3.4
#
# This script automates the configuration of a development environment
# to work seamlessly behind the NCS Zscaler proxy. It automatically
# discovers and fetches the required Zscaler CA certificates.
#
# It performs the following actions:
# 1.  Checks for required dependencies and offers to install them.
# 2.  Auto-discovers the Zscaler certificate chain, with retries for reliability.
# 3.  Validates that the fetched certificate is issued by Zscaler.
# 4.  Creates a ~/certs directory to store certificate files.
# 5.  Locates the active Python's `certifi` CA bundle.
# 6.  Creates a 'golden bundle' by combining the certifi bundle and the discovered Zscaler chain.
# 7.  Detects the user's shell (bash, zsh, fish) and uses the correct syntax.
# 8.  Confirms with the user before appending environment variables to their shell profile.
# 9.  Sets tool-specific configurations for Git, gcloud, and pip.
# 10. Provides clear, styled feedback and instructions to the user.
#
# Usage:
#   ./zscaler.sh
#   (No arguments are needed)
#

# --- 1. Dependency Check & Installation ---
check_dependencies() {
    # Helper function for styled error messages
    print_error() {
        # Use gum if available, otherwise plain echo
        if command -v gum &> /dev/null; then
            gum style --foreground 9 "✖ Error: $1"
        else
            echo "✖ Error: $1"
        fi
    }

    # First, handle 'gum' itself, as it's needed for the UI.
    if ! command -v gum &> /dev/null; then
        echo "--- Dependency Check ---"
        echo "This script uses 'gum' for a better user experience, but it's not installed."
        printf "Would you like to attempt to install it via Homebrew (macOS) or Go? [y/N] "
        read -r response
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

    # Now we know gum exists, proceed with checking other dependencies.
    gum style --bold --padding "0 1" "Checking remaining dependencies..."
    local missing_deps=()
    for cmd in git openssl python3 gcloud; do
        if ! command -v "$cmd" &> /dev/null; then
            missing_deps+=("$cmd")
        fi
    done

    if [ ${#missing_deps[@]} -gt 0 ]; then
        gum style --foreground 212 "The following required tools are missing: ${missing_deps[*]}"
        if ! gum confirm "Attempt to install them now?"; then
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
                        # On debian, pip is often separate
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
    # Final check for pip after python3 might have been installed
    if ! command -v pip &> /dev/null && ! command -v pip3 &> /dev/null; then
        print_error "'pip' is not installed. Please ensure your Python installation includes pip."
        exit 1
    fi
    gum style --foreground 10 "✔ All dependencies are satisfied."
}


# --- Main Logic ---
main() {
    # Helper function needs to be available in main scope too
    print_error() {
        gum style --foreground 9 "✖ Error: $1"
    }

    gum style --border normal --margin "1" --padding "1 2" --border-foreground "#0077B6" "NCS Australia - Zscaler & Development Environment Setup"

    # --- Input Validation ---
    if [ "$#" -ne 0 ]; then
        print_error "This script does not accept any arguments."
        gum style "Usage: ./zscaler.sh"
        exit 1
    fi

    # --- Define Paths and Profile ---
    CERT_DIR="$HOME/certs"
    ZSCALER_CHAIN_FILE="$CERT_DIR/zscaler_chain.pem"
    GOLDEN_BUNDLE_FILE="$CERT_DIR/ncs_golden_bundle.pem"
    SHELL_PROFILE=""
    SHELL_TYPE=""

    # Detect shell type and set profile path accordingly
    if [ -n "$ZSH_VERSION" ]; then
       SHELL_PROFILE="$HOME/.zshrc"
       SHELL_TYPE="posix"
    elif [ -n "$BASH_VERSION" ]; then
       SHELL_PROFILE="$HOME/.bash_profile"
       [ ! -f "$SHELL_PROFILE" ] && SHELL_PROFILE="$HOME/.bashrc"
       SHELL_TYPE="posix"
    elif [ -n "$FISH_VERSION" ]; then
       # Ensure the fish config directory exists
       mkdir -p "$HOME/.config/fish"
       SHELL_PROFILE="$HOME/.config/fish/config.fish"
       SHELL_TYPE="fish"
    else
        gum style --foreground 212 "Could not auto-detect shell. Please choose your profile file:"
        SHELL_PROFILE=$(gum file "$HOME")
        if [ -z "$SHELL_PROFILE" ]; then
            print_error "No shell profile selected. Aborting."
            exit 1
        fi
        # Make a best guess for unknown shells
        SHELL_TYPE="posix"
        gum style --foreground 212 "Assuming POSIX-compatible shell syntax (export VAR=value)."
    fi
    gum style "✔ Using shell profile: $(gum style --foreground '#00B4D8' "$SHELL_PROFILE")"

    # --- Auto-discover and Fetch Certificates ---
    mkdir -p "$CERT_DIR"
    
    fetch_certs_with_retry() {
        local retries=3
        for i in $(seq 1 $retries); do
            # Using awk for more robust parsing of certificate blocks.
            LC_ALL=C echo | openssl s_client -showcerts -connect google.com:443 2>/dev/null | awk '/-----BEGIN CERTIFICATE-----/{p=1}; p; /-----END CERTIFICATE-----/{p=0}' > "$ZSCALER_CHAIN_FILE"
            
            # Check if the file is not empty AND if it's a valid Zscaler cert
            if [ -s "$ZSCALER_CHAIN_FILE" ]; then
                if openssl x509 -in "$ZSCALER_CHAIN_FILE" -noout -issuer | grep -q "Zscaler"; then
                    # Success, we got a valid Zscaler cert
                    return 0
                else
                    # It's a cert, but not from Zscaler. Invalidate it and retry.
                    > "$ZSCALER_CHAIN_FILE" # Empty the file to signal failure
                fi
            fi

            if [ "$i" -lt "$retries" ]; then sleep 1; fi
        done
        return 1
    }

    # Removed the `bash -c` wrapper for more direct execution.
    gum spin --spinner dot --title "Discovering and fetching Zscaler certificate chain..." fetch_certs_with_retry
    
    if [ ! -s "$ZSCALER_CHAIN_FILE" ]; then
        print_error "Failed to fetch a valid Zscaler certificate. Please ensure you are on the NCS network."
        exit 1
    fi
    
    gum style "✔ Zscaler chain discovered and saved to $(gum style --foreground '#00B4D8' "$ZSCALER_CHAIN_FILE")"

    # --- Create the Golden Bundle ---
    CERTIFI_PATH=$(python3 -m certifi 2>/dev/null)
    if [ -z "$CERTIFI_PATH" ]; then
        print_error "Could not find 'certifi' package. Please ensure it is installed (`pip install --upgrade certifi`)."
        exit 1
    fi

    gum spin --spinner dot --title "Creating the 'Golden Bundle'..." -- \
        cat "$CERTIFI_PATH" "$ZSCALER_CHAIN_FILE" > "$GOLDEN_BUNDLE_FILE"
    gum style "✔ Golden Bundle created at $(gum style --foreground '#00B4D8' "$GOLDEN_BUNDLE_FILE")"

    # --- Configure Shell Environment ---
    ENV_CONFIG_BLOCK=""
    if [ "$SHELL_TYPE" = "fish" ]; then
        ENV_CONFIG_BLOCK=$(cat <<'EOF'

# --- Zscaler & NCS Certificate Configuration (added by zscaler.sh) ---
# This block ensures all command-line tools trust the NCS Zscaler proxy.
set -gx ZSCALER_CERT_BUNDLE "$HOME/certs/ncs_golden_bundle.pem"
set -gx SSL_CERT_FILE "$ZSCALER_CERT_BUNDLE"
set -gx CURL_CA_BUNDLE "$ZSCALER_CERT_BUNDLE"
set -gx REQUESTS_CA_BUNDLE "$ZSCALER_CERT_BUNDLE"
set -gx NODE_EXTRA_CA_CERTS "$ZSCALER_CERT_BUNDLE"
set -gx GRPC_DEFAULT_SSL_ROOTS_FILE_PATH "$ZSCALER_CERT_BUNDLE"
# --- End Zscaler Configuration ---
EOF
)
    else # Default to POSIX syntax for bash, zsh, etc.
        ENV_CONFIG_BLOCK=$(cat <<'EOF'

# --- Zscaler & NCS Certificate Configuration (added by zscaler.sh) ---
# This block ensures all command-line tools trust the NCS Zscaler proxy.
# The 'ncs_golden_bundle.pem' is a combination of standard CAs and the Zscaler chain.
export ZSCALER_CERT_BUNDLE="$HOME/certs/ncs_golden_bundle.pem"
export SSL_CERT_FILE="$ZSCALER_CERT_BUNDLE"
export CURL_CA_BUNDLE="$ZSCALER_CERT_BUNDLE"
export REQUESTS_CA_BUNDLE="$ZSCALER_CERT_BUNDLE"
export NODE_EXTRA_CA_CERTS="$ZSCALER_CERT_BUNDLE"
export GRPC_DEFAULT_SSL_ROOTS_FILE_PATH="$ZSCALER_CERT_BUNDLE"
# --- End Zscaler Configuration ---
EOF
)
    fi

    if gum confirm "Append the following configuration to '$SHELL_PROFILE'?"; then
        gum style "$ENV_CONFIG_BLOCK" --padding "1 2" --border rounded --border-foreground "#90E0EF"
        cp "$SHELL_PROFILE" "${SHELL_PROFILE}.bak.$(date +%F-%T)"
        # Ensure the profile file exists before appending
        touch "$SHELL_PROFILE"
        echo "$ENV_CONFIG_BLOCK" >> "$SHELL_PROFILE"
        gum style "✔ Environment variables added to your shell profile."
    else
        gum style --foreground 212 "Skipping shell profile modification. Please add the following manually:"
        gum style "$ENV_CONFIG_BLOCK" --padding "1 2" --border rounded --border-foreground "#90E0EF"
    fi

    # --- Configure Specific Tools ---
    gum spin --spinner line --title "Configuring Git, gcloud, and pip..." -- bash -c "
        git config --global http.sslcainfo '$GOLDEN_BUNDLE_FILE'
        gcloud config set core/custom_ca_certs_file '$GOLDEN_BUNDLE_FILE' >/dev/null 2>&1
        pip config set global.cert '$GOLDEN_BUNDLE_FILE' >/dev/null 2>&1
    "
    gum style "✔ Git, gcloud, and pip have been configured."

    # --- Final Instructions ---
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
check_dependencies
main "$@"
