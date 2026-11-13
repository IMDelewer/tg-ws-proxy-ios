#ifndef TgWsProxy_Bridging_Header_h
#define TgWsProxy_Bridging_Header_h

#include <stdint.h>

int32_t StartProxy(
    const char *host,
    int32_t port,
    const char *dc_ips,
    const char *secret,
    int32_t verbose
);
int32_t StopProxy(void);
void SetPoolSize(int32_t size);
void SetBufferSizeKb(int32_t kb);
void SetCfWorkerDomains(const char *domains);
void SetFakeTlsDomain(const char *domain);
void SetDisableSecure(int32_t value);
void SetForceTestDc(int32_t value);
void SetProxyProtocol(int32_t value);
void SetCfProxyDomains(const char *domains);
void SetCfProxyCacheDir(const char *cache_dir);
void SetCfProxyConfig(int32_t enabled, int32_t priority, const char *user_domain);
void SetSecret(const char *secret);
char *GetStats(void);
char *GetSecretWithPrefix(void);
char *GetCfProxyDomains(void);
int32_t RefreshCfProxyDomains(void);
void FreeString(char *pointer);

#endif
