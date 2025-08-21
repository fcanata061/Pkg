#!/bin/bash
# ================================================
# script1.sh - fetch / prepare / build / install
# ================================================

set -euo pipefail

. ./pkg.conf

# Mensagens coloridas
msg()     { echo -e "${CYAN}==>${RESET} $*"; }
success() { echo -e "${GREEN}✔${RESET} $*"; }
warn()    { echo -e "${YELLOW}⚠${RESET} $*"; }
error()   { echo -e "${RED}✘${RESET} $*"; }

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
# Baixar sources (usando $DOWNLOADER) e extrair
# ------------------------------------------------
pkg_fetch() {
    local pkg="$1"
    local dir
    dir="$(find_pkg "$pkg")" || { error "Pacote $pkg não encontrado em $REPO_DIR"; exit 1; }

    # shellcheck disable=SC1090
    source "$dir/build.txt"

    mkdir -p "$SRC_DIR" "$BUILD_DIR" "$LOG_DIR"
    cd "$SRC_DIR"

    # Suporta 'source=( ... )' com URLs e variáveis
    for url in "${source[@]}"; do
        local u file
        u="$(eval echo "$url")"
        file="$(basename "$u")"
        if [ ! -f "$file" ]; then
            msg "Baixando $u"
            if [ -n "$DOWNLOADER" ]; then
                # shellcheck disable=SC2086
                $DOWNLOADER "$u" >> "$LOG_DIR/$name-fetch.log" 2>&1 || { error "Falha no download: $u"; exit 1; }
            else
                error "Nenhum downloader (wget/curl) disponível."
                exit 1
            fi
        else
            warn "Cache detectado: $file"
        fi

        msg "Extraindo $file para $BUILD_DIR"
        tar -xf "$file" -C "$BUILD_DIR" >> "$LOG_DIR/$name-fetch.log" 2>&1 || { error "Falha ao extrair: $file"; exit 1; }
    done

    success "Fetch concluído para $name-$version"
}

# ------------------------------------------------
# Aplicar patches automaticamente (prepare)
# - Lê array 'patches=()' se existir
# - Aplica também qualquer *.patch em $pkgdir/patches
# ------------------------------------------------
pkg_prepare() {
    local pkg="$1"
    local dir
    dir="$(find_pkg "$pkg")" || { error "Pacote $pkg não encontrado"; exit 1; }

    # shellcheck disable=SC1090
    source "$dir/build.txt"

    local buildsrc="$BUILD_DIR/$name-$version"
    if [ ! -d "$buildsrc" ]; then
        # tenta adivinhar nome de diretório extraído (fallback)
        buildsrc="$(find "$BUILD_DIR" -maxdepth 1 -type d -name "${name}-${version}*" | head -n1)"
        [ -z "$buildsrc" ] && { error "Árvore de código não encontrada em $BUILD_DIR"; exit 1; }
    fi

    cd "$buildsrc"

    local applied=0
    if declare -p patches >/dev/null 2>&1; then
        for p in "${patches[@]}"; do
            local patchfile
            patchfile="$dir/$p"
            if [ -f "$patchfile" ]; then
                msg "Aplicando patch (lista): $(basename "$patchfile")"
                patch -p1 < "$patchfile" >> "$LOG_DIR/$name-prepare.log" 2>&1 || { error "Falha no patch: $p"; exit 1; }
                applied=1
            else
                warn "Patch não encontrado: $patchfile"
            fi
        done
    fi

    if [ -d "$dir/patches" ]; then
        shopt -s nullglob
        for patchfile in "$dir"/patches/*.patch; do
            msg "Aplicando patch (dir): $(basename "$patchfile")"
            patch -p1 < "$patchfile" >> "$LOG_DIR/$name-prepare.log" 2>&1 || { error "Falha no patch: $patchfile"; exit 1; }
            applied=1
        done
        shopt -u nullglob
    fi

    if [ "$applied" -eq 1 ]; then
        success "Patches aplicados para $name-$version"
    else
        warn "Nenhum patch para aplicar"
    fi
}

# ------------------------------------------------
# Compilar (executa a função build() do build.txt)
# ------------------------------------------------
pkg_build() {
    local pkg="$1"
    local dir
    dir="$(find_pkg "$pkg")" || { error "Pacote $pkg não encontrado"; exit 1; }

    # shellcheck disable=SC1090
    source "$dir/build.txt"

    local buildsrc="$BUILD_DIR/$name-$version"
    if [ ! -d "$buildsrc" ]; then
        buildsrc="$(find "$BUILD_DIR" -maxdepth 1 -type d -name "${name}-${version}*" | head -n1)"
        [ -z "$buildsrc" ] && { error "Fonte de $name-$version não está preparado"; exit 1; }
    fi
    cd "$buildsrc"

    if ! declare -f build >/dev/null; then
        error "Função build() não definida no build.txt de $pkg"
        exit 1
    fi

    msg "Compilando $name-$version"
    build >> "$LOG_DIR/$name-build.log" 2>&1 || { error "Falha no build (veja $LOG_DIR/$name-build.log)"; exit 1; }
    success "Build concluído para $name-$version"
}

# ------------------------------------------------
# Instalar no fakeroot e copiar para /
# - registra versão e manifesto
# ------------------------------------------------
pkg_install() {
    local pkg="$1"
    local force="${2:-0}"
    local dir
    dir="$(find_pkg "$pkg")" || { error "Pacote $pkg não encontrado"; exit 1; }

    # shellcheck disable=SC1090
    source "$dir/build.txt"

    local pkgdb="$DB_DIR/$name"
    local fakeroot="$PKG_DIR/$name"

    if [ -d "$pkgdb" ] && [ "$force" -eq 0 ]; then
        warn "$name já instalado. Use --force para reinstalar."
        return 0
    fi

    mkdir -p "$fakeroot" "$pkgdb"

    local buildsrc="$BUILD_DIR/$name-$version"
    if [ ! -d "$buildsrc" ]; then
        buildsrc="$(find "$BUILD_DIR" -maxdepth 1 -type d -name "${name}-${version}*" | head -n1)"
        [ -z "$buildsrc" ] && { error "Fonte de $name-$version não está preparado"; exit 1; }
    fi
    cd "$buildsrc"

    export PKG="$fakeroot"
    export DESTDIR="$fakeroot"

    if declare -f install >/dev/null; then
        msg "Instalando $name-$version em fakeroot"
        install >> "$LOG_DIR/$name-install.log" 2>&1 || { error "Falha na instalação (veja $LOG_DIR/$name-install.log)"; exit 1; }
    else
        # fallback comum para autotools
        msg "Instalando (padrão) $name-$version em fakeroot"
        make install >> "$LOG_DIR/$name-install.log" 2>&1 || { error "Falha no 'make install'"; exit 1; }
    fi

    msg "Copiando do fakeroot para $ROOT_DIR"
    cp -a "$fakeroot"/* "$ROOT_DIR" >> "$LOG_DIR/$name-install.log" 2>&1 || { error "Falha ao copiar para o sistema"; exit 1; }

    # Manifesto (lista de arquivos) e versão instalada
    find "$fakeroot" -type f | sed "s|$fakeroot||" > "$pkgdb/files.lst"
    echo "$version" > "$pkgdb/installed"

    success "$name-$version instalado no sistema"
}
