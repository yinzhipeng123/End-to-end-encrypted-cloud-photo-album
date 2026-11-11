#include "flutter_window.h"

#include <optional>
#include <wtsapi32.h>
#include <shellapi.h>
#include <dwmapi.h>
#include <flutter/standard_method_codec.h>

#include "flutter/generated_plugin_registrant.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());
  // Cover the last composited Flutter surface before minimizing. Flutter may
  // not rasterize its password page until the window becomes visible again.
  privacy_shield_ = CreateWindowW(
      L"STATIC", L"", WS_CHILD | WS_DISABLED | SS_WHITERECT,
      0, 0, frame.right - frame.left, frame.bottom - frame.top,
      GetHandle(), nullptr, GetModuleHandle(nullptr), nullptr);
  if (!privacy_shield_) return false;

  session_notifications_ =
      WTSRegisterSessionNotification(GetHandle(), NOTIFY_FOR_THIS_SESSION) != 0;
  access_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "miyu/access",
          &flutter::StandardMethodCodec::GetInstance());
  access_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        if (call.method_name() == "appVersion") {
          result->Success(flutter::EncodableValue(FLUTTER_VERSION));
        } else if (call.method_name() == "available") {
          result->Success(flutter::EncodableValue(
              session_notifications_ && !session_locked_ && !suspended_ &&
              !IsIconic(GetHandle())));
        } else if (call.method_name() == "backgroundAvailable") {
          result->Success(flutter::EncodableValue(
              session_notifications_ && !session_locked_ && !suspended_));
        } else if (call.method_name() == "lockedFrameReady") {
          if (call.arguments()) {
            if (const auto* epoch = std::get_if<int32_t>(call.arguments())) {
              ReleasePrivateFrameAfterRender(*epoch);
            }
          }
          result->Success();
        } else if (call.method_name() == "openGitHubDevice") {
          // Fixed destination; no arbitrary URI or credentials from Dart.
          const auto launched = reinterpret_cast<INT_PTR>(ShellExecuteW(
              GetHandle(), L"open", L"https://github.com/login/device",
              nullptr, nullptr, SW_SHOWNORMAL));
          result->Success(flutter::EncodableValue(launched > 32));
        } else if (call.method_name() == "openGitHubApps") {
          // Open the owner's registered apps. Installation remains an explicit
          // action on GitHub; no token, private key, or arbitrary URL is passed.
          const auto launched = reinterpret_cast<INT_PTR>(ShellExecuteW(
              GetHandle(), L"open", L"https://github.com/settings/apps",
              nullptr, nullptr, SW_SHOWNORMAL));
          result->Success(flutter::EncodableValue(launched > 32));
        } else if (call.method_name() == "state") {
          result->Success(flutter::EncodableValue(flutter::EncodableMap{
              {flutter::EncodableValue("minimizeEvents"),
               flutter::EncodableValue(minimize_events_)},
              {flutter::EncodableValue("minimized"),
               flutter::EncodableValue(IsIconic(GetHandle()) != 0)},
              {flutter::EncodableValue("privacyShieldVisible"),
               flutter::EncodableValue(privacy_shield_ &&
                   (GetWindowLongPtr(privacy_shield_, GWL_STYLE) & WS_VISIBLE))},
              {flutter::EncodableValue("sessionLockEvents"),
               flutter::EncodableValue(session_lock_events_)},
              {flutter::EncodableValue("suspendEvents"),
               flutter::EncodableValue(suspend_events_)},
              {flutter::EncodableValue("resumeEvents"),
               flutter::EncodableValue(resume_events_)},
              {flutter::EncodableValue("sessionLocked"),
               flutter::EncodableValue(session_locked_)},
              {flutter::EncodableValue("suspended"),
               flutter::EncodableValue(suspended_)},
          }));
        } else {
          result->NotImplemented();
        }
      });

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  privacy_shield_ = nullptr;
  if (session_notifications_) {
    WTSUnRegisterSessionNotification(GetHandle());
    session_notifications_ = false;
  }
  access_channel_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

void FlutterWindow::NotifyAccessLock(const char* reason) {
  CoverPrivateFrame();
  if (access_channel_) {
    access_channel_->InvokeMethod(
        "lock", std::make_unique<flutter::EncodableValue>(flutter::EncodableMap{
            {flutter::EncodableValue("reason"), flutter::EncodableValue(reason)},
            {flutter::EncodableValue("epoch"), flutter::EncodableValue(privacy_epoch_)},
        }));
  }
}

void FlutterWindow::CoverPrivateFrame() {
  ++privacy_epoch_;
  if (!privacy_shield_) return;
  const RECT rect = GetClientArea();
  SetWindowPos(privacy_shield_, HWND_TOP, 0, 0, rect.right, rect.bottom,
               SWP_NOACTIVATE | SWP_SHOWWINDOW);
  RedrawWindow(GetHandle(), nullptr, nullptr,
               RDW_INVALIDATE | RDW_ALLCHILDREN | RDW_UPDATENOW);
  // Ensure the neutral cover is presented before the OS caches a minimize
  // thumbnail. No photograph is copied into a native preview surface.
  DwmFlush();
}

void FlutterWindow::ReleasePrivateFrameAfterRender(int32_t epoch) {
  if (!privacy_shield_ || !flutter_controller_ || IsIconic(GetHandle()) ||
      epoch != privacy_epoch_ ||
      !(GetWindowLongPtr(privacy_shield_, GWL_STYLE) & WS_VISIBLE)) return;
  flutter_controller_->engine()->SetNextFrameCallback([this, epoch]() {
    if (privacy_shield_ && epoch == privacy_epoch_ && !IsIconic(GetHandle())) {
      ShowWindow(privacy_shield_, SW_HIDE);
    }
  });
  flutter_controller_->ForceRedraw();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Security notifications run before plugins, which may consume messages.
  if (message == WM_SYSCOMMAND && (wparam & 0xfff0) == SC_MINIMIZE) {
    CoverPrivateFrame();
  }
  if (message == WM_SIZE && wparam != SIZE_MINIMIZED && privacy_shield_) {
    const RECT rect = GetClientArea();
    SetWindowPos(privacy_shield_, HWND_TOP, 0, 0, rect.right, rect.bottom,
                 SWP_NOACTIVATE);
  }
  if (message == WM_SIZE && wparam == SIZE_MINIMIZED) {
    ++minimize_events_;
    NotifyAccessLock("minimize");
  } else if (message == WM_WTSSESSION_CHANGE) {
    if (wparam == WTS_SESSION_LOCK || wparam == WTS_CONSOLE_DISCONNECT ||
        wparam == WTS_REMOTE_DISCONNECT || wparam == WTS_SESSION_LOGOFF) {
      session_locked_ = true;
      if (wparam == WTS_SESSION_LOCK) ++session_lock_events_;
      NotifyAccessLock();
    } else if (wparam == WTS_SESSION_UNLOCK || wparam == WTS_CONSOLE_CONNECT ||
               wparam == WTS_REMOTE_CONNECT) {
      session_locked_ = false;
      // Reconnection never unlocks the Dart access gate.
    }
  } else if (message == WM_POWERBROADCAST) {
    if (wparam == PBT_APMSUSPEND) {
      suspended_ = true;
      ++suspend_events_;
      NotifyAccessLock();
    } else if (wparam == PBT_APMRESUMEAUTOMATIC ||
               wparam == PBT_APMRESUMESUSPEND) {
      suspended_ = false;
      ++resume_events_;
      NotifyAccessLock();
    }
  }
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
