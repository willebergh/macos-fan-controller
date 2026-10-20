#pragma once
#include <stdint.h>
#include <stddef.h>
uint32_t smc_open(uint32_t *connection);
void smc_close(uint32_t connection);
uint32_t smc_read(uint32_t connection, const char *key, char *type, uint8_t *bytes, uint32_t *size);
uint32_t smc_write(uint32_t connection, const char *key, const uint8_t *bytes, uint32_t size);
uint32_t smc_key_at(uint32_t connection, uint32_t index, char *key);
// A root-owned, per-user socket; peer credentials are checked on both ends.
int fan_server(uint32_t uid);
int fan_accept(int server, uint32_t uid);
int fan_connect(uint32_t uid);
int32_t fan_peer_pid(int socket);
uint64_t fan_process_identity(int32_t pid);
void fan_remove_socket(uint32_t uid);
