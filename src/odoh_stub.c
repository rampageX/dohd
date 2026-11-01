/*
 * ODoH-free build for systems whose wolfSSL does not include HPKE.
 * Regular DoH does not depend on any of these functions.
 */
#include "odoh.h"

#if DOHD_ENABLE_ODOH
#error "odoh_stub.c must only be compiled with DOHD_ENABLE_ODOH=0"
#endif

int odoh_config_load_file(const char *path, odoh_config *cfg)
{
    (void)path; (void)cfg;
    return -1;
}

int odoh_target_load_files(const char *cfg_path, const char *secret_path,
    odoh_target_ctx *target)
{
    (void)cfg_path; (void)secret_path; (void)target;
    return -1;
}

void odoh_target_free(odoh_target_ctx *target)
{
    (void)target;
}

int odoh_parse_message(const uint8_t *in, size_t in_len, odoh_message_view *msg)
{
    (void)in; (void)in_len; (void)msg;
    return -1;
}

int odoh_client_encrypt_query(const odoh_config *cfg,
    const uint8_t *dns_msg, uint16_t dns_len,
    uint8_t *out, uint16_t *out_len,
    odoh_client_ctx *client_ctx)
{
    (void)cfg; (void)dns_msg; (void)dns_len;
    (void)out; (void)out_len; (void)client_ctx;
    return -1;
}

int odoh_client_decrypt_response(odoh_client_ctx *client_ctx,
    const uint8_t *in, uint16_t in_len,
    uint8_t *dns_out, uint16_t *dns_out_len)
{
    (void)client_ctx; (void)in; (void)in_len;
    (void)dns_out; (void)dns_out_len;
    return -1;
}

int odoh_target_decrypt_query(odoh_target_ctx *target,
    const uint8_t *in, uint16_t in_len,
    uint8_t *dns_out, uint16_t *dns_out_len,
    odoh_req_ctx *req_ctx)
{
    (void)target; (void)in; (void)in_len;
    (void)dns_out; (void)dns_out_len; (void)req_ctx;
    return -1;
}

int odoh_target_encrypt_response(const odoh_req_ctx *req_ctx,
    const uint8_t *dns_msg, uint16_t dns_len,
    uint8_t *out, uint16_t *out_len)
{
    (void)req_ctx; (void)dns_msg; (void)dns_len;
    (void)out; (void)out_len;
    return -1;
}
