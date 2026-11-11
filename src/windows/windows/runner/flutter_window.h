#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <flutter/encodable_value.h>

#include <memory>

#include "win32_window.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> access_channel_;
  bool session_notifications_ = false;
  bool session_locked_ = false;
  bool suspended_ = false;
  // Volatile event counters for diagnosing actual OS notification delivery.
  // They contain no vault data and do not grant or restore access.
  int32_t session_lock_events_ = 0;
  int32_t minimize_events_ = 0;
  HWND privacy_shield_ = nullptr;
  int32_t privacy_epoch_ = 0;
  void CoverPrivateFrame();
  void ReleasePrivateFrameAfterRender(int32_t epoch);
  int32_t suspend_events_ = 0;
  int32_t resume_events_ = 0;
  void NotifyAccessLock(const char* reason = "system");
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
