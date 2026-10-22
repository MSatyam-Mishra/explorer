; Windows installer (Inno Setup 6), built by .github/workflows/desktop-release.yml:
;   ISCC /DAppVersion=1.0.6 /DAppDir=<flutter build output> /DRepoDir=<checkout>
;        /DOutputDir=<dir> /DOutputName=<file name without .exe> explorer.iss
;
; Installs for the current user (no admin prompt), in %LOCALAPPDATA%\Programs.
; Not in Program Files: web views (WebView2) keep their data next to the .exe
; and fail where the app can't write.

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif

[Setup]
; Never change AppId: Windows uses it to find earlier installs to upgrade.
AppId={{EAA7C0DF-E7B1-46D6-9B1E-DC41961AE3D9}
AppName=Explorer
AppVersion={#AppVersion}
AppVerName=Explorer {#AppVersion}
AppPublisher=MSatyam-Mishra
AppPublisherURL=https://github.com/MSatyam-Mishra/explorer
AppSupportURL=https://github.com/MSatyam-Mishra/explorer/issues
AppUpdatesURL=https://github.com/MSatyam-Mishra/explorer/releases
VersionInfoVersion={#AppVersion}
DefaultDirName={autopf}\Explorer
DefaultGroupName=Explorer
DisableProgramGroupPage=yes
LicenseFile={#RepoDir}\LICENSE
SetupIconFile={#RepoDir}\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\explorer.exe
UninstallDisplayName=Explorer
OutputDir={#OutputDir}
OutputBaseFilename={#OutputName}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.17763
PrivilegesRequired=lowest
CloseApplications=yes

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#AppDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\Explorer"; Filename: "{app}\explorer.exe"
Name: "{autodesktop}\Explorer"; Filename: "{app}\explorer.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\explorer.exe"; Description: "{cm:LaunchProgram,Explorer}"; Flags: nowait postinstall skipifsilent
