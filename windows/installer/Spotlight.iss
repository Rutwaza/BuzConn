#define AppName "SpotLight"
#define AppVersion "1.0.0"
#define AppPublisher "BuzConn"
#define AppId "{{D926593C-9EBD-4E8B-A6DD-4905854EE387}"
#define PayloadDir "..\..\build\windows\x64\installer-payload"

[Setup]
AppId={#AppId}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppPublisher}
DefaultDirName={localappdata}\Programs\Spotlight
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64
ArchitecturesInstallIn64BitMode=x64
OutputDir=..\..\build\windows\installer-output
OutputBaseFilename=SpotLight-Setup-{#AppVersion}-x64
SetupIconFile=..\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\SpotLight.exe
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Additional shortcuts:"; Flags: unchecked

[Files]
Source: "{#PayloadDir}\SpotLight.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#PayloadDir}\*.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#PayloadDir}\data\*"; DestDir: "{app}\data"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\SpotLight"; Filename: "{app}\SpotLight.exe"
Name: "{autodesktop}\SpotLight"; Filename: "{app}\SpotLight.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\SpotLight.exe"; Description: "Launch Spotlight"; Flags: nowait postinstall skipifsilent
