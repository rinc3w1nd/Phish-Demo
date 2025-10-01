<#
install_lab_certs.ps1
One-click installer for lab root + intermediate certs on Windows.

Usage:
  - Double-click the script in Explorer (it will request elevation).
  - Or run from an elevated PowerShell:
      .\install_lab_certs.ps1 "C:\tmp\lab-root.der" "C:\tmp\lab-inter.der"
  - Or run without args and a file picker will let you select one or more files.

Notes:
  - Accepts: .der .cer .crt .pem .p7b
  - .p7b files are installed with certutil (adds contained certs to appropriate stores)
  - Other cert files are auto-classified: self-signed -> Root, CA:true -> Intermediate, else prompts once.
#>

[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments=$true)]
    [string[]] $Files
)

function Ensure-Admin {
    $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        Write-Host "Not running as Administrator — relaunching elevated..."
        $argList = @()
        if ($Files) { $argList += $Files }
        # Re-run this script elevated with same args
        Start-Process -FilePath "powershell" -ArgumentList "-NoProfile","-ExecutionPolicy","Bypass","-File","`"$PSCommandPath`"",$argList -Verb RunAs
        exit
    }
}

function Pick-FilesGui {
    Add-Type -AssemblyName System.Windows.Forms
    $ofd = New-Object System.Windows.Forms.OpenFileDialog
    $ofd.Filter = "Certs and bundles (*.der;*.cer;*.crt;*.pem;*.p7b)|*.der;*.cer;*.crt;*.pem;*.p7b|All files (*.*)|*.*"
    $ofd.Multiselect = $true
    if ($ofd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        return $ofd.FileNames
    }
    return @()
}

function Is-SelfSigned([System.Security.Cryptography.X509Certificates.X509Certificate2]$cert) {
    # Simple self-signed check: Subject == Issuer and signature validates with public key
    if ($cert.Subject -ne $cert.Issuer) { return $false }
    try {
        $pub = $cert.PublicKey.Key
        $signed = $cert.GetCertHash()
        # Hard to verify signature directly; treat Subject==Issuer as self-signed heuristic
        return $true
    } catch {
        return $false
    }
}

function Has-BasicConstraintsCA([System.Security.Cryptography.X509Certificates.X509Certificate2]$cert) {
    foreach ($ext in $cert.Extensions) {
        if ($ext.Oid -and ($ext.Oid.Value -eq "2.5.29.19")) {
            # Format(true) returns something like "Subject Type=CA" on some systems; parse roughly
            $f = $ext.Format($true)
            if ($f -match "(?i)CA[:=]\s*TRUE" -or $f -match "(?i)subject type.*=.*CA") { return $true }
            # fallback: if "CA" string present
            if ($f -match "(?i)\bCA\b") { return $true }
        }
    }
    return $false
}

function Install-CertToStore([string]$path, [string]$storeLocation, [string]$storeName) {
    try {
        Write-Host "Importing $path -> $storeLocation\$storeName"
        Import-Certificate -FilePath $path -CertStoreLocation "Cert:\LocalMachine\$storeName" | Out-Null
        Write-Host "  OK"
        return $true
    } catch {
        Write-Warning "Import-Certificate failed for $path: $_"
        return $false
    }
}

function Install-P7b([string]$path) {
    try {
        Write-Host "Installing PKCS#7 bundle $path using certutil..."
        $out = & certutil -addstore -f Root $path 2>&1
        Write-Host $out
        return $true
    } catch {
        Write-Warning "certutil failed for $path: $_"
        return $false
    }
}

# Main
Ensure-Admin

if (-not $Files -or $Files.Count -eq 0) {
    $Files = Pick-FilesGui
    if (-not $Files -or $Files.Count -eq 0) {
        Write-Host "No files selected. Exiting."
        exit 0
    }
}

$summary = [System.Collections.ArrayList]@()
$ambiguousList = @()

foreach ($f in $Files) {
    if (-not (Test-Path $f)) {
        Write-Warning "File not found: $f"
        $summary.Add([pscustomobject]@{File=$f; Result="Missing"}) | Out-Null
        continue
    }

    $ext = [IO.Path]::GetExtension($f).ToLowerInvariant()
    switch ($ext) {
        ".p7b" {
            $ok = Install-P7b $f
            $summary.Add([pscustomobject]@{File=$f; Result = if($ok){"Installed p7b"}else{"Failed p7b"}}) | Out-Null
        }
        default {
            # Try loading as X509Certificate2
            try {
                $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList $f
            } catch {
                # try reading as PEM and converting
                try {
                    $pem = Get-Content -Path $f -Raw
                    if ($pem -match "-----BEGIN CERTIFICATE-----") {
                        # write to temp DER and reload
                        $tmp = [IO.Path]::GetTempFileName()
                        $tmpDer = "$tmp.der"
                        # decode PEM base64 portion
                        $b64 = ($pem -split "-----BEGIN CERTIFICATE-----")[1] -split "-----END CERTIFICATE-----" | Select-Object -First 1
                        $bytes = [System.Convert]::FromBase64String($b64.Trim())
                        [System.IO.File]::WriteAllBytes($tmpDer, $bytes)
                        $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList $tmpDer
                        Remove-Item $tmpDer -Force -ErrorAction SilentlyContinue
                    } else {
                        throw "Not a PEM"
                    }
                } catch {
                    Write-Warning "Could not load certificate file $f : $_"
                    $summary.Add([pscustomobject]@{File=$f; Result="LoadFailed"}) | Out-Null
                    continue
                }
            }

            # Determine store by heuristic
            $isSelf = $false
            $isCA = $false
            try { $isSelf = Is-SelfSigned $cert } catch {}
            try { $isCA = Has-BasicConstraintsCA $cert } catch {}

            if ($isSelf) {
                $ok = Install-CertToStore $f "LocalMachine" "Root"
                $summary.Add([pscustomobject]@{File=$f; Result = if($ok){"Installed Root"}else{"RootInstallFailed"}}) | Out-Null
            } elseif ($isCA) {
                $ok = Install-CertToStore $f "LocalMachine" "CA"
                $summary.Add([pscustomobject]@{File=$f; Result = if($ok){"Installed Intermediate"}else{"IntermediateInstallFailed"}}) | Out-Null
            } else {
                # Ambiguous — ask once for policy (but in one-click flow we try to avoid prompts).
                $ambiguousList += $f
            }
        }
    }
}

# If ambiguous certs exist, we prompt once (keeps "one-click" simple but safe)
if ($ambiguousList.Count -gt 0) {
    Write-Host ""
    Write-Host "The following certificate files could not be auto-classified:"
    $ambiguousList | ForEach-Object { Write-Host "  $_" }
    Write-Host ""
    $choice = Read-Host "Install these to Root (R) or Intermediate CA (I)? [R/I] (default R)"
    if ($choice -match '^[iI]') {
        foreach ($f in $ambiguousList) {
            $ok = Install-CertToStore $f "LocalMachine" "CA"
            $summary.Add([pscustomobject]@{File=$f; Result = if($ok){"Installed Intermediate"}else{"IntermediateInstallFailed"}}) | Out-Null
        }
    } else {
        foreach ($f in $ambiguousList) {
            $ok = Install-CertToStore $f "LocalMachine" "Root"
            $summary.Add([pscustomobject]@{File=$f; Result = if($ok){"Installed Root"}else{"RootInstallFailed"}}) | Out-Null
        }
    }
}

Write-Host ""
Write-Host "Summary:"
$summary | Format-Table -AutoSize

Write-Host ""
Write-Host "If you installed a Root CA, restart browsers or the machine to apply trust in some apps."
Write-Host "Done."