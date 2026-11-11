# Pinned production decoding/metadata dependencies. Do not modify Pub's cache.
set(EPA_MEDIA_CACHE "${CMAKE_CURRENT_SOURCE_DIR}/../build/dependencies")
file(MAKE_DIRECTORY "${EPA_MEDIA_CACHE}")
function(epa_download name url digest)
  set(archive "${EPA_MEDIA_CACHE}/${name}")
  if(EXISTS "${archive}")
    file(SHA256 "${archive}" actual)
    if(NOT actual STREQUAL digest)
      message(FATAL_ERROR "${name}: existing dependency checksum mismatch")
    endif()
  else()
    file(DOWNLOAD "${url}" "${archive}" EXPECTED_HASH "SHA256=${digest}"
      TLS_VERIFY ON STATUS result TIMEOUT 300)
    list(GET result 0 code)
    if(NOT code EQUAL 0)
      message(FATAL_ERROR "${name}: pinned dependency download failed")
    endif()
  endif()
endfunction()
epa_download("mpv-full-20261111.7z"
  "https://github.com/shinchiro/mpv-winbuild-cmake/releases/download/20261111/mpv-dev-x86_64-20261111-git-bcde6b93cc.7z"
  "273c079b11ea5575822f972756f4c9a71149a5c10130353abeb8586738938452")
set(EPA_MPV "${EPA_MEDIA_CACHE}/mpv-full")
file(MAKE_DIRECTORY "${EPA_MPV}")
execute_process(COMMAND "${CMAKE_COMMAND}" -E tar xf "${EPA_MEDIA_CACHE}/mpv-full-20261111.7z"
  WORKING_DIRECTORY "${EPA_MPV}" RESULT_VARIABLE unpacked)
if(NOT unpacked EQUAL 0)
  message(FATAL_ERROR "Full libmpv extraction failed")
endif()
# Installed after the plugin's default minimal decoder, preserving its ABI/name.
install(FILES "${EPA_MPV}/libmpv-2.dll" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}" COMPONENT Runtime)
install(FILES "${CMAKE_CURRENT_SOURCE_DIR}/../assets/licenses/libmpv-full-GPL.txt"
  DESTINATION "${INSTALL_BUNDLE_LIB_DIR}/licenses" COMPONENT Runtime)

epa_download("exiftool-13.63_64.zip"
  "https://downloads.sourceforge.net/project/exiftool/exiftool-13.63_64.zip"
  "7a4bff4b1d6ee15adef882837847f76c0ed23228d294feed285939b6c9b293bd")
set(EPA_EXIF "${EPA_MEDIA_CACHE}/exiftool")
file(MAKE_DIRECTORY "${EPA_EXIF}")
execute_process(COMMAND "${CMAKE_COMMAND}" -E tar xf "${EPA_MEDIA_CACHE}/exiftool-13.63_64.zip"
  WORKING_DIRECTORY "${EPA_EXIF}" RESULT_VARIABLE unpacked)
if(NOT unpacked EQUAL 0)
  message(FATAL_ERROR "ExifTool extraction failed")
endif()
install(DIRECTORY "${EPA_EXIF}/exiftool-13.63_64/" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}/metadata"
  COMPONENT Runtime PATTERN "exiftool(-k).exe" EXCLUDE)
install(FILES "${EPA_EXIF}/exiftool-13.63_64/exiftool(-k).exe"
  DESTINATION "${INSTALL_BUNDLE_LIB_DIR}/metadata" RENAME "exiftool.exe" COMPONENT Runtime)
