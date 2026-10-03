#include "win32_window.h"

Win32Window::Win32Window() {}
Win32Window::~Win32Window() {}
bool Win32Window::Create(const std::wstring& title, const Point& origin, const Size& size) { return true; }
void Win32Window::SetQuitOnClose(bool quit_on_close) {}
bool Win32Window::OnCreate() { return true; }
void Win32Window::OnDestroy() { PostQuitMessage(0); }
