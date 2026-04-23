#include "simple_router.hpp"

#include <userver/components/component_context.hpp>

#include "../controllers/plaintext/handler.hpp"
#include "../controllers/baseline11/handler.hpp"
#include "../controllers/json/handler.hpp"
#include "../controllers/single_query/handler.hpp"

namespace userver_httparena::bare {

namespace {

constexpr std::string_view kPlainTextUrlPrefix{"/pipeline"};
constexpr std::string_view kBaseLine11UrlPrefix{"/baseline11"};
constexpr std::string_view kJsonUrlPrefix{"/json"};
constexpr std::string_view kSingleQueryUrlPrefix{"/async-db"};

// NOLINTNEXTLINE
const std::string kContentTypePlain{"text/plain"};
// NOLINTNEXTLINE
const std::string kContentTypeJson{"application/json"};
// NOLINTNEXTLINE
const std::string kContentTypeTextHtml{"text/html; charset=utf-8"};

bool StartsWith(std::string_view source, std::string_view pattern)
{
  return source.substr(0, pattern.length()) == pattern;
}

}  // namespace

SimpleRouter::SimpleRouter(const userver::components::ComponentConfig& config,
                           const userver::components::ComponentContext& context)
    : userver::components::LoggableComponentBase{config, context},
      single_query_{context.FindComponent<single_query::Handler>()} { }

SimpleRouter::~SimpleRouter() = default;

SimpleResponse SimpleRouter::RouteRequest(std::string_view url) const
{
  if (StartsWith(url, kPlainTextUrlPrefix)) {
    return {plaintext::Handler::GetResponse(), kContentTypePlain};
  }

  if (StartsWith(url, kBaseLine11UrlPrefix)) {
    return {baseline11::Handler::GetResponse("1000", "2000", "3000"), kContentTypePlain};
  }

  if (StartsWith(url, kJsonUrlPrefix)) {
    return {json::Handler::GetResponse(), kContentTypeJson};
  }

  if (StartsWith(url, kSingleQueryUrlPrefix)) {
    return {single_query_.GetResponse(), kContentTypeJson};
  }

  throw std::runtime_error{"No handler found for url"};
}

}  // namespace userver_httparena::bare
