CC=gcc
VERSION ?= 0.8
#CC = clang

CFLAGS := -Wall -Wextra -Wno-sign-compare \
 -DVERSION=\"${VERSION}\" -fPIE

LDFLAGS ?=
LDLIBS := -lwolfssl -lrt -lm -lnghttp2

# The ODoH implementation needs wolfSSL's newer HPKE API. Embedded builds
# commonly use an older wolfSSL but only need regular HTTPS DNS service.
# ODOH=auto enables it when the installed headers expose the required types.
# Override explicitly with ODOH=0 (legacy) or ODOH=1 (HPKE-enabled wolfSSL).
ODOH ?= auto
ifeq ($(ODOH),auto)
  ODOH_ENABLED := $(shell printf '#include <wolfssl/options.h>\n#include <wolfssl/wolfcrypt/hpke.h>\nint main(void) { return (int)(sizeof(Hpke) + sizeof(HpkeBaseContext)); }\n' | $(CC) $(CPPFLAGS) -x c -c -o /dev/null - >/dev/null 2>&1 && echo 1 || echo 0)
else ifeq ($(ODOH),0)
  ODOH_ENABLED := 0
else ifeq ($(ODOH),1)
  ODOH_ENABLED := 1
else
  $(error Invalid ODOH=$(ODOH); use auto, 0, or 1)
endif

ifeq ($(ODOH_ENABLED),1)
  ODOH_OBJECT := odoh.o
else
  ODOH_OBJECT := odoh_stub.o
endif
CFLAGS += -DDOHD_ENABLE_ODOH=$(ODOH_ENABLED)

all: CFLAGS+= -O3
all: dohd

debug: CFLAGS+= -ggdb -O0
debug: dohd

dmalloc: CFLAGS+=-DDMALLOC -DDMALLOC_FUNC_CHECK
dmalloc: LDLIBS+=-ldmalloc
dmalloc: dohd

asan: CFLAGS+=-fsanitize=address
asan: LDFLAGS+=-fsanitize=address
asan: dohd

dohd: url64.o libevquick.o mempool.o $(ODOH_OBJECT) proxy_auth.o h2_session.o dohd.o
	$(CC) $(LDFLAGS) -o $@ $^ $(LDLIBS)
clean:
	rm -f *.o dohd
