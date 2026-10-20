# Publishes a Release build to %LOCALAPPDATA%\Programs\TeXLocal, adds it to the Start menu and to Open with for .tex and .zip.
$ErrorActionPreference = 'Stop'
$dir = Join-Path $env:LOCALAPPDATA 'Programs\TeXLocal'
$out = Join-Path ([IO.Path]::GetTempPath()) 'TeXLocal-publish'

if (Get-Process TeXLocal -ErrorAction SilentlyContinue) { throw 'Quit TeXLocal first.' }
if (Test-Path $out) { Remove-Item $out -Recurse -Force }
dotnet publish (Join-Path $PSScriptRoot 'TeXLocal\TeXLocal.csproj') -c Release -p:Platform=x64 -o $out
if ($LASTEXITCODE) { throw 'dotnet publish failed.' }

if (Test-Path $dir) { Remove-Item $dir -Recurse -Force }
Move-Item $out $dir

$exe = Join-Path $dir 'TeXLocal.exe'
$lnk = (New-Object -ComObject WScript.Shell).CreateShortcut(
    (Join-Path ([Environment]::GetFolderPath('Programs')) 'TeXLocal.lnk'))
$lnk.TargetPath = $exe
$lnk.WorkingDirectory = $dir
$lnk.Description = 'Underleaf, an offline LaTeX editor'
$lnk.Save()

# Open with for .tex and .zip, this user's, leaving each type's default app as it is. CreateSubKey opens a key that
# exists, where PowerShell's New-Item -Force would empty it.
$classes = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Software\Classes')
$classes.CreateSubKey('TeXLocal.Document\DefaultIcon').SetValue('', "`"$exe`",0")
$classes.CreateSubKey('TeXLocal.Document\shell\open\command').SetValue('', "`"$exe`" `"%1`"")
foreach ($type in '.tex', '.zip') { $classes.CreateSubKey("$type\OpenWithProgids").SetValue('TeXLocal.Document', '') }
"Installed to $dir"
