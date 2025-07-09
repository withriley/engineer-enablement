#!/bin/zsh
#
# NCS Australia - Mise Development Environment Setup Script
#
# Author: Emile Hofsink
# Version: 1.1.1
#
# This script automates the complete installation and configuration of 'mise'
# according to the NCS Australia standard development environment.
#
# It performs the following actions:
# 1.  Checks for and downloads the latest version of itself.
# 2.  Checks for dependencies (gum, curl, git) and offers to install them.
# 3.  Installs the 'mise' binary using the official installer.
# 4.  Automatically creates the standard NCS 'config.toml' file.
# 5.  Automatically creates a robust '.env' file with the required Zscaler variables.
# 6.  Guides the user through activating mise in their shell (zsh, bash, or fish).
#
# Usage:
#   This script is best run via the one-liner, which saves it to a temporary file.
#   curl -sSL "https://raw.githubusercontent.com/withriley/engineer-enablement/main/tools/install_mise.sh?_=$(date +%s)" -o /tmp/install_mise.sh && zsh /tmp/install_mise.sh
#

# --- Self-Update Mechanism ---
# This ensures the user is always running the latest version of the script.
SCRIPT_URL="https://raw.githubusercontent.com/withriley/engineer-enablement/main/tools/install_mise.sh"
CURRENT_VERSION="1.1.1" # This must match the version in this header

self_update() {
    # Use plain echo since gum may not be installed yet.
    echo "Checking for script updates..."
    
    # Fetch the latest version string from the remote script.
    # The timestamp is a cache-busting mechanism.
    LATEST_VERSION=$(curl -sSL "${SCRIPT_URL}?_=$(date +%s)" | grep -m 1 "Version:" | awk '{print $3}')

    if [ -z "$LATEST_VERSION" ]; then
        echo "Warning: Could not check for script updates. Proceeding with the current version."
        return
    fi

    # Simple version comparison.
    if [ "$LATEST_VERSION" != "$CURRENT_VERSION" ]; then
        echo "A new version ($LATEST_VERSION) is available. The script will now update and re-launch."
        
        # The script needs to know its own location to overwrite itself.
        # This requires it to be run from a file, not a pipe.
        local script_path="$0"
        if [ -z "$script_path" ] || [[ ! -f "$script_path" ]]; then
            echo "Error: Cannot self-update when run from a pipe. Please use the recommended one-liner."
            exit 1
        fi

        # Download the new script to a temporary location.
        if curl -sSL "${SCRIPT_URL}?_=$(date +%s)" -o "$script_path.tmp"; then
            # Replace the old script with the new one.
            mv "$script_path.tmp" "$script_path"
            # Make sure the new script is executable.
            chmod +x "$script_path"
            echo "Update complete. Re-executing the script..."
            # Re-execute the new script, passing along any arguments.
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
    for cmd in curl git; do
        if ! command -v "$cmd" &> /dev/null; then
            missing_deps+=("$cmd")
        fi
    done

    if [ ${#missing_deps[@]} -gt 0 ]; then
        print_error "This script requires the following tools, but they are not installed: ${missing_deps[*]}"
        exit 1
    fi
    gum style --foreground 10 "✔ All dependencies are satisfied."
}

# --- Main Logic ---
main() {
    gum style --border normal --margin "1" --padding "1 2" --border-foreground "#0077B6" "NCS Australia - Mise Environment Setup"

    if command -v mise &> /dev/null; then
        gum style "✔ 'mise' is already installed. Skipping installation."
    else
        gum spin --spinner dot --title "Installing mise..." -- bash -c "curl -sS https://mise.jdx.dev/install.sh | sh"
        export PATH="$HOME/.local/bin:$PATH"
        if ! command -v mise &> /dev/null; then
            print_error "Mise installation failed. Please check the output above."
            exit 1
        fi
        gum style "✔ 'mise' installed successfully."
    fi

    local MISE_CONFIG_DIR="$HOME/.config/mise"
    local MISE_CONFIG_TOML="$MISE_CONFIG_DIR/config.toml"
    local MISE_ENV_FILE="$MISE_CONFIG_DIR/.env"

    mkdir -p "$MISE_CONFIG_DIR"
    gum style --bold "Creating NCS standard configuration files..."

    cat <<'EOF' > "$MISE_CONFIG_TOML"
# ~/.config/mise/config.toml
# NCS Australia Standard Mise Configuration
[settings]
experimental = true
trusted_config_paths = ["~/.config/mise/config.toml"]
[env]
_.file = "~/.config/mise/.env"
[tools]
go = "latest"
node = "latest"
deno = "latest"
bun = "latest"
rust = "latest"
python = "3.12"
dart = "latest"
flutter = "latest"
lua = "5.1"
terraform = "latest"
pnpm = "latest"
usage = "latest"
pipx = "latest"
lazygit = "latest"
lazydocker = "latest"
gcloud = "latest"
yq = "latest"
jq = "latest"
gh = "latest"
gitleaks = "latest"
tokei = "latest"
zoxide = "latest"
fzf = "latest"
fd = "latest"
ripgrep = "latest"
"go:github.com/GoogleCloudPlatform/cloud-sql-proxy/v2" = { version = "latest" }
"go:github.com/air-verse/air" = { version = "latest" }
"go:github.com/swaggo/swag/cmd/swag" = { version = "latest" }
"go:github.com/sqlc-dev/sqlc/cmd/sqlc" = { version = "latest" }
"go:github.com/charmbracelet/freeze" = { version = "latest" }
"go:github.com/charmbracelet/vhs" = { version = "latest" }
"npm:@dataform/cli" = "latest"
"npm:@google/gemini-cli" = "latest"
"npm:opencode-ai" = "latest"
"pipx:sqlfluff/sqlfluff" = "latest"
"cargo:tuckr" = "latest"
[tasks.bundle-update]
description = "Runs Update, Upgrade, Cleanup and Autoremove for Brew"
run = "brew update && brew upgrade && brew cleanup && brew autoremove"
[tasks.set-gcp-project]
description = "Sets the active Google Cloud project and ADC quota project."
usage = 'arg "<project_id>" "The Google Cloud Project ID to set."'
run = "gcloud config set project {{arg(name='project_id')}} && gcloud auth application-default set-quota-project {{arg(name='project_id')}}"
[tasks.banish-ds-store]
description = "Removes .DS_Store files from a Git repository."
dir = "{{cwd}}"
run = "find . -name .DS_Store -print0 | xargs -0 git rm -f --ignore-unmatch && echo .DS_Store >> .gitignore && git add .gitignore && git commit -m ':fire: .DS_Store banished!' && git push"
EOF
    gum style "✔ Created $(gum style --foreground '#00B4D8' "$MISE_CONFIG_TOML")"

    # Create .env file for Zscaler.
    # We remove the quotes from <<'EOF' to allow $HOME to be expanded by the shell.
    # We also explicitly set the full path for every variable to avoid expansion issues
    # in nested processes like `go get`.
    cat <<EOF > "$MISE_ENV_FILE"
# ~/.config/mise/.env
# This file provides environment variables to all tools managed by mise.
# It assumes you have run the zscaler.sh script first.

# Zscaler Certificate Configuration
SSL_CERT_FILE="$HOME/certs/ncs_golden_bundle.pem"
SSL_CERT_DIR="$HOME/certs"
CERT_PATH="$HOME/certs/ncs_golden_bundle.pem"
CERT_DIR="$HOME/certs"
REQUESTS_CA_BUNDLE="$HOME/certs/ncs_golden_bundle.pem"
CURL_CA_BUNDLE="$HOME/certs/ncs_golden_bundle.pem"
NODE_EXTRA_CA_CERTS="$HOME/certs/ncs_golden_bundle.pem"
GRPC_DEFAULT_SSL_ROOTS_FILE_PATH="$HOME/certs/ncs_golden_bundle.pem"
GIT_SSL_CAINFO="$HOME/certs/ncs_golden_bundle.pem"
CLOUDSDK_CORE_CUSTOM_CA_CERTS_FILE="$HOME/certs/ncs_golden_bundle.pem"
EOF
    gum style "✔ Created $(gum style --foreground '#00B4D8' "$MISE_ENV_FILE")"

    gum style --bold --padding "1 0" "Final Step: Activate 'mise' in your shell"
    local shell_type
    local shell_profile
    local activation_cmd
    local parent_shell
    parent_shell=$(ps -p $$ -o comm=)

    if [[ "$parent_shell" == "zsh" ]]; then
        shell_type="zsh"; shell_profile="$HOME/.zshrc"; activation_cmd='eval "$(mise activate zsh)"'
    elif [[ "$parent_shell" == "bash" ]]; then
        shell_type="bash"; shell_profile="$HOME/.bash_profile"; [ ! -f "$shell_profile" ] && shell_profile="$HOME/.bashrc"; activation_cmd='eval "$(mise activate bash)"'
    elif [[ "$parent_shell" == "fish" ]]; then
        shell_type="fish"; shell_profile="$HOME/.config/fish/config.fish"; activation_cmd='mise activate fish | source'
    else
        print_error "Could not automatically detect your shell ($parent_shell)."
        gum style "Please add the appropriate activation command for your shell to its startup file."
        exit 1
    fi

    gum style "Your detected shell is $(gum style --bold "$shell_type"). The required activation command is:"
    gum style "$activation_cmd" --padding "0 2" --border rounded --border-foreground "#90E0EF"

    if gum confirm "Append this command to '$shell_profile'?" < /dev/tty; then
        cp "$shell_profile" "${shell_profile}.bak.$(date +%F-%T)"
        touch "$shell_profile"
        echo -e "\n# Activate mise\n$activation_cmd" >> "$shell_profile"
        gum style "✔ Activation command added to '$shell_profile'."
    else
        gum style --foreground 212 "Skipping automatic modification. Please add the activation command manually."
    fi

    FINAL_MESSAGE=$(cat <<EOF
NCS Mise Environment Setup Complete!

Two final steps are required:

1.  **Restart your terminal completely.**
    This is essential for the shell activation to take effect.

2.  **Run 'mise install' in your new terminal.**
    This will download and install all the standard NCS tools.
    It will take some time on the first run.

    mise install

After that, you can start removing conflicting tools previously
installed by Homebrew (e.g., 'brew uninstall terraform').
EOF
)
    gum style "$FINAL_MESSAGE" --border double --padding "1 2" --margin "1" --border-foreground "#0077B6"
}

# --- Script Entrypoint ---
# The self-update must be run first. It will exit or re-execute the script.
self_update "$@"

# The rest of the script will only run if it's up-to-date.
check_dependencies
main "$@"
