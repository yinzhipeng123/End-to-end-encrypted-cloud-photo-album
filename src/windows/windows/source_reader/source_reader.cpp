#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <vector>
#include <cwchar>
#include <cstring>

extern "C" __declspec(dllexport) HANDLE epa_open(
    const wchar_t* path, DWORD access, DWORD sharing, DWORD flags, DWORD* error) {
  HANDLE file = CreateFileW(path, access, sharing, nullptr, OPEN_EXISTING, flags, nullptr);
  *error = file == INVALID_HANDLE_VALUE ? GetLastError() : ERROR_SUCCESS;
  return file;
}

// Capture thread-local errors before returning to the Dart VM. Returning an
// error code also avoids relying on GetLastError across separate FFI calls.
extern "C" __declspec(dllexport) DWORD epa_read_start(
    HANDLE file, void* buffer, DWORD length, DWORD* count, OVERLAPPED* operation) {
  return ReadFile(file, buffer, length, count, operation) ? ERROR_SUCCESS : GetLastError();
}
extern "C" __declspec(dllexport) DWORD epa_read_result(
    HANDLE file, OVERLAPPED* operation, DWORD* count) {
  return GetOverlappedResult(file, operation, count, FALSE) ? ERROR_SUCCESS : GetLastError();
}

// Rename the exact open, version-verified file without replacing a destination.
// The caller holds source and destination ancestor guards. Same-volume only.
extern "C" __declspec(dllexport) DWORD epa_move_to_recovery(
    HANDLE file, const wchar_t* destination) {
  const size_t characters = wcslen(destination);
  if (characters == 0 || characters > 32760) return ERROR_INVALID_NAME;
  const DWORD bytes = static_cast<DWORD>(characters * sizeof(wchar_t));
  std::vector<unsigned char> storage(sizeof(FILE_RENAME_INFO) + bytes, 0);
  auto* info = reinterpret_cast<FILE_RENAME_INFO*>(storage.data());
  info->ReplaceIfExists = FALSE;
  info->RootDirectory = nullptr;
  info->FileNameLength = bytes;
  memcpy(info->FileName, destination, bytes);
  return SetFileInformationByHandle(file, FileRenameInfo, info,
      static_cast<DWORD>(storage.size())) ? ERROR_SUCCESS : GetLastError();
}
