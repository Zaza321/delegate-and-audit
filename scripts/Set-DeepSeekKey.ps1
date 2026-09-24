#requires -Version 7.0
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$targetDirectory = Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'delegate-and-audit'
$target = Join-Path $targetDirectory 'deepseek-key.dpapi'
[void](New-Item -ItemType Directory -Path $targetDirectory -Force)
$key = Read-Host -AsSecureString 'DeepSeek API key'
if ($key.Length -eq 0) { throw 'Boş anahtar kaydedilmedi.' }
$protected = ConvertFrom-SecureString -SecureString $key
[System.IO.File]::WriteAllText($target, $protected, [System.Text.UTF8Encoding]::new($false))
Write-Output 'DeepSeek anahtarı Windows kullanıcı hesabına bağlı şifreli depoya kaydedildi.'
