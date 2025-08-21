#!/bin/bash
# ================================================
# script2.sh - Funções de manutenção (remover/revdep/depsolve)
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
# Remover pacote
# ------------------------------------------------
remover() {
    local pkg="$1"
    local manifest="$DB_DIR/$pkg/files.lst"

    if [ ! -f "$manifest" ]; then
        error "Pacote $pkg não está instalado"
    fi

    msg "Removendo arquivos de $pkg"
    while read -r file; do
        rm -f "$ROOT_DIR/$file" >> "$LOG_DIR/$pkg-remove.log" 2>&1
    done < "$manifest"

    rm -rf "$DB_DIR/$pkg"
    success "Pacote $pkg removido"
}

# ------------------------------------------------
# Verificação de dependências quebradas
# ------------------------------------------------
revdep() {
    msg "Verificando bibliotecas quebradas..."
    local broken=0

    for bin in $(find "$PREFIX/bin" "$PREFIX/lib" -type f 2>/dev/null); do
        if file "$bin" | grep -q "ELF"; then
            missing=$(ldd "$bin" 2>/dev/null | grep "not found")
            if [ -n "$missing" ]; then
                warn "Dependência faltando em: $bin"
                echo "$missing" >> "$LOG_DIR/revdep.log"
                broken=1
            fi
        fi
    done

    if [ $broken -eq 0 ]; then
        success "Nenhuma dependência quebrada encontrada"
    else
        error "Dependências quebradas detectadas. Veja: $LOG_DIR/revdep.log"
    fi
}

# ------------------------------------------------
# Resolver dependências recursivamente
# ------------------------------------------------
depsolve() {
    local pkg="$1"
    local dir=$(find_pkg "$pkg") || error "Pacote $pkg não encontrado"
    source "$dir/build.txt"

    if [ "${#depends[@]}" -eq 0 ]; then
        warn "Nenhuma dependência declarada para $pkg"
        return 0
    fi

    msg "Resolvendo dependências para $pkg..."
    for dep in "${depends[@]}"; do
        if [ ! -d "$DB_DIR/$dep" ]; then
            warn "Dependência faltando: $dep → Instalando..."
            ./pkg install "$dep" || error "Falha ao instalar dependência $dep"
        else
            success "Dependência já instalada: $dep"
        fi
    done
}

# ------------------------------------------------
# Entrada
# ------------------------------------------------
case "$1" in
    remover) remover "$2" ;;
    revdep) revdep ;;
    depsolve) depsolve "$2" ;;
    *) echo -e "${BLUE}Uso:${RESET} $0 {remover|revdep|depsolve} [pacote]" ;;
esac
