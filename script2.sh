#!/bin/bash
# ====================================================
# script2.sh - remover / depsolve / revdep / órfãos
# ====================================================

set -euo pipefail

. ./pkg.conf
. ./script1.sh

# -------- util --------
msg()     { echo -e "${CYAN}${ICON_INFO}${RESET} $*"; }
success() { echo -e "${GREEN}${ICON_OK}${RESET} $*"; }
warn()    { echo -e "${YELLOW}${ICON_WARN}${RESET} $*"; }
error()   { echo -e "${RED}${ICON_FAIL}${RESET} $*"; }

_sql_init_if() { [ -f "$SQLITE_DB" ] || return 0; }

# -------- Remove pacote --------
pkg_remove() {
    local pkg="$1"
    local dir; dir="$(find_pkg "$pkg")" || true

    # hook pre_remove (pode existir sem receita)
    if [ -n "$dir" ]; then run_hook "pre_remove" "$dir" >>"$(logfile "$pkg-remove")" 2>&1 || true; fi

    local pkgdb="$DB_DIR/$pkg"
    local manifest="$pkgdb/files.lst"
    if [ ! -f "$manifest" ]; then
        error "$pkg não está instalado (manifesto ausente)"
        return 1
    fi

    msg "Removendo arquivos de $pkg"
    while IFS= read -r rel; do
        [ -z "$rel" ] && continue
        local abs="$ROOT_DIR/$rel"
        if [ -e "$abs" ] || [ -h "$abs" ]; then
            rm -f "$abs"
        fi
    done < "$manifest"

    rm -rf "$pkgdb"

    # remove do DB sqlite
    if [ -f "$SQLITE_DB" ]; then
        sqlite3 "$SQLITE_DB" "DELETE FROM files WHERE package='$pkg';"
        sqlite3 "$SQLITE_DB" "DELETE FROM deps WHERE package='$pkg';"
        sqlite3 "$SQLITE_DB" "DELETE FROM packages WHERE name='$pkg';"
    fi

    # hook post_remove
    if [ -n "$dir" ]; then run_hook "post_remove" "$dir" >>"$(logfile "$pkg-remove")" 2>&1 || true; fi

    success "$pkg removido"
}

# -------- Resolve dependências recursivas --------
_pkg_depsolve_inner() {
    local pkg="$1"; local seen_arr="$2"
    local dir; dir="$(find_pkg "$pkg")" || { error "Pacote $pkg não encontrado"; exit 1; }
    # shellcheck disable=SC1090
    source "$dir/build.txt"

    if ! declare -p depends >/dev/null 2>&1; then return 0; fi
    local d
    for d in "${depends[@]}"; do
        eval "if [[ -n \${$seen_arr[$d]+x} ]]; then continue; fi"
        eval "$seen_arr[$d]=1"

        if [ ! -d "$DB_DIR/$d" ]; then
            msg "Dependência faltando: $d (do pacote $pkg)"
            _pkg_depsolve_inner "$d" "$seen_arr"
            pkg_fetch "$d"
            pkg_prepare "$d"
            pkg_build "$d"
            pkg_install "$d" 0
        else
            success "Dependência ok: $d"
        fi
    done
}
pkg_depsolve() {
    local pkg="$1"
    declare -A seen=()
    seen["$pkg"]=1
    _pkg_depsolve_inner "$pkg" seen
}

# -------- Revdep + órfãos (via DB) --------
pkg_revdep() {
    msg "Analisando binários e bibliotecas ELF…"
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
                    warn "Quebra detectada: $pkg → $abs"
                    msg "Recompilando $pkg para corrigir revdep"
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

    msg "Procurando pacotes órfãos…"
    # Órfão: instalado no DB mas receita não existe no repositório
    for pkgdb in "$DB_DIR"/*; do
        [ -d "$pkgdb" ] || continue
        local pkg="$(basename "$pkgdb")"
        if ! find_pkg "$pkg" >/dev/null 2>&1; then
            warn "Órfão: $pkg (sem receita) → removendo"
            pkg_remove "$pkg"
        fi
    done

    if [ "$broken_any" -eq 0 ]; then
        success "Sem quebras detectadas"
    else
        success "Revdep: correções aplicadas"
    fi
}

# -------- Utilidades com DB --------
db_list_installed() {
    if [ ! -f "$SQLITE_DB" ]; then
        # fallback pelo diretório
        find "$DB_DIR" -maxdepth 1 -mindepth 1 -type d -printf "%f\n" | sort
    else
        sqlite3 "$SQLITE_DB" "SELECT name FROM packages ORDER BY name;"
    fi
}

db_get_version() {
    local pkg="$1"
    if [ ! -f "$SQLITE_DB" ]; then
        cat "$DB_DIR/$pkg/installed" 2>/dev/null || true
    else
        sqlite3 "$SQLITE_DB" "SELECT version FROM packages WHERE name='$pkg';"
    fi
}
