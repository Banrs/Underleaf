; The Windows installer: Inno Setup 6, per user and without admin rights, into
; %LOCALAPPDATA%\Programs\TeXLocal with a Start-menu shortcut. Build it from
; a Release publish (see HANDOFF.md) with
;   iscc /DSource=<publish folder> /DAppVersion=<version> apps\windows\installer\TeXLocal.iss
; Projects (~\TeXLocal) and settings (%LOCALAPPDATA%\TeXLocal) are the user's
; and stay when the app is uninstalled.

#ifndef Source
  #define Source "..\..\..\release\windows"
#endif
#ifndef AppVersion
  #define AppVersion "0.2.0"
#endif

[Setup]
AppId={{6E0B5D2A-3F49-4C1E-9A57-1D8C2B7E4F30}
AppName=TeXLocal
AppVersion={#AppVersion}
AppPublisher=TeXLocal
DefaultDirName={localappdata}\Programs\TeXLocal
DisableDirPage=yes
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.17763
UninstallDisplayIcon={app}\TeXLocal.exe
SetupIconFile=..\TeXLocal\Assets\TeXLocal.ico
OutputDir={#Source}\..
OutputBaseFilename=TeXLocal-{#AppVersion}-setup
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes

[Files]
Source: "{#Source}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[InstallDelete]
; An update replaces the whole app, so files a newer version dropped don't linger.
Type: filesandordirs; Name: "{app}\*"

[Icons]
Name: "{userprograms}\TeXLocal"; Filename: "{app}\TeXLocal.exe"

[Run]
Filename: "{app}\TeXLocal.exe"; Description: "Open TeXLocal"; Flags: nowait postinstall skipifsilent
