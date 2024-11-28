ifneq (,$(wildcard .git))
VERSION  ?= $(shell git describe --tags)
else
VERSION  ?= 2.1.5-procursus7
endif

CC       ?= cc
CXX      ?= c++
INSTALL  ?= install
LN       ?= ln
CODESIGN ?= codesign
DSYMUTIL ?= dsymutil

CXXFLAGS ?= -O2 -pipe
LDFLAGS  ?=

PREFIX   ?= /usr/local

BINDIR   ?= $(PREFIX)/bin
MANDIR   ?= $(PREFIX)/share/man

SRC      := ldid.cpp
LIBS     ?=

LIBPLIST_INCLUDES  ?= $(shell pkg-config --cflags libplist-2.0)
LIBPLIST_LIBS      ?= $(shell pkg-config --libs libplist-2.0)

ifeq ($(shell uname -s),FreeBSD)
LIBCRYPTO_INCLUDES ?= -I/usr/include
LIBCRYPTO_LIBS     ?= -L/usr/lib -lcrypto
else
LIBCRYPTO_INCLUDES ?= $(shell pkg-config --cflags libcrypto)
LIBCRYPTO_LIBS     ?= $(shell pkg-config --libs libcrypto)
endif

ifeq ($(SMARTCARD),1)
CPPFLAGS += -DSMARTCARD
endif

MANPAGE_LANGS := zh_TW zh_CN

EXT ?=

PRODUCT_DIR ?= $(TARGET_BUILD_DIR)
ifeq ($(PRODUCT_DIR),)
PRODUCT_DIR := ./build
endif

DEVELOPMENT_TEAM ?= $(shell echo $DEVELOPMENT_TEAM)
CODE_SIGN_IDENTITY ?= $(shell echo $CODE_SIGN_IDENTITY)

all: ldid$(EXT) sign dsym

%.cpp.o: %.cpp
	$(CXX) -c -std=c++11 $(CXXFLAGS) $(LIBCRYPTO_INCLUDES) $(LIBPLIST_INCLUDES) $(CPPFLAGS) -I. -DLDID_VERSION=\"$(VERSION)\" $< -o $@

ldid$(EXT): $(SRC:%=%.o)
	$(CXX) -o $@ $^ $(LDFLAGS) $(LIBCRYPTO_LIBS) $(LIBPLIST_LIBS) $(LIBS)
	
dsym: ldid$(EXT)
	@echo "Generating dSYM file for ldid$(EXT)..."
	$(DSYMUTIL) ldid$(EXT) -o $(DWARF_DSYM_FOLDER_PATH)/ldid$(EXT).dSYM


sign: ldid$(EXT) dsym
	@echo "Signing binary and dSYM file..."
	$(CODESIGN) --force --sign "$(CODE_SIGN_IDENTITY)" \
		$(if $(ENTITLEMENTS_FILE),--entitlements $(ENTITLEMENTS_FILE),) \
		--timestamp \
		--options runtime \
		ldid$(EXT)
	$(CODESIGN) --force --sign "$(CODE_SIGN_IDENTITY)" \
	--options runtime \
		--timestamp \
		$(DWARF_DSYM_FOLDER_PATH)/ldid$(EXT).dSYM

install: all
	@echo "Copying ldid$(EXT) to $(PRODUCT_DIR)..."
#	$(INSTALL) -d $(PRODUCT_DIR)
#	$(INSTALL) -m755 ldid$(EXT) $(PRODUCT_DIR)/

clean:
	rm -rf ldid$(EXT) *.o

.PHONY: all clean install sign
