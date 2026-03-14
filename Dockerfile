FROM alpine:3.21 as buildsystem

RUN apk update && apk add \
    wget unzip gcompat libgcc bash patch make curl build-base

WORKDIR /opt

ENV NDK_VERSION android-ndk-r27c-linux

RUN wget https://dl.google.com/android/repository/${NDK_VERSION}.zip \
 && unzip ${NDK_VERSION}.zip \
 && rm ${NDK_VERSION}.zip

ENV PATH="$PATH:/opt/android-ndk-r27c/toolchains/llvm/prebuilt/linux-x86_64/bin"

WORKDIR /root

##########
# CONFIG #
##########

ARG TARGET=armv7a-linux-androideabi32
ARG PHP_VERSION=8.4.2

ENV SQLITE3_VERSION 3470200

########################
# Build SQLite
########################

RUN wget https://www.sqlite.org/2024/sqlite-amalgamation-${SQLITE3_VERSION}.zip
RUN unzip sqlite-amalgamation-${SQLITE3_VERSION}.zip

WORKDIR /root/sqlite-amalgamation-${SQLITE3_VERSION}

RUN ${TARGET}-clang \
    -shared -fPIC sqlite3.c \
    -o libsqlite3.so

########################
# Download PHP
########################

WORKDIR /root

RUN wget https://www.php.net/distributions/php-${PHP_VERSION}.tar.gz
RUN tar -xvf php-${PHP_VERSION}.tar.gz

COPY *.patch /root/

WORKDIR /root/php-${PHP_VERSION}

RUN patch -p1 < ../ext-standard-dns.c.patch && \
    patch -p1 < ../resolv.patch && \
    patch -p1 < ../ext-standard-php_fopen_wrapper.c.patch && \
    patch -p1 < ../main-streams-cast.c.patch && \
    patch -p1 < ../fork.patch

########################
# Build PHP
########################

WORKDIR /root

RUN mkdir build install

WORKDIR /root/build

RUN ../php-${PHP_VERSION}/configure \
  --host=${TARGET} \
  --prefix=/usr/local/php \
  --disable-dom \
  --disable-simplexml \
  --disable-xml \
  --disable-xmlreader \
  --disable-xmlwriter \
  --disable-phar \
  --disable-phpdbg \
  --disable-cgi \
  --without-pear \
  --without-libxml \
  --with-sqlite3 \
  --with-pdo-sqlite \
  --enable-embed \
  SQLITE_CFLAGS="-I/root/sqlite-amalgamation-${SQLITE3_VERSION}" \
  SQLITE_LIBS="-lsqlite3 -L/root/sqlite-amalgamation-${SQLITE3_VERSION}" \
  CC=${TARGET}-clang

########################
# Android DNS headers
########################

RUN for hdr in resolv_params.h resolv_private.h resolv_static.h resolv_stats.h; do \
    curl https://android.googlesource.com/platform/bionic/+/refs/heads/android12--mainline-release/libc/dns/include/$hdr?format=TEXT \
    | base64 -d > $hdr ; \
  done

########################
# Compile
########################

RUN make -j$(nproc)

########################
# Install PHP
########################

RUN make install DESTDIR=/root/install

########################
# Copy sqlite
########################

RUN cp /root/sqlite-amalgamation-${SQLITE3_VERSION}/libsqlite3.so /root/install/usr/local/php/lib/

########################
# Final image
########################

FROM scratch

ARG LIBDIR
ENV LIBDIR=${LIBDIR}

# PHP runtime libraries
COPY --from=buildsystem /root/install/usr/local/php/lib/libphp.so /app/src/main/jniLibs/${LIBDIR}/
COPY --from=buildsystem /root/install/usr/local/php/lib/libsqlite3.so /app/src/main/jniLibs/${LIBDIR}/

# PHP headers for JNI builds
COPY --from=buildsystem /root/install/usr/local/php/include/php /app/include/php
