@echo off
REM reaper_cpclip.dll ? l'extension REAPER.
setlocal
REM TROUVER VISUAL STUDIO PLUTOT QUE LE SUPPOSER. Le chemin en dur ne vaut
REM que pour une edition Community 2022 installee par defaut : sur une autre
REM machine (Professional, Build Tools, disque D:) il echoue en silence, et
REM l'erreur qu'on voit ensuite est "cl introuvable", qui ne dit pas pourquoi.
REM vswhere est livre AVEC Visual Studio depuis 2017 et vit toujours au meme
REM endroit.
set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
set "VCVARS="
if exist "%VSWHERE%" (
  for /f "usebackq delims=" %%i in (`"%VSWHERE%" -latest -products * ^
      -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 ^
      -property installationPath`) do set "VCVARS=%%i\VC\Auxiliary\Build\vcvars64.bat"
)
if not defined VCVARS set "VCVARS=%ProgramFiles%\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat"
if not exist "%VCVARS%" (
  echo.
  echo   Visual Studio introuvable.
  echo   Installe "Desktop development with C++" ^(VS 2022 ou Build Tools^).
  exit /b 5
)
call "%VCVARS%" >nul 2>&1
cd /d "%~dp0"
if not exist build mkdir build

REM Le SDK reste HORS du depot : c'est une dependance fournisseur, pas notre
REM code, et sa licence n'est pas la notre. Surchargeable pour qui le range
REM ailleurs.
REM   git clone --depth 1 https://github.com/justinfrankel/reaper-sdk.git
REM Trois endroits conventionnels avant d'abandonner, pour qu'un clone frais
REM sur une autre machine construise sans qu'on ait rien a regler :
REM   1. REAPER_SDK, s'il est pose (il gagne toujours)
REM   2. a cote du depot     ..\..\reaper-sdk\sdk
REM   3. %USERPROFILE%\dev\reaper-sdk\sdk
if not defined REAPER_SDK (
  if exist "%~dp0..\..\reaper-sdk\sdk\reaper_plugin.h" (
    set "REAPER_SDK=%~dp0..\..\reaper-sdk\sdk"
  ) else (
    set "REAPER_SDK=%USERPROFILE%\dev\reaper-sdk\sdk"
  )
)
set SDK=%REAPER_SDK%
if not exist "%SDK%\reaper_plugin.h" (
  echo.
  echo   SDK introuvable : %SDK%
  echo   Clone https://github.com/justinfrankel/reaper-sdk puis pose
  echo   REAPER_SDK sur son sous-dossier sdk.
  exit /b 3
)

REM /LD      DLL
REM /MT      CRT statique : la DLL atterrit sur des machines sans redistribuable
REM /EHsc    exceptions ON, avec un catch(...) a chaque frontiere exportee
REM /GR-     pas de RTTI
REM PAS de /arch: ? baseline x64 = SSE2, ce qui est exactement la cible.
REM /external:  les en-tetes du SDK sont bruyants en /W4 et ce n'est pas notre
REM             code. On les traite en W0 au lieu de baisser notre propre garde.
REM Les defstrings ReaScript avant toute chose : une chaine mal formee
REM compile parfaitement et se fait refuser au CHARGEMENT de REAPER, avec un
REM message qui ne dit ni ou ni pourquoi. Deux secondes de python valent mieux
REM que sept boites de dialogue au demarrage.
where python >nul 2>&1
if not errorlevel 1 (
  python tools\check_defs.py
  if errorlevel 1 exit /b 4
)

cl /nologo /std:c++17 /O2 /Oi /Gy /EHsc /GR- /MT /W4 /wd4324 /Zc:__cplusplus ^
   /external:I "%SDK%" /external:W0 ^
   /I "%SDK%" /Fo:build\ /Fd:build\ ^
   src\host\cp_main.cpp src\host\cp_source.cpp ^
   src\core\cp_engine.cpp src\core\cp_voice.cpp src\core\cp_pool.cpp src\core\cp_lanes.cpp ^
   /LD /Fe:build\reaper_cpclip.dll ^
   /link /OPT:REF /OPT:ICF
if errorlevel 1 exit /b 1
echo.
echo === construit : build\reaper_cpclip.dll ===

REM Les sondes Lua, elles, se remplacent a chaud : REAPER ne les verrouille pas.
copy /Y lua\*.lua "%APPDATA%\REAPER\Scripts\CP_Scripts\WIP\" >nul 2>&1

REM La DLL, non. REAPER la tient ouverte tant qu'il tourne, et aucune extension
REM ne se recharge a chaud : c'est la nature du format, pas un defaut de montage.
tasklist /FI "IMAGENAME eq reaper.exe" 2>nul | find /I "reaper.exe" >nul
if not errorlevel 1 (
  echo.
  echo   REAPER TOURNE : la DLL n'a PAS ete installee.
  echo   Ferme REAPER et relance ce script.
  exit /b 2
)
copy /Y build\reaper_cpclip.dll "%APPDATA%\REAPER\UserPlugins\" >nul
if errorlevel 1 exit /b 1
echo   installee dans UserPlugins — redemarre REAPER.
exit /b 0
