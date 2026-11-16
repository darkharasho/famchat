; Inno Setup script for the FamChat Windows installer (release.yml builds and signs it).
;   iscc /DAppVersion=1.2.3 app\windows\installer\famchat.iss
; Packs build\windows\x64\runner\Release (the signed `flutter build windows` output).
; Installs per user by default (no admin prompt); the dialog offers an all-users install.

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif

[Setup]
; Never change AppId: Windows uses it to find the installed app for upgrades and uninstall.
AppId={{B8E6E859-0026-4A2F-98B9-5182458BCF6E}
AppName=FamChat
AppVersion={#AppVersion}
AppVerName=FamChat {#AppVersion}
AppPublisher=Michael Stephens
AppPublisherURL=https://famchat.dev
DefaultDirName={autopf}\FamChat
DefaultGroupName=FamChat
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=..\..\build\windows\installer
OutputBaseFilename=FamChat-{#AppVersion}-windows-x64-setup
SetupIconFile=..\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\famchat.exe
UninstallDisplayName=FamChat
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "..\..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\FamChat"; Filename: "{app}\famchat.exe"
Name: "{autodesktop}\FamChat"; Filename: "{app}\famchat.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\famchat.exe"; Description: "{cm:LaunchProgram,FamChat}"; Flags: nowait postinstall skipifsilent
