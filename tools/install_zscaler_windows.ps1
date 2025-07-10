<#
.SYNOPSIS
    NCS Australia - Zscaler & Development Environment Setup Script for Windows
.DESCRIPTION
    This script automates the configuration of a Windows development environment
    to work seamlessly behind the NCS Zscaler proxy. It automatically
    discovers and fetches the required Zscaler CA certificates.

.NOTES
    Author: Emile Hofsink
    Version: 1.2.2
    Requires: Windows PowerShell 5.1+ or PowerShell 7+
    Run this script in an Administrator PowerShell session.

.EXAMPLE
    .\install_zscaler_windows.ps1

.EXAMPLE
    .\install_zscaler_windows.ps1 -Verbose
#>
[CmdletBinding()]
param (
    [Switch]$Verbose
)

# --- Script Setup ---
$ErrorActionPreference = 'Stop'
$global:VerbosePreference = if ($Verbose) { 'Continue' } else { 'SilentlyContinue' }

# --- Helper Functions ---
function Write-Styled {
    param(
        [Parameter(Mandatory=$true, Position=0)]
        [string]$Message,
        [string]$ForegroundColor = 'White'
    )
    Write-Host $Message -ForegroundColor $ForegroundColor
}

function Write-Success {
    param([string]$Message)
    Write-Styled -Message "✔ $Message" -ForegroundColor 'Green'
}

function Write-Warning {
    param([string]$Message)
    Write-Styled -Message "⚠ $Message" -ForegroundColor 'Yellow'
}

function Write-ErrorMsg {
    param([string]$Message)
    Write-Styled -Message "✖ $Message" -ForegroundColor 'Red'
}

# --- 1. Dependency Check & Installation ---
function Check-Dependencies {
    Write-Styled -Message "Checking dependencies..." -ForegroundColor 'Cyan'
    if (-not (Get-Command scoop -ErrorAction SilentlyContinue)) {
        Write-Warning "Package manager 'Scoop' not found."
        $choice = Read-Host "Would you like to install it now? (This is recommended) [y/N]"
        if ($choice -eq 'y') {
            try {
                Set-ExecutionPolicy RemoteSigned -Scope CurrentUser -Force
                Invoke-RestMethod -Uri https://get.scoop.sh | Invoke-Expression
                Write-Success "Scoop installed successfully. Please close and re-open this Administrator PowerShell session, then re-run the script."
                exit
            } catch {
                $exception = $_
                Write-ErrorMsg ("Scoop installation failed: " + $exception.Exception.Message)
                exit
            }
        } else {
            Write-ErrorMsg "Scoop is required to automatically install other dependencies. Please install it and re-run."
            exit
        }
    }
    $missingDeps = @()
    $deps = @('git', 'openssl', 'python', 'gcloud')
    foreach ($dep in $deps) {
        if (-not (Get-Command $dep -ErrorAction SilentlyContinue)) { $missingDeps += $dep }
    }
    if ($missingDeps.Count -gt 0) {
        Write-Warning "The following required tools are missing: $($missingDeps -join ', ')"
        $choice = Read-Host "Attempt to install them now using Scoop? [y/N]"
        if ($choice -eq 'y') {
            foreach ($dep in $missingDeps) {
                try {
                    scoop install $dep
                    Write-Success "$dep installed."
                } catch {
                    $exception = $_
                    Write-ErrorMsg ("Failed to install $dep: " + $exception.Exception.Message)
                }
            }
            Write-Success "Dependency installation complete. Please close and re-open this Administrator PowerShell session, then re-run the script."
            exit
        } else {
            Write-ErrorMsg "Aborting. Please install the missing dependencies and re-run."
            exit
        }
    }
    Write-Success "All dependencies are satisfied."
}

# --- Main Logic ---
function Main {
    $CurrentVersion = "1.2.2"
    Write-Styled -Message "===========================================================" -ForegroundColor 'Cyan'
    Write-Styled -Message "  NCS Australia - Zscaler Setup for Windows (v$CurrentVersion)" -ForegroundColor 'Cyan'
    Write-Styled -Message "===========================================================" -ForegroundColor 'Cyan'
    
    $certsDir = Join-Path $HOME "certs"
    if (-not (Test-Path $certsDir)) {
        New-Item -Path $certsDir -ItemType Directory | Out-Null
    }
    $zscalerChainFile = Join-Path $certsDir "zscaler_chain.pem"
    $goldenBundleFile = Join-Path $certsDir "ncs_golden_bundle.pem"

    Write-Styled -Message "Discovering and fetching Zscaler certificate chain..." -ForegroundColor 'Yellow'
    $success = $false
    $retries = 3
    for ($i = 1; $i -le $retries; $i++) {
        Write-Verbose "--- Attempt $i of $retries ---"
        try {
            $request = [System.Net.HttpWebRequest]::Create("https://google.com")
            $request.ServerCertificateValidationCallback = { $true }
            $response = $request.GetResponse()
            $cert = $request.ServicePoint.Certificate
            $chain = New-Object System.Security.Cryptography.X509Certificates.X509Chain
            $chain.Build($cert)
            $pemChain = ""
            foreach ($element in $chain.ChainElements) {
                $pemCert = "-----BEGIN CERTIFICATE-----`n" + [System.Convert]::ToBase64String($element.Certificate.Export('Cert'), 'InsertLineBreaks') + "`n-----END CERTIFICATE-----`n"
                $pemChain += $pemCert
            }
            Set-Content -Path $zscalerChainFile -Value $pemChain -Encoding Ascii
            $issuer = (openssl x509 -in $zscalerChainFile -noout -issuer).ToString()
            if ($issuer -like '*Zscaler*') {
                Write-Verbose "✔ Issuer is Zscaler. Success!"
                $success = $true
                break
            } else {
                Write-Verbose "✖ Certificate issuer is not Zscaler."
                Remove-Item $zscalerChainFile -ErrorAction SilentlyContinue
            }
        } catch {
            $exception = $_
            Write-Verbose ("✖ Connection or certificate fetch failed on attempt $i: " + $exception.Exception.Message)
        }
        if ($i -lt $retries) { Start-Sleep -Seconds 1 }
    }

    if (-not $success) {
        Write-ErrorMsg "Failed to fetch a valid Zscaler certificate. Please ensure you are on the NCS network."
        exit
    }
    Write-Success "Zscaler chain discovered and saved to $zscalerChainFile"

    Write-Styled -Message "Installing Zscaler Root CA into Windows Trust Store..." -ForegroundColor 'Yellow'
    try {
        Import-Certificate -FilePath $zscalerChainFile -CertStoreLocation Cert:\CurrentUser\Root
        Write-Success "Zscaler Root CA successfully installed for the current user."
    } catch {
        $exception = $_
        Write-ErrorMsg ("Failed to install certificate to Windows Trust Store: " + $exception.Exception.Message)
    }

    Write-Styled -Message "Creating the 'Golden Bundle'..." -ForegroundColor 'Yellow'
    $certifiPath = (python -m certifi)
    if (-not $certifiPath) {
        Write-ErrorMsg "Could not find 'certifi' package. Please ensure it is installed (`pip install --upgrade certifi`)."
        exit
    }
    $certifiContent = Get-Content $certifiPath -Raw
    $zscalerContent = Get-Content $zscalerChainFile -Raw
    Set-Content -Path $goldenBundleFile -Value ($certifiContent + "`n" + $zscalerContent) -Encoding Ascii
    Write-Success "Golden Bundle created at $goldenBundleFile"

    Write-Styled -Message "Setting system-wide environment variables..." -ForegroundColor 'Yellow'
    $envVars = @{
        "SSL_CERT_FILE" = $goldenBundleFile
        "SSL_CERT_DIR" = $certsDir
        "CERT_PATH" = $goldenBundleFile
        "CERT_DIR" = $certsDir
        "REQUESTS_CA_BUNDLE" = $goldenBundleFile
        "CURL_CA_BUNDLE" = $goldenBundleFile
        "NODE_EXTRA_CA_CERTS" = $goldenBundleFile
        "GRPC_DEFAULT_SSL_ROOTS_FILE_PATH" = $goldenBundleFile
        "GIT_SSL_CAINFO" = $goldenBundleFile
        "CLOUDSDK_CORE_CUSTOM_CA_CERTS_FILE" = $goldenBundleFile
    }
    foreach ($key in $envVars.Keys) {
        $value = $envVars[$key]
        try {
            # Set persistently for the User
            [System.Environment]::SetEnvironmentVariable($key, $value, [System.EnvironmentVariableTarget]::User)
            # Set for the current process using the robust Set-Item cmdlet
            Set-Item -Path "Env:\$key" -Value $value
            Write-Verbose "Set User Env Var: ${key} = ${value}"
        } catch {
            $exception = $_
            Write-ErrorMsg ("Failed to set environment variable '$key': " + $exception.Exception.Message)
        }
    }
    Write-Success "System environment variables have been set."

    Write-Styled -Message "Configuring Git, gcloud, and pip..." -ForegroundColor 'Yellow'
    try {
        git config --global http.sslcainfo $goldenBundleFile
        Write-Success "Git config set."
    } catch {
        $exception = $_
        Write-Warning ("Could not configure Git: " + $exception.Exception.Message)
    }
    try {
        gcloud config set core/custom_ca_certs_file $goldenBundleFile
        Write-Success "gcloud config set."
    } catch {
        $exception = $_
        Write-Warning ("Could not configure gcloud: " + $exception.Exception.Message)
    }
    try {
        pip config set global.cert $goldenBundleFile
        Write-Success "pip config set."
    } catch {
        $exception = $_
        Write-Warning ("Could not configure pip: " + $exception.Exception.Message)
    }

    Write-Styled -Message "===========================================================" -ForegroundColor 'Cyan'
    Write-Styled -Message "  NCS Environment Configuration Complete!" -ForegroundColor 'Cyan'
    Write-Styled -Message "===========================================================" -ForegroundColor 'Cyan'
    Write-Warning "IMPORTANT: You must close and re-open your PowerShell/CMD terminal for all changes to take full effect."
}

# --- Script Entrypoint ---
# Self-update removed to prevent parsing issues on first run. Use the one-liner to get the latest version.
Check-Dependencies
Main
