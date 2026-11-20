cmake_minimum_required(VERSION 3.16)
# usage: configured by build/build-updater.sh only, with MACFUSE_VERSION, MACFUSE_ICON and the pinned clang22,
#        to build macfuse-updater.app
set(MACFUSE_VERSION "" CACHE STRING "the full version, <UPSTREAM_VERSION>-mavericks.N")
set(MACFUSE_ICON "" CACHE FILEPATH "upstream's AppIcon.icns, from the extracted dmg")
if(MACFUSE_VERSION STREQUAL "" OR NOT EXISTS "${MACFUSE_ICON}")
  message(FATAL_ERROR "configure through build/build-updater.sh: MACFUSE_VERSION and MACFUSE_ICON (an existing .icns) are required")
endif()
project(macfuse-updater LANGUAGES OBJC)

find_package(MavericksShipyard REQUIRED)
set(MAVERICKS_REQUIRE_APPLECLANG OFF)
include(Mavericks)
include(MavericksSparkle)
mavericks_add_updater_app(
  PRODUCT macfuse
  PRODUCT_NAME "Mavericks macFUSE"
  ICON "${MACFUSE_ICON}"
  VERSION "${MACFUSE_VERSION}"
  ED_PUBKEY_FILE "${CMAKE_CURRENT_SOURCE_DIR}/ed25519_key.pub"
  LOG_PREFIX "MavMacFUSEUpdater"
  CONFIRM_TITLE "Mavericks macFUSE updated"
  CONFIRM_BODY "macFUSE for Mavericks was updated. File systems mounted from now on use the new version."
)
