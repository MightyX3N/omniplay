/* OmniPlay HTTPS front door for phones.
 *
 * Phone browsers only allow the camera on HTTPS pages, so this listens for TLS on the local
 * network (default port 21892) and forwards the decrypted bytes to OmniPlay's own plain server
 * on 127.0.0.1 (port 21890). The certificate is self-signed, created once and kept in OmniPlay's
 * save folder, so the phone asks to trust it only the first time.
 *
 * One background thread, non-blocking sockets, a handful of connections. Built on mbedTLS.
 */
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include "mbedtls/net_sockets.h"
#include "mbedtls/ssl.h"
#include "mbedtls/entropy.h"
#include "mbedtls/ctr_drbg.h"
#include "mbedtls/x509_crt.h"
#include "mbedtls/x509_csr.h"
#include "mbedtls/pk.h"
#include "mbedtls/ecp.h"
#include "mbedtls/error.h"
#include "psa/crypto.h"

#ifdef _WIN32
#include <windows.h>
#define API __declspec(dllexport)
static void sleep_ms(int ms) { Sleep(ms); }
#else
#include <pthread.h>
#include <unistd.h>
#define API
static void sleep_ms(int ms) { usleep(ms * 1000); }
#endif

#define MAXC 12
#define BUF 16384

typedef struct {
  int used, shaking;
  mbedtls_net_context tls_fd, plain_fd;
  mbedtls_ssl_context ssl;
  unsigned char up[BUF];   int up_len;    /* phone -> OmniPlay, waiting to be written */
  unsigned char down[BUF]; int down_len;  /* OmniPlay -> phone */
  int idle;                               /* loops without traffic */
} conn_t;

static mbedtls_entropy_context entropy;
static mbedtls_ctr_drbg_context drbg;
static mbedtls_ssl_config conf;
static mbedtls_x509_crt cert;
static mbedtls_pk_context key;
static mbedtls_net_context listener;
static conn_t conns[MAXC];
static int g_target_port = 21890, g_running = 0;
static char g_status[256] = "off";
static volatile int g_stop = 0;
static int g_port = 0, g_accepted = 0, g_served = 0, g_failed = 0, g_last_err = 0;
static void update_status(void)
{
  char e[96] = "";
  if (g_last_err) mbedtls_strerror(g_last_err, e, sizeof e);
  snprintf(g_status, sizeof g_status, "listening on port %d; %d connections, %d secure, %d failed%s%s", g_port, g_accepted, g_served, g_failed, g_last_err ? ", last: " : "", e);
}

static void status(const char *s, int err)
{
  if (err) {
    char e[128];
    mbedtls_strerror(err, e, sizeof e);
    snprintf(g_status, sizeof g_status, "%s (%s)", s, e);
  } else {
    snprintf(g_status, sizeof g_status, "%s", s);
  }
}

static int write_file(const char *path, const unsigned char *data)
{
  FILE *f = fopen(path, "wb");
  if (!f) return -1;
  fputs((const char *)data, f);
  fclose(f);
  return 0;
}

/* load cert + key from dir, or create a new self-signed pair there */
static int load_or_make_cert(const char *dir)
{
  char kpath[600], cpath[600];
  snprintf(kpath, sizeof kpath, "%s/omniplay-tls-key.pem", dir);
  snprintf(cpath, sizeof cpath, "%s/omniplay-tls-cert.pem", dir);
  if (mbedtls_pk_parse_keyfile(&key, kpath, NULL, mbedtls_ctr_drbg_random, &drbg) == 0 &&
      mbedtls_x509_crt_parse_file(&cert, cpath) == 0) return 0;
  mbedtls_pk_free(&key); mbedtls_pk_init(&key);
  mbedtls_x509_crt_free(&cert); mbedtls_x509_crt_init(&cert);

  int r = mbedtls_pk_setup(&key, mbedtls_pk_info_from_type(MBEDTLS_PK_ECKEY));
  if (r) return r;
  r = mbedtls_ecp_gen_key(MBEDTLS_ECP_DP_SECP256R1, mbedtls_pk_ec(key), mbedtls_ctr_drbg_random, &drbg);
  if (r) return r;

  mbedtls_x509write_cert crt;
  mbedtls_x509write_crt_init(&crt);
  mbedtls_x509write_crt_set_version(&crt, MBEDTLS_X509_CRT_VERSION_3);
  mbedtls_x509write_crt_set_md_alg(&crt, MBEDTLS_MD_SHA256);
  mbedtls_x509write_crt_set_subject_key(&crt, &key);
  mbedtls_x509write_crt_set_issuer_key(&crt, &key);
  mbedtls_x509write_crt_set_subject_name(&crt, "CN=OmniPlay on this PC,O=OmniPlay");
  mbedtls_x509write_crt_set_issuer_name(&crt, "CN=OmniPlay on this PC,O=OmniPlay");
  unsigned char serial[8];
  mbedtls_ctr_drbg_random(&drbg, serial, sizeof serial);
  serial[0] &= 0x7f;
  mbedtls_x509write_crt_set_serial_raw(&crt, serial, sizeof serial);
  mbedtls_x509write_crt_set_validity(&crt, "20250101000000", "20450101000000");
  mbedtls_x509write_crt_set_basic_constraints(&crt, 0, -1);

  static unsigned char pem[4096];
  r = mbedtls_x509write_crt_pem(&crt, pem, sizeof pem, mbedtls_ctr_drbg_random, &drbg);
  mbedtls_x509write_crt_free(&crt);
  if (r) return r;
  write_file(cpath, pem);
  r = mbedtls_x509_crt_parse(&cert, pem, strlen((char *)pem) + 1);
  if (r) return r;
  r = mbedtls_pk_write_key_pem(&key, pem, sizeof pem);
  if (r) return r;
  write_file(kpath, pem);
  return 0;
}

static void drop(conn_t *c)
{
  mbedtls_ssl_free(&c->ssl);
  mbedtls_net_free(&c->tls_fd);
  mbedtls_net_free(&c->plain_fd);
  c->used = 0;
}

static int pump(conn_t *c)
{
  int moved = 0, r;
  if (c->shaking) {
    r = mbedtls_ssl_handshake(&c->ssl);
    if (r == MBEDTLS_ERR_SSL_WANT_READ || r == MBEDTLS_ERR_SSL_WANT_WRITE) return 0;
    if (r) { g_failed++; g_last_err = r; update_status(); return -1; } /* usually the phone hasn't trusted the certificate yet */
    c->shaking = 0;
    g_served++; update_status();
    char port[16];
    snprintf(port, sizeof port, "%d", g_target_port);
    if (mbedtls_net_connect(&c->plain_fd, "127.0.0.1", port, MBEDTLS_NET_PROTO_TCP)) return -1;
    mbedtls_net_set_nonblock(&c->plain_fd);
    return 1;
  }
  /* phone -> OmniPlay */
  if (c->up_len < BUF) {
    r = mbedtls_ssl_read(&c->ssl, c->up + c->up_len, BUF - c->up_len);
    if (r > 0) { c->up_len += r; moved = 1; }
    else if (r == 0 || (r != MBEDTLS_ERR_SSL_WANT_READ && r != MBEDTLS_ERR_SSL_WANT_WRITE)) return -1;
  }
  if (c->up_len > 0) {
    r = mbedtls_net_send(&c->plain_fd, c->up, c->up_len);
    if (r > 0) { memmove(c->up, c->up + r, c->up_len - r); c->up_len -= r; moved = 1; }
    else if (r != MBEDTLS_ERR_SSL_WANT_WRITE) return -1;
  }
  /* OmniPlay -> phone */
  if (c->down_len < BUF) {
    r = mbedtls_net_recv(&c->plain_fd, c->down + c->down_len, BUF - c->down_len);
    if (r > 0) { c->down_len += r; moved = 1; }
    else if (r == 0) { if (c->down_len == 0) return -1; }
    else if (r != MBEDTLS_ERR_SSL_WANT_READ) return -1;
  }
  if (c->down_len > 0) {
    r = mbedtls_ssl_write(&c->ssl, c->down, c->down_len);
    if (r > 0) { memmove(c->down, c->down + r, c->down_len - r); c->down_len -= r; moved = 1; }
    else if (r != MBEDTLS_ERR_SSL_WANT_READ && r != MBEDTLS_ERR_SSL_WANT_WRITE) return -1;
  }
  return moved;
}

static void loop(void)
{
  while (!g_stop) {
    int busy = 0;
    /* new connections */
    mbedtls_net_context fd;
    mbedtls_net_init(&fd);
    int r = mbedtls_net_accept(&listener, &fd, NULL, 0, NULL);
    if (r == 0) {
      int slot = -1;
      for (int i = 0; i < MAXC; i++) if (!conns[i].used) { slot = i; break; }
      if (slot < 0) { mbedtls_net_free(&fd); }
      else {
        conn_t *c = &conns[slot];
        memset(c, 0, sizeof *c);
        c->used = 1; c->shaking = 1;
        g_accepted++; update_status();
        c->tls_fd = fd;
        mbedtls_net_init(&c->plain_fd);
        mbedtls_net_set_nonblock(&c->tls_fd);
        mbedtls_ssl_init(&c->ssl);
        if (mbedtls_ssl_setup(&c->ssl, &conf)) { drop(c); }
        else mbedtls_ssl_set_bio(&c->ssl, &c->tls_fd, mbedtls_net_send, mbedtls_net_recv, NULL);
        busy = 1;
      }
    }
    for (int i = 0; i < MAXC; i++) {
      conn_t *c = &conns[i];
      if (!c->used) continue;
      int p = pump(c);
      if (p < 0) { drop(c); continue; }
      if (p > 0) { busy = 1; c->idle = 0; }
      else if (c->shaking && ++c->idle > 5000) drop(c); /* handshake stuck ~10 s */
    }
    if (!busy) sleep_ms(2);
  }
}

#ifdef _WIN32
static DWORD WINAPI thread_main(LPVOID p) { (void)p; loop(); return 0; }
#else
static void *thread_main(void *p) { (void)p; loop(); return NULL; }
#endif

/* dir: where the certificate lives; listen_port: e.g. 21892; target_port: OmniPlay's plain server */
API int sb_tls_start(const char *dir, int listen_port, int target_port)
{
  if (g_running) return 0;
  g_target_port = target_port;
  mbedtls_entropy_init(&entropy);
  mbedtls_ctr_drbg_init(&drbg);
  mbedtls_ssl_config_init(&conf);
  mbedtls_x509_crt_init(&cert);
  mbedtls_pk_init(&key);
  mbedtls_net_init(&listener);
  psa_crypto_init(); /* TLS 1.3 needs it */
  int r = mbedtls_ctr_drbg_seed(&drbg, mbedtls_entropy_func, &entropy, (const unsigned char *)"omniplay", 8);
  if (r) { status("random generator failed", r); return -1; }
  r = load_or_make_cert(dir);
  if (r) { status("certificate failed", r); return -1; }
  r = mbedtls_ssl_config_defaults(&conf, MBEDTLS_SSL_IS_SERVER, MBEDTLS_SSL_TRANSPORT_STREAM, MBEDTLS_SSL_PRESET_DEFAULT);
  if (r) { status("TLS setup failed", r); return -1; }
  mbedtls_ssl_conf_rng(&conf, mbedtls_ctr_drbg_random, &drbg);
  r = mbedtls_ssl_conf_own_cert(&conf, &cert, &key);
  if (r) { status("certificate rejected", r); return -1; }
  char port[16];
  snprintf(port, sizeof port, "%d", listen_port);
  r = mbedtls_net_bind(&listener, "0.0.0.0", port, MBEDTLS_NET_PROTO_TCP); /* IPv4: phones on Wi-Fi */
  if (r) { status("port busy", r); return -1; }
  mbedtls_net_set_nonblock(&listener);
  g_running = 1;
#ifdef _WIN32
  HANDLE h = CreateThread(NULL, 0, thread_main, NULL, 0, NULL);
  if (h) CloseHandle(h);
#else
  pthread_t t;
  pthread_create(&t, NULL, thread_main, NULL);
  pthread_detach(t);
#endif
  g_port = listen_port;
  update_status();
  return 0;
}

API const char *sb_tls_status(void) { return g_status; }
API void sb_tls_stop(void) { g_stop = 1; }
