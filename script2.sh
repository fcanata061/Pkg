#!/bin/bash
# ====================================================
# script2.sh - remover / depsolve / revdep avançado
# ====================================================

set -euo pipefail

. ./pkg.conf
. ./script1.sh

# Mensagens coloridas
msg()     { echo -e "${CYAN}==>${RESET} $*"; }
success() { echo -e "${GREEN}✔${RESET} $*"; }
warn()    { echo -e "${YELLOW}⚠${RESET} $*"; }
error()   { echo -e "${RED}✘${RESET} $*"; }

# ------------------------------------------------
# Remover pacote a partir do manifesto
# ------------------------------------------------
pkg_remove() {
    local pkg="$1"
    local pkgdb="$DB_DIR/$pkg"
    local manifest="$pkgdb/files.lst"

    if [ ! -f "$manifest" ]; then
        error "Pacote $pkg não está instalado (manifesto não encontrado)"
        return 1
    fi

    msg "Removendo arquivos de $pkg"
    while IFS= read -r rel; do
        [ -z "$rel" ] && continue
        local abs="$ROOT_DIR/$rel"
        if [ -f "$abs" ] || [ -h "$abs" ]; then
            rm -f "$abs"
        fi
    done < "$manifest"

    rm -rf "$pkgdb"
    success "$pkg removido"
}

# ------------------------------------------------
# Resolver dependências recursivamente
# - lê 'depends=(...)' do build.txt
# ------------------------------------------------
_pkg_depsolve_inner() {
    local pkg="$1"
    local seen_var="$2" # nome de array associativo para ciclo

    local dir
    dir="$(find_pkg "$pkg")" || { error "Pacote $pkg não encontrado"; exit 1; }
    # shellcheck disable=SC1090
    source "$dir/build.txt"

    # declara array de depends se não existir
    if ! declare -p depends >/dev/null 2>&1; then
        return 0
    fi

    local dep
    for dep in "${depends[@]}"; do
        # Evitar loops: usa array associativo recebido
        if [ -n "${!seen_var-}" ]; then
            eval "if [[ -n \${$seen_var[$dep]+x} ]]; then continue; fi"
            eval "$seen_var[$dep]=1"
        fi

        if [ ! -d "$DB_DIR/$dep" ]; then
            msg "Dependência ausente: $dep → resolvendo"
            _pkg_depsolve_inner "$dep" "$seen_var"
            # instala dependência
            pkg_fetch "$dep"
            pkg_prepare "$dep"
            pkg_build "$dep"
            pkg_install "$dep" 0
        else
            success "Dependência já instalada: $dep"
        fi
    done
}

pkg_depsolve() {
    local pkg="$1"
    # usa array associativo 'seen' para evitar ciclos
    declare -A seen=()
    seen["$pkg"]=1
    _pkg_depsolve_inner "$pkg" seen
}

# ------------------------------------------------
# revdep avançado:
# - detecta "not found" em ldd para binários/ELF instalados
# - recompila pacotes quebrados (--force)
# - remove órfãos (pacotes instalados sem diretório/receita no repositório)
# ------------------------------------------------
pkg_revdep() {
    msg "Verificando bibliotecas e binários ELF instalados..."
    local broken_any=0

    for pkgdb in "$DB_DIR"/*; do
        [ -d "$pkgdb" ] || continue
        local pkg="$(basename "$pkgdb")"
        local manifest="$pkgdb/files.lst"
        [ -f "$manifest" ] || continue

        while IFS= read -r rel; do
            [ -z "$rel" ] && continue
            local abs="$ROOT_DIR/$rel"
            [ -e "$abs" ] || continue
            if file "$abs" 2>/dev/null | grep -q "ELF"; then
                if ldd "$abs" 2>/dev/null | grep -q "not found"; then
                    warn "Dependências quebradas em $pkg ($abs)"
                    msg "Recompilando $pkg (revdep fix)"
                    pkg_fetch "$pkg"
                    pkg_prepare "$pkg"
                    pkg_build "$pkg"
                    pkg_install "$pkg" 1
                    broken_any=1
                    break
                fi
            fi
        done < "$manifest"
    done

    msg "Removendo pacotes órfãos (sem receita no repositório atual)..."
    for pkgdb in "$DB_DIR"/*; do
        [ -d "$pkgdb" ] || continue
        local pkg="$(basename "$pkgdb")"
        if ! find_pkg "$pkg" >/dev/null 2>&1; then
            warn "Órfão detectado: $pkg → removendo"
            pkg_remove "$pkg"
        fi
    done

    if [ "$broken_any" -eq 0 ]; then
        success "Nenhuma dependência quebrada encontrada"
    else
        success "Correções de revdep concluídas"
    fi
}
