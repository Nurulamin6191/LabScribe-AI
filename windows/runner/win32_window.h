#ifndef RUNNER_WIN32_WINDOW_H_
#define RUNNER_WIN32_WINDOW_H_

#include <windows.h>
#include <string>

class Win32Window {
 public:
  struct Point { int x; int y; Point(int x, int y) : x(x), y(y) {} };
  struct Size { int width; int height; Size(int width, int height) : width(width), height(height) {} };

  Win32Window();
  virtual ~Win32Window();
  bool Create(const std::wstring& title, const Point& origin, const Size& size);
  void SetQuitOnClose(bool quit_on_close);
 protected:
  virtual bool OnCreate();
  virtual void OnDestroy();
};

#endif  // RUNNER_WIN32_WINDOW_H_
