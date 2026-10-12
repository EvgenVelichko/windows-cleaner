$ErrorActionPreference = 'Stop'

$module = Get-Module -ListAvailable -Name ps2exe |
    Sort-Object Version -Descending |
    Select-Object -First 1

if (-not $module) {
    throw 'The ps2exe module was not found. Run: Install-Module ps2exe -Scope CurrentUser'
}

Import-Module $module.Path -Force

$source = Join-Path $PSScriptRoot 'WindowsCleaner.ps1'
$output = Join-Path $PSScriptRoot 'WindowsCleaner.exe'

Invoke-PS2EXE `
    -inputFile $source `
    -outputFile $output `
    -x64 `
    -STA `
    -noConsole `
    -noConfigFile `
    -title 'Windows Cleaner' `
    -description 'Installed app manager and disk cleanup for Windows' `
    -product 'Windows Cleaner' `
    -version '1.0.0.0'
