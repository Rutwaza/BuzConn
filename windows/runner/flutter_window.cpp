#include "flutter_window.h"

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <windows.h>
#include <mmsystem.h>

#include <optional>

#include "flutter/generated_plugin_registrant.h"

#ifndef WDA_EXCLUDEFROMCAPTURE
#define WDA_EXCLUDEFROMCAPTURE 0x00000011
#endif

namespace {

constexpr int kMaxWindowWidth = 1600;
constexpr int kMaxWindowHeight = 1000;

}  // namespace

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
  RegisterPrivacyChannel();
  RegisterCallChannel();
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::RegisterPrivacyChannel() {
  auto channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "spotlight/privacy",
      &flutter::StandardMethodCodec::GetInstance());

  channel->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        if (call.method_name() != "setSecureScreen") {
          result->NotImplemented();
          return;
        }

        bool enabled = false;
        const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
        if (args) {
          auto value = args->find(flutter::EncodableValue("enabled"));
          if (value != args->end()) {
            if (const auto* bool_value = std::get_if<bool>(&value->second)) {
              enabled = *bool_value;
            }
          }
        }

        const DWORD affinity = enabled ? WDA_EXCLUDEFROMCAPTURE : WDA_NONE;
        if (!SetWindowDisplayAffinity(GetHandle(), affinity) && enabled) {
          // Older Windows builds do not support WDA_EXCLUDEFROMCAPTURE.
          SetWindowDisplayAffinity(GetHandle(), WDA_MONITOR);
        }
        result->Success();
      });

  privacy_channel_ = std::move(channel);
}

void FlutterWindow::RegisterCallChannel() {
  auto channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "spotlight/calls",
      &flutter::StandardMethodCodec::GetInstance());

  channel->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        if (call.method_name() != "setRinging") {
          result->NotImplemented();
          return;
        }

        bool enabled = false;
        const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
        if (args) {
          const auto value = args->find(flutter::EncodableValue("enabled"));
          if (value != args->end()) {
            if (const auto* bool_value = std::get_if<bool>(&value->second)) {
              enabled = *bool_value;
            }
          }
        }

        if (enabled) {
          PlaySoundW(L"SystemExclamation", nullptr,
                     SND_ALIAS | SND_ASYNC | SND_LOOP);
        } else {
          PlaySoundW(nullptr, nullptr, 0);
        }
        result->Success();
      });

  call_channel_ = std::move(channel);
}

void FlutterWindow::OnDestroy() {
  PlaySoundW(nullptr, nullptr, 0);
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (message == WM_GETMINMAXINFO) {
    const LRESULT default_result =
        DefWindowProc(hwnd, message, wparam, lparam);
    auto* min_max_info = reinterpret_cast<MINMAXINFO*>(lparam);
    const double scale_factor = GetDpiForWindow(hwnd) / 96.0;
    const int max_width =
        static_cast<int>(kMaxWindowWidth * scale_factor);
    const int max_height =
        static_cast<int>(kMaxWindowHeight * scale_factor);

    MONITORINFO monitor_info{sizeof(MONITORINFO)};
    const HMONITOR monitor = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
    if (GetMonitorInfo(monitor, &monitor_info)) {
      const int work_width =
          monitor_info.rcWork.right - monitor_info.rcWork.left;
      const int work_height =
          monitor_info.rcWork.bottom - monitor_info.rcWork.top;
      const int constrained_width =
          max_width < work_width ? max_width : work_width;
      const int constrained_height =
          max_height < work_height ? max_height : work_height;

      min_max_info->ptMaxPosition.x = (work_width - constrained_width) / 2;
      min_max_info->ptMaxPosition.y = (work_height - constrained_height) / 2;
      min_max_info->ptMaxSize.x = constrained_width;
      min_max_info->ptMaxSize.y = constrained_height;
      min_max_info->ptMaxTrackSize.x = constrained_width;
      min_max_info->ptMaxTrackSize.y = constrained_height;
    } else {
      min_max_info->ptMaxSize.x = max_width;
      min_max_info->ptMaxSize.y = max_height;
      min_max_info->ptMaxTrackSize.x = max_width;
      min_max_info->ptMaxTrackSize.y = max_height;
    }

    return default_result;
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
