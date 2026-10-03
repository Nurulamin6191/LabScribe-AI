#include "flutter_window.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  // Stub implementation
  return true;
}

void FlutterWindow::OnDestroy() {
  Win32Window::OnDestroy();
}
