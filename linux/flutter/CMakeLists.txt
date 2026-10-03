cmake_minimum_required(VERSION 3.10)

# Flutter variables
set(FLUTTER_ROOT "" CACHE PATH "Flutter SDK path")
set(PROJECT_DIR "${CMAKE_CURRENT_SOURCE_DIR}/..")

# Stub for flutter configuration
add_library(flutter INTERFACE)
