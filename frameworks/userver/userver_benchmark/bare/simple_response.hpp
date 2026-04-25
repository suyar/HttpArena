#pragma once

#include <string>

namespace userver_httparena::bare {

struct SimpleResponse final {
  std::string body;
  std::string content_type;
};

}  // namespace userver_httparena::bare
