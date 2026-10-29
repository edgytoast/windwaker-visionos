# Apple Vision Pro: the game as WindWakerVisionGame.framework, which the SwiftUI app
# (visionos/App) embeds. Included from native/CMakeLists.txt after executable.cmake when
# CMAKE_SYSTEM_NAME is visionOS (visionos/scripts/build-visionos.sh configures it).
#
# - The same objects as the switchwaker executable (executable.cmake's response file, in its order:
#   main.dol units, REL units, audio), plus cos_pc, cos_sdk, Aurora and the visionOS host
#   (visionos/host); not aurora::main: SwiftUI owns main(), and the host runs the game's
#   aurora_main on a thread of its own.
# - Exports ONLY the C bridge (visionos/exports.txt): the game's replacement operator new/delete
#   must stay inside the framework, or dyld makes them process-wide and SwiftUI allocates through
#   them (crashes on the device; the plugin's footgun catalogue, C).
#
# Two allocators inside the framework. The game replaces the global operator new/delete with its
# JKRHeap (native/src/pc/game_hooks/pc_jkr_heap.cpp). On the Mac the executable's replacement is
# process-wide, libc++.dylib included. Hidden in a framework, it isn't: inline libc++ code in the
# framework allocated a std::string in the game's heap and libc++.dylib's out-of-line string code
# freed it with the system's free() (an abort in PADInit at boot, Simulator 2026-10-08). So:
# - The game's own domain: its units and cos_pc (the PC layer, which builds game objects and was
#   written against the game's heap) are linked first into ONE relocatable object (ld -r,
#   wwvr_game.o). The object keeps the game's operator new/delete and the std template instances
#   it made to itself (visionos/cmake/game_private.txt makes them local, and localize-std.sh the
#   weak ones -unexported_symbols_list leaves external), so the game allocates
#   exactly as on the Mac. The SDK's <string> declares std::string's out-of-line members `extern
#   template` (there is no switch to turn that off any more), so visionos/game/
#   wwvr_libcxx_instances.cpp instantiates them in the object too, against the game's operators,
#   instead of cos_pc calling libc++.dylib's copies (the game's units use no libc++ at all).
# - Everything else in the framework (cos_sdk, Aurora, Dawn, SDL, the DSP and the visionOS host)
#   uses visionos/host/wwvr_host_alloc.cpp: new is malloc, as libc++.dylib's, and delete hands a
#   block the game's heap owns back to it (wwvr_game_delete), so a block may cross either way.
#   This also takes Aurora's and the SDK's allocations inside the game's GX/PAD calls out of the
#   game's heaps (SwitchWaker's TODO in pc_jkr_heap.cpp).
include_guard(GLOBAL)

if (NOT TARGET cos_sdk OR NOT DEFINED _exe_rsp)
    message(STATUS "wwvr: WindWakerVisionGame.framework disabled (needs cos_sdk and every module)")
    return()
endif ()

set(WWVR_VISIONOS_DIR "${COS_NATIVE_ROOT}/../visionos")
get_filename_component(WWVR_VISIONOS_DIR "${WWVR_VISIONOS_DIR}" ABSOLUTE)
set(WWVR_HOST_DIR "${WWVR_VISIONOS_DIR}/host")

# The OpenXR provider (visionos/openxr-provider, GPL-3.0-or-later, from TPVR): OpenXR's entry points
# over CompositorServices and ARKit, linked in place of a loader. Only the Khronos headers are
# needed, at the release the provider is built against.
include(FetchContent)
FetchContent_Declare(openxr_headers
        URL https://github.com/KhronosGroup/OpenXR-SDK/archive/refs/tags/release-1.1.61.tar.gz
        URL_HASH SHA256=d5e2773d282642e6e250bd10266f316fc3ff3b8602c83db009a1f434205998e6
        DOWNLOAD_EXTRACT_TIMESTAMP TRUE
        SOURCE_SUBDIR include-only-no-cmake) # no such directory: the SDK's own CMake is never added
FetchContent_MakeAvailable(openxr_headers)
set(WWVR_XR_PROVIDER_DIR "${WWVR_VISIONOS_DIR}/openxr-provider")
add_library(wwvr_openxr_provider STATIC
        "${WWVR_XR_PROVIDER_DIR}/src/xr_visionos_runtime.mm"
        "${WWVR_XR_PROVIDER_DIR}/src/xr_visionos_input.mm"
        "${WWVR_XR_PROVIDER_DIR}/src/xr_visionos_hand_tracking.mm"
        "${WWVR_XR_PROVIDER_DIR}/src/xr_visionos_compositor.mm"
        "${WWVR_XR_PROVIDER_DIR}/src/xr_visionos_controllers.mm"
        "${WWVR_XR_PROVIDER_DIR}/src/xr_visionos_smaa.mm")
target_include_directories(wwvr_openxr_provider PUBLIC "${WWVR_XR_PROVIDER_DIR}/include")
target_include_directories(wwvr_openxr_provider SYSTEM PUBLIC "${openxr_headers_SOURCE_DIR}/include")
target_compile_features(wwvr_openxr_provider PUBLIC cxx_std_20)
target_compile_options(wwvr_openxr_provider PRIVATE -fobjc-arc -w)

# The game's side of the visionOS port: code that reads or drives the game (its camera, player
# and pads for VR), so it allocates and links like cos_pc. Compiled like a game unit.
file(GLOB WWVR_GAME_SIDE_SOURCES CONFIGURE_DEPENDS "${WWVR_VISIONOS_DIR}/game/*.cpp")
add_library(wwvr_game_side STATIC ${WWVR_GAME_SIDE_SOURCES})
target_link_libraries(wwvr_game_side PRIVATE cos_game_headers)
target_include_directories(wwvr_game_side PRIVATE "${WWVR_HOST_DIR}" "${WWVR_VISIONOS_DIR}/game"
        "${COS_NATIVE_ROOT}/src/pc" "${COS_NATIVE_ROOT}/sdk/include" "${aurora_SOURCE_DIR}/include"
        "$<TARGET_PROPERTY:dawn::webgpu_dawn,INTERFACE_INCLUDE_DIRECTORIES>")

# The clang target and SDK path the ld -r step links for (the game's units are compiled with the
# same --target).
if (CMAKE_OSX_SYSROOT MATCHES "^/")
    set(WWVR_SDK_PATH "${CMAKE_OSX_SYSROOT}")
else ()
    execute_process(COMMAND xcrun --sdk "${CMAKE_OSX_SYSROOT}" --show-sdk-path
            OUTPUT_VARIABLE WWVR_SDK_PATH OUTPUT_STRIP_TRAILING_WHITESPACE COMMAND_ERROR_IS_FATAL ANY)
endif ()
if (WWVR_SDK_PATH MATCHES "XRSimulator")
    set(WWVR_LINK_TARGET "arm64-apple-xros${CMAKE_OSX_DEPLOYMENT_TARGET}-simulator")
else ()
    set(WWVR_LINK_TARGET "arm64-apple-xros${CMAKE_OSX_DEPLOYMENT_TARGET}")
endif ()

# The game's domain in one relocatable object (see above). Inputs in the executable's order (the
# REL units after main.dol for their static initialisers), then cos_pc and the game side whole.
set(WWVR_GAME_OBJECT "${CMAKE_BINARY_DIR}/wwvr_game.o")
set(WWVR_GAME_PRIVATE "${WWVR_VISIONOS_DIR}/cmake/game_private.txt")
set(_wwvr_game_objects)
foreach (_m IN LISTS COS_MODULES)
    list(APPEND _wwvr_game_objects "$<TARGET_OBJECTS:${_m}>")
endforeach ()
add_custom_command(
        OUTPUT "${WWVR_GAME_OBJECT}"
        COMMAND "${CMAKE_CXX_COMPILER}" -r -nostdlib "--target=${WWVR_LINK_TARGET}" -isysroot "${WWVR_SDK_PATH}"
                "@${_exe_rsp}"
                "-Wl,-force_load,$<TARGET_FILE:cos_pc>"
                "-Wl,-force_load,$<TARGET_FILE:wwvr_game_side>"
                "-Wl,-unexported_symbols_list,${WWVR_GAME_PRIVATE}"
                -o "${WWVR_GAME_OBJECT}"
        # The weak std instances ld -r leaves external ("automatically hidden"): local too.
        COMMAND "${WWVR_VISIONOS_DIR}/cmake/localize-std.sh" "${WWVR_GAME_OBJECT}"
        DEPENDS ${COS_MODULES} cos_pc wwvr_game_side "${_exe_rsp}" "${WWVR_GAME_PRIVATE}" ${_wwvr_game_objects}
                "${WWVR_VISIONOS_DIR}/cmake/localize-std.sh"
        COMMENT "Linking the game and cos_pc into one object (their operator new stays their own)"
        VERBATIM)
add_custom_target(wwvr_game_object DEPENDS "${WWVR_GAME_OBJECT}")
set_source_files_properties("${WWVR_GAME_OBJECT}" PROPERTIES EXTERNAL_OBJECT TRUE GENERATED TRUE)

add_library(WindWakerVisionGame SHARED
        "${WWVR_HOST_DIR}/game_host.mm"
        "${WWVR_HOST_DIR}/sense_pad.mm"
        "${WWVR_HOST_DIR}/wwvr_window.cpp"
        "${WWVR_HOST_DIR}/wwvr_xr.mm"
        "${WWVR_HOST_DIR}/wwvr_host_alloc.cpp"
        "${WWVR_GAME_OBJECT}")
add_dependencies(WindWakerVisionGame wwvr_game_object)
target_include_directories(WindWakerVisionGame PRIVATE "${WWVR_HOST_DIR}"
        "$<TARGET_PROPERTY:dawn::webgpu_dawn,INTERFACE_INCLUDE_DIRECTORIES>")
# Aurora's internal headers are not needed: the host uses its public API (aurora/gfx.hpp, mirror.h).
set_source_files_properties("${WWVR_HOST_DIR}/game_host.mm" "${WWVR_HOST_DIR}/sense_pad.mm"
        "${WWVR_HOST_DIR}/wwvr_xr.mm" PROPERTIES COMPILE_OPTIONS "-fobjc-arc")
target_compile_features(WindWakerVisionGame PRIVATE cxx_std_20)
target_link_libraries(WindWakerVisionGame PRIVATE cos_sdk wwvr_openxr_provider)
if (DEFINED AURORA_SDL3_TARGET AND TARGET ${AURORA_SDL3_TARGET})
    target_link_libraries(WindWakerVisionGame PRIVATE ${AURORA_SDL3_TARGET})
endif ()
foreach (_framework UIKit Foundation Metal QuartzCore IOSurface GameController CoreHaptics AVFoundation
        AudioToolbox CoreAudio CoreMotion CoreGraphics CompositorServices ARKit)
    target_link_libraries(WindWakerVisionGame PRIVATE "-framework ${_framework}")
endforeach ()
target_link_options(WindWakerVisionGame PRIVATE
        "LINKER:-exported_symbols_list,${WWVR_VISIONOS_DIR}/exports.txt")
set_target_properties(WindWakerVisionGame PROPERTIES
        FRAMEWORK TRUE
        MACOSX_FRAMEWORK_IDENTIFIER "dev.windwakervr.vision.game"
        MACOSX_FRAMEWORK_BUNDLE_VERSION "1"
        MACOSX_FRAMEWORK_SHORT_VERSION_STRING "0.1"
        OUTPUT_NAME WindWakerVisionGame
        INSTALL_NAME_DIR "@rpath"
        LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}"
        LINKER_LANGUAGE CXX
        LINK_DEPENDS "${WWVR_GAME_OBJECT};${WWVR_VISIONOS_DIR}/exports.txt")
message(STATUS "wwvr: WindWakerVisionGame.framework (the game for Apple Vision Pro)")
