cmake_minimum_required(VERSION 3.14)
project(labscribe LANGUAGES CXX)

set(BINARY_NAME "labscribe")

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

add_subdirectory(flutter)

add_executable(${BINARY_NAME} WIN32
  "runner/main.cpp"
  "runner/flutter_window.cpp"
  "runner/win32_window.cpp"
  "runner/utils.cpp"
  "runner/runner.exe.manifest"
  "runner/resources.rc"
)

target_link_libraries(${BINARY_NAME} PRIVATE flutter flutter_wrapper_app)
