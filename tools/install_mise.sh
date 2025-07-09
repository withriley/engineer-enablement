#!/bin/zsh
#
# NCS Australia - Mise Development Environment Setup Script
#
# Author: Emile Hofsink
# Version: 1.0.1
#
# This script automates the complete installation and configuration of 'mise'
# according to the NCS Australia standard development environment.
#
# It performs the following actions:
# 1.  Checks for dependencies (gum, curl, git) and offers to install them.
# 2.  Installs the 'mise' binary using the official installer.
# 3.  Ensures '~/.local/bin' is in the user's PATH.
# 4.  Automatically creates the standard NCS 'config.toml' file.
# 5.  Automatically creates the '.env' file with the required Zscaler variables.
# 6.  Guides the user through activating mise in their shell (zsh, bash, or fish).
#
# Usage:
#   ./install_mise.sh
#   Or via one-liner: curl -sSL <url_to_script> | zsh
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
        # The '< /dev/tty' is crucial for ensuring this prompt works when run via a pipe (e.g. curl | zsh)
        printf "Would you like to attempt to install it via Homebrew (macOS) or Go? [y/N] "
        read -r response < /dev/tty
        if [[ "$response" =~ ^([yY][eE][sS]|[yY])$ ]]; then
            if command -v brew &> /dev/null; then
                echo "--> Found Homebrew. Attempting to install 'gum'..."
                brew install gum
            elif command -v go &> /dev/null;
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
                echo "✔ 'gum' installed successfully. Please re-run the script to continue."
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
    # Helper function needs to be available in main scope too
    print_error() {
        gum style --foreground 9 "✖ Error: $1"
    }

    gum style --border normal --margin "1" --padding "1 2" --border-foreground "#0077B6" "NCS Australia - Mise Environment Setup"

    # --- Step 1: Install Mise ---
    if command -v mise &> /dev/null; then
        gum style "✔ 'mise' is already installed. Skipping installation."
    else
        gum spin --spinner dot --title "Installing mise..." -- bash -c "curl -sS https://mise.jdx.dev/install.sh | sh"
        # Add mise to the current session's PATH to allow subsequent commands to work
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

    # --- Step 2: Create Standard Configuration Files ---
    mkdir -p "$MISE_CONFIG_DIR"
    gum style --bold "Creating NCS standard configuration files..."

    # Create config.toml
    cat <<'EOF' > "$MISE_CONFIG_TOML"
# ~/.config/mise/config.toml
# NCS Australia Standard Mise Configuration

[settings]
experimental = true
trusted_config_paths = [
    "~/.config/mise/config.toml",
]

[env]
# This tells mise to load environment variables from the specified file.
# We will use this for our Zscaler configuration.
_.file = "~/.config/mise/.env"

[tools]
# Languages
go = "latest"
node = "latest"
deno = "latest"
bun = "latest"
rust = "latest"
python = "3.12" # Pinned to 3.12 for broad compatibility (e.g., gsutil).
dart = "latest"
flutter = "latest"
lua = "5.1" # Pinned to 5.1 for Neovim compatibility.
terraform = "latest"
pnpm = "latest"

# Mise & Python Tooling
usage = "latest" # Required for CLI Completions
pipx = "latest"  # Python package manager

# TUI (Text-based User Interface) Tools
lazygit = "latest"
lazydocker = "latest"

# Core CLI Tools
gcloud = "latest"
yq = "latest"
jq = "latest"
gh = "latest"
gitleaks = "latest"
tokei = "latest"
zoxide = "latest"

# Neovim Ecosystem Tools
fzf = "latest"
fd = "latest"
ripgrep = "latest"

# Go-based Tools (special syntax)
"go:github.com/GoogleCloudPlatform/cloud-sql-proxy/v2" = { version = "latest" }
"go:github.com/air-verse/air" = { version = "latest" }
"go:github.com/swaggo/swag/cmd/swag" = { version = "latest" }
"go:github.com/sqlc-dev/sqlc/cmd/sqlc" = { version = "latest" }
"go:github.com/charmbracelet/freeze" = { version = "latest" }
"go:github.com/charmbracelet/vhs" = { version = "latest" }

# NPM-based Tools (special syntax)
"npm:@dataform/cli" = "latest"
"npm:@google/gemini-cli" = "latest"
"npm:opencode-ai" = "latest"

# Pipx-based Tools (special syntax)
"pipx:sqlfluff/sqlfluff" = "latest"

# Cargo-based Tools (special syntax)
"cargo:tuckr" = "latest"

# --- Task Runner Configuration ---
# This section defines reusable commands you can run with `mise run <task-name>`

[tasks.bundle-update]
description = "Runs Update, Upgrade, Cleanup and Autoremove for Brew"
run = """
brew update && brew upgrade && brew cleanup && brew autoremove
"""

[tasks.set-gcp-project]
description = "Sets the active Google Cloud project and ADC quota project."
usage = 'arg "<project_id>" "The Google Cloud Project ID to set."'
run = """
gcloud config set project {{arg(name='project_id')}}
gcloud auth application-default set-quota-project {{arg(name='project_id')}}
"""

[tasks.banish-ds-store]
description = "Removes .DS_Store files from a Git repository."
dir = "{{cwd}}"
run = """
find . -name .DS_Store -print0 | xargs -0 git rm -f --ignore-unmatch
echo .DS_Store >> .gitignore
git add .gitignore
git commit -m ':fire: .DS_Store banished!'
git push
"""
EOF
    gum style "✔ Created $(gum style --foreground '#00B4D8' "$MISE_CONFIG_TOML")"

    # Create .env file for Zscaler
    cat <<'EOF' > "$MISE_ENV_FILE"
# ~/.config/mise/.env
# This file provides environment variables to all tools managed by mise.
# It assumes you have run the zscaler.sh script first.

# Zscaler Certificate Configuration
ZSCALER_CERT_BUNDLE="$HOME/certs/ncs_golden_bundle.pem"
ZSCALER_CERT_DIR="$HOME/certs"
SSL_CERT_FILE="$ZSCALER_CERT_BUNDLE"
SSL_CERT_DIR="$ZSCALER_CERT_DIR"
CERT_PATH="$ZSCALER_CERT_BUNDLE"
CERT_DIR="$ZSCALER_CERT_DIR"
REQUESTS_CA_BUNDLE="$ZSCALER_CERT_BUNDLE"
CURL_CA_BUNDLE="$ZSCALER_CERT_BUNDLE"
NODE_EXTRA_CA_CERTS="$ZSCALER_CERT_BUNDLE"
GRPC_DEFAULT_SSL_ROOTS_FILE_PATH="$ZSCALER_CERT_BUNDLE"
GIT_SSL_CAINFO="$ZSCALER_CERT_BUNDLE"
CLOUDSDK_CORE_CUSTOM_CA_CERTS_FILE="$ZSCALER_CERT_BUNDLE"
EOF
    gum style "✔ Created $(gum style --foreground '#00B4D8' "$MISE_ENV_FILE")"

    # --- Step 3: Activate Mise in Shell ---
    gum style --bold --padding "1 0" "Final Step: Activate 'mise' in your shell"

    local shell_type
    local shell_profile
    local activation_cmd

    # We must check the shell by inspecting the parent process, as $ZSH_VERSION etc. aren't set in a `sh` subshell.
    local parent_shell
    parent_shell=$(ps -p $$ -o comm=)

    if [[ "$parent_shell" == "zsh" ]]; then
        shell_type="zsh"
        shell_profile="$HOME/.zshrc"
        activation_cmd='eval "$(mise activate zsh)"'
    elif [[ "$parent_shell" == "bash" ]]; then
        shell_type="bash"
        shell_profile="$HOME/.bash_profile"
        [ ! -f "$shell_profile" ] && shell_profile="$HOME/.bashrc"
        activation_cmd='eval "$(mise activate bash)"'
    elif [[ "$parent_shell" == "fish" ]]; then
        shell_type="fish"
        shell_profile="$HOME/.config/fish/config.fish"
        activation_cmd='mise activate fish | source'
    else
        print_error "Could not automatically detect your shell ($parent_shell)."
        gum style "Please add the appropriate activation command for your shell to its startup file."
        exit 1
    fi

    gum style "Your detected shell is $(gum style --bold "$shell_type"). The required activation command is:"
    gum style "$activation_cmd" --padding "0 2" --border rounded --border-foreground "#90E0EF"

    # Use < /dev/tty to ensure gum can read from the terminal even when piped
    if gum confirm "Append this command to '$shell_profile'?" < /dev/tty; then
        # Create a backup before modifying
        cp "$shell_profile" "${shell_profile}.bak.$(date +%F-%T)"
        touch "$shell_profile"
        echo -e "\n# Activate mise\n$activation_cmd" >> "$shell_profile"
        gum style "✔ Activation command added to '$shell_profile'."
    else
        gum style --foreground 212 "Skipping automatic modification. Please add the activation command manually."
    fi

    # --- Final Instructions ---
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
check_dependencies
main "$@"
