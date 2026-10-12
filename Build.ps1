$ErrorActionPreference = 'Stop'

$module = Get-Module -ListAvailable -Name ps2exe |
    Sort-Object Version -Descending |
    Select-Object -First 1

if (-not $module) {
    throw 'Не найден модуль ps2exe. Сначала выполните: Install-Module ps2exe -Scope CurrentUser'
}

Import-Module $module.Path -Force

$source = Join-Path $PSScriptRoot 'Cleaner.ps1'
$output = Join-Path $PSScriptRoot 'Чистка-компьютера.exe'

Invoke-PS2EXE `
    -inputFile $source `
    -outputFile $output `
    -x64 `
    -STA `
    -noConsole `
    -noConfigFile `
    -title 'Чистка компьютера' `
    -description 'Менеджер программ и очистка диска для Windows' `
    -product 'Чистка компьютера' `
    -version '1.0.0.0'
