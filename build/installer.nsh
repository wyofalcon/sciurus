!macro customInstall
  ; Install Visual C++ Redistributable silently (required for better-sqlite3)
  File /oname=$PLUGINSDIR\vc_redist.x64.exe "${BUILD_RESOURCES_DIR}\vc_redist.x64.exe"
  ExecWait '"$PLUGINSDIR\vc_redist.x64.exe" /quiet /norestart'
!macroend
