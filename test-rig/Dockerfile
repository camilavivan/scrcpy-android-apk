# scrcpy-android test image.
#
# The unit target bundles JDK 17, Android cmdline-tools, platform 36, and
# build-tools 35 and 36. The e2e target adds the API 36 emulator image and
# runtime libraries. JVM-only tests therefore do not download an emulator.
# Project is mounted at /work; runs in --rm mode.

FROM debian:bookworm-slim@sha256:60eac759739651111db372c07be67863818726f754804b8707c90979bda511df AS unit

ARG SDK_VER=11076708
ARG SDK_SHA256=2d2d50857e4eb553af5a6dc3ad507a17adf43d115264b1afc116f95c92e5e258
ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        openjdk-17-jdk-headless \
        curl unzip ca-certificates git util-linux \
 && rm -rf /var/lib/apt/lists/*

ENV ANDROID_SDK_ROOT=/opt/android-sdk
ENV ANDROID_HOME=$ANDROID_SDK_ROOT

RUN mkdir -p $ANDROID_SDK_ROOT/cmdline-tools \
 && curl -fsSL "https://dl.google.com/android/repository/commandlinetools-linux-${SDK_VER}_latest.zip" \
        -o /tmp/clt.zip \
 && printf '%s  %s\n' "$SDK_SHA256" /tmp/clt.zip | sha256sum -c - \
 && unzip -q /tmp/clt.zip -d $ANDROID_SDK_ROOT/cmdline-tools \
 && mv $ANDROID_SDK_ROOT/cmdline-tools/cmdline-tools $ANDROID_SDK_ROOT/cmdline-tools/latest \
 && rm /tmp/clt.zip

ENV PATH=$ANDROID_SDK_ROOT/cmdline-tools/latest/bin:$ANDROID_SDK_ROOT/platform-tools:$ANDROID_SDK_ROOT/emulator:$PATH

COPY sdk-packages.txt /tmp/sdk-packages.txt
RUN yes | sdkmanager --licenses >/dev/null \
 && sdkmanager $(tr '\n' ' ' < /tmp/sdk-packages.txt) >/dev/null \
 && chmod -R a+rwX "$ANDROID_SDK_ROOT"

# Pre-create the default AVD location and let gradle put its cache here.
ENV GRADLE_USER_HOME=/work/.tools/gradle-home
ENV ANDROID_AVD_HOME=/work/.tools/avd

WORKDIR /work

FROM unit AS e2e

ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        libpulse0 libxkbcommon0 libgl1 libnss3 libasound2 libdbus-1-3 \
        qemu-system-x86 qemu-utils procps ffmpeg \
 && rm -rf /var/lib/apt/lists/*

COPY sdk-packages-e2e.txt /tmp/sdk-packages-e2e.txt
RUN sdkmanager $(tr '\n' ' ' < /tmp/sdk-packages-e2e.txt) >/dev/null \
 && chmod -R a+rwX "$ANDROID_SDK_ROOT"
