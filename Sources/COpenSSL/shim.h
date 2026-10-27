// OpenSSL for wss:// in SocketWebSocketTask off Apple platforms (Linux: apt install libssl-dev), with the macros Swift
// can't call as functions.
#ifndef CHANNEL_COPENSSL_SHIM_H
#define CHANNEL_COPENSSL_SHIM_H

#include <openssl/ssl.h>
#include <openssl/err.h>
#include <openssl/x509v3.h>

static inline long channel_ssl_set_server_name(SSL *ssl, const char *name) { return SSL_set_tlsext_host_name(ssl, name); }
static inline int channel_ssl_ctx_set_min_tls12(SSL_CTX *context) {
  return (int)SSL_CTX_set_min_proto_version(context, TLS1_2_VERSION);
}

#endif
