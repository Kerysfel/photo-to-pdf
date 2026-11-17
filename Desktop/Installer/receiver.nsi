Unicode True
!include "MUI2.nsh"

!ifndef PUBLISH_DIR
  !error "Set PUBLISH_DIR to the Windows publish directory"
!endif
!ifndef OUTPUT_FILE
  !error "Set OUTPUT_FILE to the installer path"
!endif

!ifndef ICON_FILE
  !error "Set ICON_FILE to the application ICO file"
!endif

Icon "${ICON_FILE}"
UninstallIcon "${ICON_FILE}"
!define MUI_ICON "${ICON_FILE}"
!define MUI_UNICON "${ICON_FILE}"

Name "Фото в PDF — приёмник"
OutFile "${OUTPUT_FILE}"
InstallDir "$LOCALAPPDATA\Programs\PhotoToPDF Receiver"
InstallDirRegKey HKCU "Software\PhotoToPDF\Receiver" "InstallDir"
RequestExecutionLevel user
SetCompressor /SOLID lzma

!define MUI_ABORTWARNING
!define MUI_FINISHPAGE_RUN "$INSTDIR\PhotoToPdf.Receiver.exe"
!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "Russian"

Section "Приёмник" SEC_MAIN
  SetShellVarContext current
  SetOutPath "$INSTDIR"
  File "${PUBLISH_DIR}/PhotoToPdf.Receiver.exe"
  File "${PUBLISH_DIR}/av_libglesv2.dll"
  File "${PUBLISH_DIR}/libHarfBuzzSharp.dll"
  File "${PUBLISH_DIR}/libSkiaSharp.dll"
  WriteUninstaller "$INSTDIR\Uninstall.exe"
  CreateDirectory "$SMPROGRAMS\Фото в PDF"
  CreateShortcut "$SMPROGRAMS\Фото в PDF\Приёмник.lnk" "$INSTDIR\PhotoToPdf.Receiver.exe"
  CreateShortcut "$DESKTOP\Фото в PDF — приёмник.lnk" "$INSTDIR\PhotoToPdf.Receiver.exe"
  WriteRegStr HKCU "Software\PhotoToPDF\Receiver" "InstallDir" "$INSTDIR"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\PhotoToPDFReceiver" "DisplayName" "Фото в PDF — приёмник"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\PhotoToPDFReceiver" "DisplayVersion" "0.1.3"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\PhotoToPDFReceiver" "UninstallString" '"$INSTDIR\Uninstall.exe"'
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\PhotoToPDFReceiver" "NoModify" 1
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\PhotoToPDFReceiver" "NoRepair" 1
SectionEnd

Section "Uninstall"
  SetShellVarContext current
  Delete "$SMPROGRAMS\Фото в PDF\Приёмник.lnk"
  Delete "$DESKTOP\Фото в PDF — приёмник.lnk"
  RMDir "$SMPROGRAMS\Фото в PDF"
  Delete "$INSTDIR\PhotoToPdf.Receiver.exe"
  Delete "$INSTDIR\av_libglesv2.dll"
  Delete "$INSTDIR\libHarfBuzzSharp.dll"
  Delete "$INSTDIR\libSkiaSharp.dll"
  Delete "$INSTDIR\Uninstall.exe"
  RMDir "$INSTDIR"
  DeleteRegKey HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\PhotoToPDFReceiver"
  DeleteRegKey HKCU "Software\PhotoToPDF\Receiver"
SectionEnd
