FROM ghcr.io/astral-sh/uv:0.8.23 AS uv-source

FROM ubuntu@sha256:59a458b76b4e8896031cd559576eac7d6cb53a69b38ba819fb26518536368d86 AS base

ENV DEBIAN_FRONTEND=noninteractive

# 最低限必要そうなものをインストール
RUN <<EOF
apt-get update
apt-get install -y \
    python3 \
    python3-pip \
    python3-dev \
    git \
    curl \
    gnupg \
    sudo \
    unzip \
    rsync \
    libglib2.0-0 \
    locales
apt-get clean
rm -rf /var/lib/apt/lists/*
EOF

# 日本語ロケールとタイムゾーン
RUN <<EOF
locale-gen ja_JP.UTF-8
update-locale LANG=ja_JP.UTF-8 LC_ALL=ja_JP.UTF-8
EOF
ENV TZ=Asia/Tokyo

# GitHub CLI のインストール
RUN <<EOF
curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | tee /etc/apt/sources.list.d/github-cli.list > /dev/null
apt-get update
apt-get install -y gh
apt-get clean
rm -rf /var/lib/apt/lists/*
EOF

# 日本語ロケールの環境変数を設定
ENV LANG=ja_JP.UTF-8
ENV LC_ALL=ja_JP.UTF-8

# ここで一旦ビルド完了

FROM base AS texlive

# TeXLiveのインストール、TeXLiveのサイトから最新のinstall-tlを取得して行う
# 作業の際、余計なデータが残らないように、install-tlは/tmp以下にダウンロードして展開し、呼び出す
RUN --mount=type=bind,source=.,target=/docker <<EOM
# Install TeXLive
set -xe
mkdir -p /tmp/texlive
cd /tmp/texlive
# Download the TeXLive installer
curl -L -O https://mirror.ctan.org/systems/texlive/tlnet/install-tl-unx.tar.gz
tar xvzf install-tl-unx.tar.gz
mv install-tl-*/ install-tl.d
cd install-tl.d
# TeXLiveのインストール時にコケることが時々あるため、ウェイトを設けて再試行するようにして成功率アップ
# 原因はおそらくサーバー側が無応答と思われるが正直不明です。
for i in 1 2 3; do
    ./install-tl --profile=/docker/texlive.profile --lang=ja && break || {
        echo "Install failed, retrying in 10+ seconds... ($i/3)"
        sleep $((10 + RANDOM % 3))  # 混雑緩和のため若干ラグを足せるように修正
    }
done
hash -r
tlmgr install wrapfig capt-of framed upquote needspace \
    tabulary varwidth titlesec latexmk cmap float wrapfig \
    fancyvrb booktabs parskip adjustbox
# Clean up
cd /tmp
rm -rf /tmp/texlive
EOM

# /opt/texlive/bin/ARCH-linuxにパスを通すようにシェルのスタートアップを書き換え
RUN <<EOM
echo "export PATH=/opt/texlive/bin/$(uname -m)-linux:$PATH" >> /etc/bash.bashrc
echo "export PATH=/opt/texlive/bin/$(uname -m)-linux:$PATH" >> /etc/profile
set -x
PATH="/opt/texlive/bin/$(uname -m)-linux:$PATH" which latexmk # テスト
EOM

FROM texlive
ARG USER=worker
ARG UID=1000
ARG GID=1000
ARG USER_HOME=/home/${USER}
ARG USER_SHELL=/bin/bash

# ユーザの作成
RUN <<EOM
# 最近のイメージでは、すでにUID1000のユーザーが存在していることがある
# そのため、ユーザーを作成する前に確認して、存在しない場合のみ作成する
# UID 1000が存在するのであれば、一度既存のユーザーを削除し手再作成する
if id -u ${UID} >/dev/null 2>&1; then
    # /etc/passwdからユーザーを取得
    RMUSER=$(getent passwd ${UID}|cut -d: -f1)
    userdel -r ${RMUSER}
    groupdel ${RMUSER} || true # 一緒に消えていることもある
fi

groupadd -g ${GID} ${USER}
useradd -m -s ${USER_SHELL} -u ${UID} -g ${USER} -G sudo ${USER}
mkdir -p ${USER_HOME}/.ssh
chown -R ${UID}:${GID} ${USER_HOME}
chmod 700 ${USER_HOME}/.ssh
echo "${USER} ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers
EOM


USER ${USER}
# uvツールのインストール
COPY --from=uv-source /uv /uvx /usr/local/bin/

# nvmのインストール
ENV NVM_DIR=/home/${USER}/.nvm
RUN curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash
# node,npmのインストール
RUN <<EOM
    . ${NVM_DIR}/nvm.sh
    nvm install --lts
    nvm use --lts
EOM

WORKDIR /app
