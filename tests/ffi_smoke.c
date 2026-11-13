#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "../ios/TgWsProxy/TgWsProxy-Bridging-Header.h"

int main(void) {
    const char *secret = "0123456789abcdef0123456789abcdef";
    /* Не 1443: на машине разработчика этот порт уже держит само приложение. */
    const char *port_env = getenv("TGWS_SMOKE_PORT");
    int32_t port = port_env != NULL ? (int32_t)strtol(port_env, NULL, 10) : 34443;
    SetPoolSize(0);
    SetBufferSizeKb(64);
    SetDisableSecure(0);
    SetForceTestDc(0);
    SetProxyProtocol(0);
    char cache[] = "/tmp/tgws-ffi-cache-XXXXXX";
    assert(mkdtemp(cache) != NULL);
    SetCfProxyCacheDir(cache);
    SetCfProxyConfig(0, 1, "");
    SetCfProxyDomains("alpha.co.uk\nbeta.co.uk\ngamma.co.uk");
    char cache_file[256];
    snprintf(cache_file, sizeof(cache_file), "%s/cfproxy-domains-cache.txt", cache);
    FILE *stored = fopen(cache_file, "r");
    assert(stored != NULL);
    char saved[2048] = {0};
    assert(fread(saved, 1, sizeof(saved) - 1, stored) > 0);
    fclose(stored);
    assert(strstr(saved, "alpha.co.uk") != NULL);
    SetCfWorkerDomains("one.example.com,two.example.com");
    SetCfProxyConfig(0, 1, "one.example.com,two.example.com");
    SetFakeTlsDomain("example.com");
    SetSecret(secret);
    char *full_secret = GetSecretWithPrefix();
    assert(strcmp(full_secret, "ee0123456789abcdef0123456789abcdef6578616d706c652e636f6d") == 0);
    FreeString(full_secret);
    char *domains = GetCfProxyDomains();
    assert(strcmp(domains, "one.example.com\ntwo.example.com") == 0);
    FreeString(domains);
    SetFakeTlsDomain("");
    assert(StartProxy("127.0.0.1", 65536, "", secret, 0) == -2);
    assert(StartProxy("127.0.0.1", port, "", "invalid", 0) == -2);
    int32_t started = StartProxy("127.0.0.1", port, "", secret, 0);
    if (started != 0) {
        fprintf(stderr, "StartProxy returned %d\n", started);
    }
    assert(started == 0);
    domains = GetCfProxyDomains();
    assert(strcmp(domains, "one.example.com\ntwo.example.com") == 0);
    FreeString(domains);

    char *stats = GetStats();
    assert(stats != NULL);
    assert(strstr(stats, "active=0") != NULL);
    assert(strstr(stats, "up_bytes=0") != NULL);
    assert(strstr(stats, "down_bytes=0") != NULL);
    printf("%s\n", stats);
    FreeString(stats);

    assert(StopProxy() == 0);
    for (int i = 0; i < 5; i++) {
        assert(StartProxy("127.0.0.1", port, "", secret, 0) == 0);
        assert(StopProxy() == 0);
    }
    assert(unlink(cache_file) == 0);
    assert(rmdir(cache) == 0);
    return EXIT_SUCCESS;
}
