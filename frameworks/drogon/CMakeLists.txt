cmake_minimum_required(VERSION 3.14)
project(httparena-drogon CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_FLAGS_RELEASE "${CMAKE_CXX_FLAGS_RELEASE} -O3 -flto")

find_package(Drogon REQUIRED)

add_executable(server main.cc)
target_link_libraries(server PRIVATE Drogon::Drogon)
