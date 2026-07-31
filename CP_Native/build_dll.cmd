@echo off
REM reaper_cpclip.dll ? l'extension REAPER.
setlocal
call "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat" >nul 2>&1
cd /d "%~dp0"
if not exist build mkdir build

REM Le SDK reste HORS du depot : c'est une dependance fournisseur, pas notre
REM code, et sa licence n'est pas la notre. Surchargeable pour qui le range
REM ailleurs.
REM   git clone --depth 1 https://github.com/justinfrankel/reaper-sdk.git
if not defined REAPER_SDK set REAPER_SDK=C:\Users\Cedric\dev\reaper-sdk\sdk
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
cl /nologo /std:c++17 /O2 /Oi /Gy /EHsc /GR- /MT /W4 /wd4324 /Zc:__cplusplus ^
   /external:I "%SDK%" /external:W0 ^
   /I "%SDK%" /Fo:build\ /Fd:build\ ^
   src\host\cp_main.cpp src\host\cp_source.cpp ^
   src\core\cp_engine.cpp src\core\cp_voice.cpp src\core\cp_pool.cpp ^
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
