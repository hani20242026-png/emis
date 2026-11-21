# This file controls compiler building configurations.
# Edit this file to change additional build settings for your plugin dependencies.
# This is part of the managed Flutter build system.

cmake_minimum_required(VERSION 3.14)

set(EPHEMERAL_DIR "${CMAKE_CURRENT_SOURCE_DIR}/ephemeral")

# Configuration provided via flutter.
include("${EPHEMERAL_DIR}/generated_config.cmake")

# TODO: Move the flutter tool portions to the runner CMakeLists.txt file.
if(NOT DEFINED FLUTTER_TARGET_PLATFORM)
  set(FLUTTER_TARGET_PLATFORM "windows")
endif()

# Flutter library and tool-managed plugin dependencies.
add_subdirectory(${EPHEMERAL_DIR} ${EPHEMERAL_DIR}/build)

# === Begin custom app CMake configuration ===
set(FLUTTER_MANAGED_PLUGINS_LIST
  ${FLUTTER_MANAGED_PLUGINS_LIST}
)
# === End custom app CMake configuration ===

# Application build; see runner/CMakeLists.txt for details.
function(FLUTTER_BUILD_APP TARGET_NAME)
  # Install the Flutter library and ICU data files.
  install(
    FILES "${FLUTTER_LIBRARY}"
    DESTINATION "."
    COMPONENT Runtime
  )
  install(
    FILES "${ICUDTL_FILE}"
    DESTINATION "data"
    COMPONENT Runtime
  )

  # Install any bundled assets and AOT snapshot.
  install(
    DIRECTORY "${FLUTTER_ASSET_DIR}"
    DESTINATION "data"
    COMPONENT Runtime
  )
  if(EXISTS "${AOT_LIBRARY}")
    install(
      FILES "${AOT_LIBRARY}"
      DESTINATION "."
      COMPONENT Runtime
    )
  endif()

  # Install plugin native libraries if present.
  get_property(PLUGIN_BUNDLED_LIBRARIES GLOBAL PROPERTY PLUGIN_BUNDLED_LIBRARIES)
  if(PLUGIN_BUNDLED_LIBRARIES)
    install(
      FILES ${PLUGIN_BUNDLED_LIBRARIES}
      DESTINATION "."
      COMPONENT Runtime
    )
  endif()

  # Ensure runner target depends on plugin targets.
  get_property(FLUTTER_PLUGIN_TARGETS GLOBAL PROPERTY FLUTTER_PLUGIN_TARGETS)
  if(FLUTTER_PLUGIN_TARGETS)
    add_dependencies(${TARGET_NAME} ${FLUTTER_PLUGIN_TARGETS})
  endif()
endfunction()
