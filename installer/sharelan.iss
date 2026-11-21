[Setup]
AppName=ShareLAN
AppVersion=1.1.0
DefaultDirName={autopf}\ShareLAN
DefaultGroupName=ShareLAN
OutputDir=..\installer_out
OutputBaseFilename=ShareLAN-Setup
Compression=lzma
SolidCompression=yes
ArchitecturesInstallIn64BitMode=x64compatible
DisableProgramGroupPage=yes

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"

[Files]
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: recursesubdirs ignoreversion

[Icons]
Name: "{group}\ShareLAN"; Filename: "{app}\sharelan.exe"
Name: "{autodesktop}\ShareLAN"; Filename: "{app}\sharelan.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\sharelan.exe"; Description: "Launch ShareLAN"; Flags: nowait postinstall skipifsilent
