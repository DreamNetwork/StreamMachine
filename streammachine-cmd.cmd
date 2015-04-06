@IF EXIST "%~dp0\node.exe" (
  "%~dp0\node.exe" "%~dp0\streammachine-cmd" %*
) ELSE @IF EXIST "%~dp0\node_modules\bin\node.exe" (
  "%~dp0\node_modules\bin\node.exe" "%~dp0\streammachine-cmd" %*
) ELSE (
  @SETLOCAL
  @SET PATHEXT=%PATHEXT:;.JS;=;%
  node "%~dp0\streammachine-cmd" %*
)