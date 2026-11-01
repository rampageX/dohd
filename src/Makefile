CC=gcc
VERSION ?= 0.8
#CC = clang

CFLAGS := -Wall -Wextra -Wno-sign-compare \
 -DVERSION=\"${VERSION}\" -fPIE

LDFLAGS ?=
LDLIBS := -lwolfssl -lrt -lm -lnghttp2

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

dohd: url64.o libevquick.o mempool.o odoh.o proxy_auth.o h2_session.o dohd.o
	$(CC) $(LDFLAGS) -o $@ $^ $(LDLIBS)
clean:
	rm -f *.o dohd
