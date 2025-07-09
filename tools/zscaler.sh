#!/bin/zsh
#
# NCS Australia - Zscaler & Development Environment Setup Script
#
# Author: Emile Hofsink
# Version: 2.0.0
#
# This script automates the configuration of a development environment
# to work seamlessly behind the NCS Zscaler proxy. It automatically
# discovers and fetches the required Zscaler CA certificates.
#
# It performs the following actions:
# 1.  Checks for required dependencies (gum, git, gcloud, python3, pip, openssl).
# 2.  Offers to install 'gum' if it is missing.
# 3.  Auto-discovers the Zscaler certificate chain by connecting to an external site.
# 4.  Creates a ~/certs directory to store certificate files.
# 5.  Locates the active Python's `certifi` CA bundle.
# 6.  Creates a 'golden bundle' by combining the certifi bundle and the discovered Zscaler chain.
# 7.  Confirms with the user before appending environment variables to their shell profile.
# 8.  Sets tool-specific configurations for Git, gcloud, and pip.
# 9.  Provides clear, styled feedback and instructions to the user.
#
# Usage:
#   ./setup_ncs_certs.sh
#   (No arguments are needed)
#

# --- 1. Dependency Check ---
check_dependencies() {
    # Check for gum first, as it's essential for the UI.
    # We use standard 'echo' and 'read' here since gum may not be installed yet.
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
                echo "✖ Could not find Homebrew or Go. Please install 'gum' manually."
                echo "   Visit: https://github.com/charmbracelet/gum"
                exit 1
            fi
            # Verify installation post-attempt
            if ! command -v gum &> /dev/null; then
                echo "✖ 'gum' installation failed. Please install it manually and re-run the script."
                exit 1
            fi
             echo "✔ 'gum' installed successfully. Please re-run the script."
             exit 0
        else
            echo "✖ 'gum' is required to proceed. Please install it and re-run the script."
            exit 1
        fi
    fi

    # Helper function for styled error messages, now that we know gum exists.
    print_error() {
        gum style --foreground 9 "✖ Error: $1"
    }

    # Now that we know gum exists, we can use it for the rest of the checks
    gum style --bold --padding "0 1" "Checking remaining dependencies..."
    local missing_deps=0
    # Added 'openssl' to the dependency list
    for cmd in git gcloud python3 pip openssl; do
        if ! command -v "$cmd" &> /dev/null; then
            print_error "'$cmd' command not found. Please install it and try again."
            missing_deps=$((missing_deps + 1))
        fi
    done

    if [ "$missing_deps" -gt 0 ]; then
        gum style --bold "Aborting due to missing dependencies."
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
    # The script no longer takes arguments.
    if [ "$#" -ne 0 ]; then
        print_error "This script does not accept any arguments."
        gum style "Usage: ./setup_ncs_certs.sh"
        exit 1
    fi

    # --- Define Paths and Profile ---
    CERT_DIR="$HOME/certs"
    ZSCALER_CHAIN_FILE="$CERT_DIR/zscaler_chain.pem"
    GOLDEN_BUNDLE_FILE="$CERT_DIR/ncs_golden_bundle.pem"
    SHELL_PROFILE=""

    if [ -n "$ZSH_VERSION" ]; then
       SHELL_PROFILE="$HOME/.zshrc"
    elif [ -n "$BASH_VERSION" ]; then
       SHELL_PROFILE="$HOME/.bash_profile"
       [ ! -f "$SHELL_PROFILE" ] && SHELL_PROFILE="$HOME/.bashrc"
    else
        gum style --foreground 212 "Could not auto-detect shell. Please choose your profile file:"
        SHELL_PROFILE=$(gum file "$HOME")
        if [ -z "$SHELL_PROFILE" ]; then
            print_error "No shell profile selected. Aborting."
            exit 1
        fi
    fi
    gum style "✔ Using shell profile: $(gum style --foreground '#00B4D8' "$SHELL_PROFILE")"

    # --- Auto-discover and Fetch Certificates ---
    mkdir -p "$CERT_DIR"
    
    # Use openssl to connect to an external site and capture the certificate chain presented by Zscaler.
    # The sed command extracts only the PEM-formatted certificate blocks.
    # We define this as a function to make it work cleanly with gum spin.
    fetch_certs() {
        # The 'echo' prevents openssl from waiting for stdin.
        # 2>/dev/null suppresses connection errors from appearing in the output.
        echo | openssl s_client -showcerts -connect google.com:443 2>/dev/null | sed -n '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/p' > "$ZSCALER_CHAIN_FILE"
    }

    gum spin --spinner dot --title "Discovering and fetching Zscaler certificate chain..." -- bash -c "$(declare -f fetch_certs); fetch_certs"
    
    # Check if the file was created and is not empty
    if [ ! -s "$ZSCALER_CHAIN_FILE" ]; then
        print_error "Failed to fetch Zscaler certificates. Are you connected to the NCS network?"
        exit 1
    fi
    
    gum style "✔ Zscaler chain discovered and saved to $(gum style --foreground '#00B4D8' "$ZSCALER_CHAIN_FILE")"

    # --- Create the Golden Bundle ---
    CERTIFI_PATH=$(python3 -m certifi 2>/dev/null)
    if [ -z "$CERTIFI_PATH" ]; then
        print_error "Could not find 'certifi' package. Please ensure it is installed."
        exit 1
    fi

    gum spin --spinner dot --title "Creating the 'Golden Bundle'..." -- \
        cat "$CERTIFI_PATH" "$ZSCALER_CHAIN_FILE" > "$GOLDEN_BUNDLE_FILE"
    gum style "✔ Golden Bundle created at $(gum style --foreground '#00B4D8' "$GOLDEN_BUNDLE_FILE")"

    # --- Configure Shell Environment ---
    ENV_CONFIG_BLOCK=$(cat <<EOF

# --- Zscaler & NCS Certificate Configuration (added by setup_ncs_certs.sh) ---
# This block ensures all command-line tools trust the NCS Zscaler proxy.
# The 'ncs_golden_bundle.pem' is a combination of standard CAs and the Zscaler chain.
export ZSCALER_CERT_BUNDLE="\$HOME/certs/ncs_golden_bundle.pem"
export SSL_CERT_FILE="\$ZSCALER_CERT_BUNDLE"
export CURL_CA_BUNDLE="\$ZSCALER_CERT_BUNDLE"
export REQUESTS_CA_BUNDLE="\$ZSCALER_CERT_BUNDLE"
export NODE_EXTRA_CA_CERTS="\$ZSCALER_CERT_BUNDLE"
export GRPC_DEFAULT_SSL_ROOTS_FILE_PATH="\$ZSCALER_CERT_BUNDLE"
# --- End Zscaler Configuration ---
EOF
)

    if gum confirm "Append the following configuration to '$SHELL_PROFILE'?"; then
        gum style "$ENV_CONFIG_BLOCK" --padding "1 2" --border rounded --border-foreground "#90E0EF"
        # Create a backup before modifying
        cp "$SHELL_PROFILE" "${SHELL_PROFILE}.bak.$(date +%F-%T)"
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
