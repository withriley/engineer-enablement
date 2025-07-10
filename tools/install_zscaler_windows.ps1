<#
.SYNOPSIS
    NCS Australia - Zscaler & Development Environment Setup Script for Windows
.DESCRIPTION
    This script automates the configuration of a Windows development environment
    to work seamlessly behind the NCS Zscaler proxy. It automatically
    discovers and fetches the required Zscaler CA certificates.

.NOTES
    Author: Emile Hofsink
    Version: 1.2.0
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

# --- Self-Update Mechanism ---
$ScriptUrl = "https://raw.githubusercontent.com/withriley/engineer-enablement/refs/heads/main/tools/install_zscaler_windows.ps1"
$CurrentVersion = "1.2.0" # This must match the version in this header

function Self-Update {
    Write-Host "Checking for script updates..."
    try {
        $caBundlePath = Join-Path $HOME "certs\ncs_golden_bundle.pem"
        $latestScriptContent = ""

        # If our custom bundle exists, we must use a more complex method to make a cert-aware web request.
        if (Test-Path $caBundlePath) {
            # This C# code block defines a callback to handle certificate validation.
            $validationCallback = {
                param($sender, $certificate, $chain, $sslPolicyErrors)
                # On the first run, this allows the connection. On subsequent runs, it's not strictly needed but harmless.
                return $true 
            }
            [System.Net.ServicePointManager]::ServerCertificateValidationCallback = $validationCallback
            $webClient = New-Object System.Net.WebClient
            $latestScriptContent = $webClient.DownloadString("$ScriptUrl`?_=$(Get-Date -UFormat %s)")
        } else {
            # Before certs are installed, a simple request is fine. It will likely fail, which is handled by the catch block.
            $latestScriptContent = Invoke-RestMethod -Uri "$ScriptUrl`?_=$(Get-Date -UFormat %s)"
        }

        $latestVersion = ($latestScriptContent | Select-String -Pattern "Version:").Line.Split(' ')[-1]

        if ($null -eq $latestVersion) {
            Write-Warning "Could not determine latest version. Proceeding with current version."
            return
        }

        if ($latestVersion -ne $CurrentVersion) {
            Write-Host "A new version ($latestVersion) is available. The script will now update and re-launch." -ForegroundColor Yellow
            $scriptPath = $MyInvocation.MyCommand.Path
            # Use the same cert-aware method to download the update if needed.
            if (Test-Path $caBundlePath) {
                $webClient.DownloadFile("$ScriptUrl`?_=$(Get-Date -UFormat %s)", "$scriptPath.tmp")
                Move-Item -Path "$scriptPath.tmp" -Destination $scriptPath -Force
            } else {
                Invoke-RestMethod -Uri "$ScriptUrl`?_=$(Get-Date -UFormat %s)" -OutFile $scriptPath
            }
            Write-Host "Update complete. Re-executing the script..." -ForegroundColor Green
            & $scriptPath @PSBoundParameters
            exit
        }
    } 
    catch {
        $exception = $_
        Write-Warning "Could not check for script updates: $($exception.Exception.Message). Proceeding with current version."
    }
}


# --- Script Setup ---
$ErrorActionPreference = 'Stop'
$global:VerbosePreference = if ($Verbose) { 'Continue' } else { 'SilentlyContinue' }

# --- Helper Functions ---
function Write-Styled {
    param([Parameter(Mandatory=$true, Position=0)][string]$Message, [string]$ForegroundColor = 'White')
    Write-Host $Message -ForegroundColor $ForegroundColor
}
function Write-Success { param([string]$Message) Write-Styled -Message "✔ $Message" -ForegroundColor 'Green' }
function Write-Warning { param([string]$Message) Write-Styled -Message "⚠ $Message" -ForegroundColor 'Yellow' }
function Write-ErrorMsg { param([string]$Message) Write-Styled -Message "✖ $Message" -ForegroundColor 'Red' }

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
            } catch { Write-ErrorMsg "Scoop installation failed. Please install it manually from https://scoop.sh and re-run this script."; exit }
        } else { Write-ErrorMsg "Scoop is required to automatically install other dependencies. Please install it and re-run."; exit }
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
                try { scoop install $dep; Write-Success "$dep installed." } catch { Write-ErrorMsg "Failed to install $dep." }
            }
            Write-Success "Dependency installation complete. Please close and re-open this Administrator PowerShell session, then re-run the script."
            exit
        } else { Write-ErrorMsg "Aborting. Please install the missing dependencies and re-run."; exit }
    }
    Write-Success "All dependencies are satisfied."
}

# --- Main Logic ---
function Main {
    Write-Styled -Message "===========================================================" -ForegroundColor 'Cyan'
    Write-Styled -Message "  NCS Australia - Zscaler Environment Setup for Windows (v$CurrentVersion)" -ForegroundColor 'Cyan'
    Write-Styled -Message "===========================================================" -ForegroundColor 'Cyan'
    
    $certsDir = "$HOME\certs"
    if (-not (Test-Path $certsDir)) { New-Item -Path $certsDir -ItemType Directory | Out-Null }
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
                Write-Verbose "✔ Issuer is Zscaler. Success!"; $success = $true; break
            } else {
                Write-Verbose "✖ Certificate issuer is not Zscaler."; Remove-Item $zscalerChainFile -ErrorAction SilentlyContinue
            }
        } 
        catch {
            $exception = $_
            Write-Verbose "✖ Connection or certificate fetch failed on attempt $i $($exception.Exception.Message)"
        }
        if ($i -lt $retries) { Start-Sleep -Seconds 1 }
    }

    if (-not $success) { Write-ErrorMsg "Failed to fetch a valid Zscaler certificate. Please ensure you are on the NCS network."; exit }
    Write-Success "Zscaler chain discovered and saved to $zscalerChainFile"

    Write-Styled -Message "Installing Zscaler Root CA into Windows Trust Store..." -ForegroundColor 'Yellow'
    try {
        Import-Certificate -FilePath $zscalerChainFile -CertStoreLocation Cert:\CurrentUser\Root
        Write-Success "Zscaler Root CA successfully installed for the current user."
    } 
    catch { Write-ErrorMsg "Failed to install certificate to Windows Trust Store. Please ensure you are running as Administrator." }

    Write-Styled -Message "Creating the 'Golden Bundle'..." -ForegroundColor 'Yellow'
    $certifiPath = (python -m certifi)
    if (-not $certifiPath) { Write-ErrorMsg "Could not find 'certifi' package."; exit }
    $certifiContent = Get-Content $certifiPath -Raw
    $zscalerContent = Get-Content $zscalerChainFile -Raw
    Set-Content -Path $goldenBundleFile -Value ($certifiContent + "`n" + $zscalerContent) -Encoding Ascii
    Write-Success "Golden Bundle created at $goldenBundleFile"

    Write-Styled -Message "Setting system-wide environment variables..." -ForegroundColor 'Yellow'
    $envVars = @{
        "SSL_CERT_FILE" = $goldenBundleFile; "SSL_CERT_DIR" = $certsDir; "CERT_PATH" = $goldenBundleFile; "CERT_DIR" = $certsDir
        "REQUESTS_CA_BUNDLE" = $goldenBundleFile; "CURL_CA_BUNDLE" = $goldenBundleFile; "NODE_EXTRA_CA_CERTS" = $goldenBundleFile
        "GRPC_DEFAULT_SSL_ROOTS_FILE_PATH" = $goldenBundleFile; "GIT_SSL_CAINFO" = $goldenBundleFile; "CLOUDSDK_CORE_CUSTOM_CA_CERTS_FILE" = $goldenBundleFile
    }
    foreach ($key in $envVars.Keys) {
        $value = $envVars[$key]
        try {
            [System.Environment]::SetEnvironmentVariable($key, $value, [System.EnvironmentVariableTarget]::User)
            $env:$key = $value # Set for current session
            Write-Verbose "Set User Env Var: $key = $value"
        } 
        catch { Write-ErrorMsg "Failed to set environment variable '$key'. Please ensure you are running as Administrator." }
    }
    Write-Success "System environment variables have been set."

    Write-Styled -Message "Configuring Git, gcloud, and pip..." -ForegroundColor 'Yellow'
    try { git config --global http.sslcainfo $goldenBundleFile; Write-Success "Git config set." } catch { Write-Warning "Could not configure Git." }
    try { gcloud config set core/custom_ca_certs_file $goldenBundleFile; Write-Success "gcloud config set." } catch { Write-Warning "Could not configure gcloud." }
    try { pip config set global.cert $goldenBundleFile; Write-Success "pip config set." } catch { Write-Warning "Could not configure pip." }

    Write-Styled -Message "===========================================================" -ForegroundColor 'Cyan'
    Write-Styled -Message "  NCS Environment Configuration Complete!" -ForegroundColor 'Cyan'
    Write-Styled -Message "===========================================================" -ForegroundColor 'Cyan'
    Write-Warning "IMPORTANT: You must close and re-open your PowerShell/CMD terminal for all changes to take full effect."
}

# --- Script Entrypoint ---
Self-Update @PSBoundParameters
Check-Dependencies
Main
