#!/bin/bash
# ================================================
# script1.sh - Funções de fetch, prepare, build, install
# ================================================

. ./pkg.conf   # carrega variáveis globais

# Cores
RED="\033[1;31m"
GREEN="\033[1;32m"
YELLOW="\033[1;33m"
BLUE="\033[1;34m"
MAGENTA="\033[1;35m"
CYAN="\033[1;36m"
RESET="\033[0m"

msg()     { echo -e "${CYAN}==>${RESET} $1"; }
success() { echo -e "${GREEN}✔${RESET} $1"; }
error()   { echo -e "${RED}✘${RESET} $1"; }
warn()    { echo -e "${YELLOW}⚠${RESET} $1"; }

# ------------------------------------------------
# Baixar fontes
# ------------------------------------------------
baixar() {
    local pkg="$1"
    source "$pkg/build.txt"

    msg "Baixando fontes de ${MAGENTA}$name-$version${RESET}..."

    mkdir -p "$SRC_DIR" "$BUILD_DIR/$name-$version"
    cd "$SRC_DIR" || exit 1

    for url in "${source[@]}"; do
        msg "➡ ${BLUE}Download${RESET}: $url"
        $DOWNLOADER "$url" >> "$LOG_DIR/$name-fetch.log" 2>&1 || {
            error "Falha no download: $url"
            exit 1
        }
    done

    for file in "${source[@]##*/}"; do
        msg "➡ ${BLUE}Extraindo${RESET}: $file"
        tar xf "$file" -C "$BUILD_DIR" >> "$LOG_DIR/$name-fetch.log" 2>&1 || {
            error "Falha ao extrair $file"
            exit 1
        }
    done

    success "Fontes prontos em $BUILD_DIR/$name-$version"
}

# ------------------------------------------------
# Aplicar patches
# ------------------------------------------------
prepare() {
    local pkg="$1"
    source "$pkg/build.txt"

    cd "$BUILD_DIR/$name-$version" || exit 1

    if [ "${#patches[@]}" -gt 0 ]; then
        msg "Aplicando patches..."
        for patch in "${patches[@]}"; do
            msg "➡ ${BLUE}Patch${RESET}: $patch"
            patch -p1 < "$pkg/$patch" >> "$LOG_DIR/$name-prepare.log" 2>&1 || {
                error "Erro aplicando patch $patch"
                exit 1
            }
        done
        success "Patches aplicados"
    else
        warn "Nenhum patch definido"
    fi
}

# ------------------------------------------------
# Compilar
# ------------------------------------------------
build() {
    local pkg="$1"
    source "$pkg/build.txt"

    msg "Compilando ${MAGENTA}$name-$version${RESET}..."
    cd "$BUILD_DIR/$name-$version" || exit 1

    if declare -f build >/dev/null; then
        build >> "$LOG_DIR/$name-build.log" 2>&1 || {
            error "Erro na compilação (veja $LOG_DIR/$name-build.log)"
            exit 1
        }
    else
        warn "Nenhuma função build() definida em build.txt"
    fi

    success "Build concluído"
}

# ------------------------------------------------
# Instalar no fakeroot
# ------------------------------------------------
install() {
    local pkg="$1"
    source "$pkg/build.txt"

    msg "Instalando ${MAGENTA}$name-$version${RESET} no fakeroot..."
    cd "$BUILD_DIR/$name-$version" || exit 1

    local DEST="$PKG_DIR/$name"
    mkdir -p "$DEST"

    if declare -f install >/dev/null; then
        install >> "$LOG_DIR/$name-install.log" 2>&1 || {
            error "Erro na instalação (veja $LOG_DIR/$name-install.log)"
            exit 1
        }
    else
        warn "Nenhuma função install() definida em build.txt, rodando padrão..."
        make DESTDIR="$DEST" install >> "$LOG_DIR/$name-install.log" 2>&1 || exit 1
    fi

    success "Instalado no fakeroot: $DEST"
}

# ------------------------------------------------
# Entrada
# ------------------------------------------------
case "$1" in
    baixar) baixar "$2" ;;
    prepare) prepare "$2" ;;
    build) build "$2" ;;
    install) install "$2" ;;
    *) echo -e "${BLUE}Uso:${RESET} $0 {baixar|prepare|build|install} <pacote>" ;;
esac
