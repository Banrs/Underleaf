# Publishes a Release build to %LOCALAPPDATA%\Programs\TeXLocal and adds it to the Start menu.
$ErrorActionPreference = 'Stop'
$dir = Join-Path $env:LOCALAPPDATA 'Programs\TeXLocal'
$out = Join-Path ([IO.Path]::GetTempPath()) 'TeXLocal-publish'

if (Get-Process TeXLocal -ErrorAction SilentlyContinue) { throw 'Quit TeXLocal first.' }
if (Test-Path $out) { Remove-Item $out -Recurse -Force }
dotnet publish (Join-Path $PSScriptRoot 'TeXLocal\TeXLocal.csproj') -c Release -p:Platform=x64 -o $out
if ($LASTEXITCODE) { throw 'dotnet publish failed.' }

if (Test-Path $dir) { Remove-Item $dir -Recurse -Force }
Move-Item $out $dir

$lnk = (New-Object -ComObject WScript.Shell).CreateShortcut(
    (Join-Path ([Environment]::GetFolderPath('Programs')) 'TeXLocal.lnk'))
$lnk.TargetPath = Join-Path $dir 'TeXLocal.exe'
$lnk.WorkingDirectory = $dir
$lnk.Description = 'Underleaf, an offline LaTeX editor'
$lnk.Save()
"Installed to $dir"
