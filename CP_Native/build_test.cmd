@echo off
REM Harnais hors-ligne du coeur. Ne depend ni de REAPER ni du SDK.
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

REM /O2      optimisation vitesse
REM /std:c++17
REM /EHsc    exceptions C++ (le harnais en a besoin pour bad_alloc)
REM /GR-     pas de RTTI : on n'en a aucun usage et ca alourdit le binaire
REM /MT      CRT statique
REM PAS de /arch: ? la baseline x64 de MSVC est SSE2, ce qui est exactement la
REM cible. Un /arch:AVX rendrait le binaire inexecutable sur une machine
REM ancienne, avec un plantage au chargement et pas un message.
REM /wd4324  le remplissage par alignas(64) est VOULU : il separe les curseurs
REM          producteur et consommateur sur deux lignes de cache.
cl /nologo /std:c++17 /O2 /EHsc /GR- /MT /W4 /wd4324 /Zc:__cplusplus /Fo:build\ ^
   src\test\harness.cpp src\core\cp_engine.cpp src\core\cp_voice.cpp src\core\cp_pool.cpp src\core\cp_lanes.cpp ^
   /Fe:build\cp_test.exe
if errorlevel 1 exit /b 1
echo.
build\cp_test.exe
exit /b %errorlevel%
