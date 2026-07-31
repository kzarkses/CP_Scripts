@echo off
REM reaper_cpclip.dll ? l'extension REAPER.
setlocal
call "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat" >nul 2>&1
cd /d "%~dp0"
if not exist build mkdir build

set SDK=C:\Users\Cedric\dev\reaper-sdk\sdk

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
dir /b build\reaper_cpclip.dll
exit /b 0
