# CMake des le premier jour — pour que le portage macOS/Linux ne soit pas une
# reecriture. La construction quotidienne sur Windows passe par build_dll.cmd
# (cl.exe direct) parce que CMake n'est pas installe sur la machine de dev ;
# les deux doivent produire le meme binaire.
cmake_minimum_required(VERSION 3.21)   # CMP0091 : MSVC_RUNTIME_LIBRARY

project(CP_Native VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

set(REAPER_SDK "${CMAKE_CURRENT_SOURCE_DIR}/../reaper-sdk/sdk"
    CACHE PATH "Chemin vers reaper-sdk/sdk")

# --- le coeur : aucune dependance, testable hors REAPER ---------------------
add_library(cp_core STATIC
  src/core/cp_engine.cpp
  src/core/cp_voice.cpp
  src/core/cp_pool.cpp)
target_include_directories(cp_core PUBLIC src/core)

# --- le harnais hors-ligne --------------------------------------------------
add_executable(cp_test src/test/harness.cpp)
target_link_libraries(cp_test PRIVATE cp_core)

enable_testing()
add_test(NAME coeur COMMAND cp_test)

# --- l'extension ------------------------------------------------------------
add_library(reaper_cpclip SHARED
  src/host/cp_main.cpp
  src/host/cp_source.cpp)
target_link_libraries(reaper_cpclip PRIVATE cp_core)
target_include_directories(reaper_cpclip PRIVATE "${REAPER_SDK}")
set_target_properties(reaper_cpclip PROPERTIES PREFIX "" OUTPUT_NAME "reaper_cpclip")

if(MSVC)
  # CRT statique : la DLL atterrit sur des machines sans redistribuable VC++.
  set_property(TARGET cp_core cp_test reaper_cpclip
               PROPERTY MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
  # /GR- pas de RTTI. AUCUN /arch: — la baseline x64 de MSVC est SSE2, ce qui
  # est exactement la cible ; /arch:AVX rendrait le binaire inexecutable sur une
  # machine ancienne, avec un plantage au chargement et pas un message.
  target_compile_options(cp_core PRIVATE /W4 /wd4324 /GR- /Zc:__cplusplus)
  target_compile_options(reaper_cpclip PRIVATE /W4 /wd4324 /GR- /Zc:__cplusplus)
  target_compile_options(cp_test PRIVATE /W4 /wd4324 /Zc:__cplusplus)
else()
  target_compile_options(cp_core PRIVATE -Wall -Wextra -fno-rtti)
  target_compile_options(reaper_cpclip PRIVATE -Wall -Wextra -fno-rtti)
endif()

if(APPLE)
  set_target_properties(reaper_cpclip PROPERTIES SUFFIX ".dylib")
elseif(UNIX)
  set_target_properties(reaper_cpclip PROPERTIES SUFFIX ".so")
endif()
