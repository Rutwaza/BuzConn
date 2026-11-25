#define AppName "Duhuze"
; AppVersion comes from pubspec.yaml (build_installer.ps1 passes /DAppVersion=...).
#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif
#define AppPublisher "DUHUZE TECHS"
#define AppId "{{D926593C-9EBD-4E8B-A6DD-4905854EE387}"
#define PayloadDir "..\..\build\windows\x64\installer-payload"

[Setup]
AppId={#AppId}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppPublisher}
DefaultDirName={localappdata}\Programs\Duhuze
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64
ArchitecturesInstallIn64BitMode=x64
OutputDir=..\..\build\windows\installer-output
OutputBaseFilename=Duhuze-Setup-{#AppVersion}-x64
SetupIconFile=..\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\Duhuze.exe
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Additional shortcuts:"; Flags: unchecked

[Files]
Source: "{#PayloadDir}\Duhuze.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#PayloadDir}\*.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#PayloadDir}\data\*"; DestDir: "{app}\data"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\Duhuze"; Filename: "{app}\Duhuze.exe"; AppUserModelID: "BuzConn.Duhuze"
Name: "{autodesktop}\Duhuze"; Filename: "{app}\Duhuze.exe"; Tasks: desktopicon; AppUserModelID: "BuzConn.Duhuze"

[Run]
Filename: "{app}\Duhuze.exe"; Description: "Launch Duhuze"; Flags: nowait postinstall skipifsilent
