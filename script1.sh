#!/bin/bash
# ================================================
# script1.sh - Funções de build (fetch/prepare/build/install)
# ================================================

. ./pkg.conf

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
error()   { echo -e "${RED}✘${RESET} $1"; exit 1; }
warn()    { echo -e "${YELLOW}⚠${RESET} $1"; }

# ------------------------------------------------
# Localizar pacote no repositório
# ------------------------------------------------
find_pkg() {
    local pkg="$1"
    for repo in "${REPOS[@]}"; do
        if [ -f "$REPO_DIR/$repo/$pkg/build.txt" ]; then
            echo "$REPO_DIR/$repo/$pkg"
            return 0
        fi
    done
    return 1
}

# ------------------------------------------------
# Baixar fontes
# ------------------------------------------------
fetch() {
    local pkg="$1"
    local dir=$(find_pkg "$pkg") || error "Pacote $pkg não encontrado"
    source "$dir/build.txt"

    mkdir -p "$SRC_DIR" "$BUILD_DIR/$name-$version"
    cd "$SRC_DIR"

    for url in "${source[@]}"; do
        msg "Baixando $url"
        $DOWNLOADER "$url" >> "$LOG_DIR/$name-fetch.log" 2>&1 || error "Falha no download $url"
    done

    # extrair para /tmp/build/$name
    for url in "${source[@]}"; do
        file=$(basename "$url")
        msg "Extraindo $file"
        tar xf "$file" -C "$BUILD_DIR" >> "$LOG_DIR/$name-fetch.log" 2>&1
    done

    success "Sources de $name baixados e extraídos"
}

# ------------------------------------------------
# Aplicar patches (prepare)
# ------------------------------------------------
prepare() {
    local pkg="$1"
    local dir=$(find_pkg "$pkg") || error "Pacote $pkg não encontrado"
    source "$dir/build.txt"

    cd "$BUILD_DIR/$name-$version"

    if [ -d "$dir/patches" ]; then
        for patch in "$dir"/patches/*.patch; do
            [ -f "$patch" ] || continue
            msg "Aplicando patch $(basename "$patch")"
            patch -p1 < "$patch" >> "$LOG_DIR/$name-prepare.log" 2>&1 || error "Erro ao aplicar patch"
        done
    fi

    success "Patches aplicados em $name"
}

# ------------------------------------------------
# Build
# ------------------------------------------------
build() {
    local pkg="$1"
    local dir=$(find_pkg "$pkg") || error "Pacote $pkg não encontrado"
    source "$dir/build.txt"

    cd "$BUILD_DIR/$name-$version"

    msg "Compilando $name-$version"
    build >> "$LOG_DIR/$name-build.log" 2>&1 || error "Falha no build de $name"

    success "Build de $name-$version concluído"
}

# ------------------------------------------------
# Install
# ------------------------------------------------
install() {
    local pkg="$1"
    local dir=$(find_pkg "$pkg") || error "Pacote $pkg não encontrado"
    source "$dir/build.txt"

    cd "$BUILD_DIR/$name-$version"

    msg "Instalando $name-$version em fakeroot"
    install >> "$LOG_DIR/$name-install.log" 2>&1 || error "Falha na instalação"

    # salvar lista de arquivos instalados
    mkdir -p "$DB_DIR/$name"
    find "$PKG_DIR" -type f | sed "s|$PKG_DIR||" > "$DB_DIR/$name/files.lst"

    # copiar para o sistema real
    cp -a "$PKG_DIR"/* "$ROOT_DIR" >> "$LOG_DIR/$name-install.log" 2>&1

    success "$name-$version instalado no sistema"
}

# ------------------------------------------------
# Entrada
# ------------------------------------------------
case "$1" in
    fetch) fetch "$2" ;;
    prepare) prepare "$2" ;;
    build) build "$2" ;;
    install) install "$2" ;;
    *) echo -e "${BLUE}Uso:${RESET} $0 {fetch|prepare|build|install} pacote" ;;
esac
