#!/bin/bash
# ================================================
# script1.sh - fetch / prepare / build / install
# ================================================

set -euo pipefail

. ./pkg.conf

# -------- util color/log --------
msg()     { echo -e "${CYAN}${ICON_INFO}${RESET} $*"; }
success() { echo -e "${GREEN}${ICON_OK}${RESET} $*"; }
warn()    { echo -e "${YELLOW}${ICON_WARN}${RESET} $*"; }
error()   { echo -e "${RED}${ICON_FAIL}${RESET} $*"; }
logfile() { echo "$LOG_DIR/$1.log"; }

spinner() {
    # spinner <pid> <prefix-msg>
    local pid="$1"; local prefix="${2:-}"
    local spin='|/-\'; local i=0
    while kill -0 "$pid" 2>/dev/null; do
        i=$(( (i+1) %4 ))
        echo -ne "${DIM}${prefix} ${spin:$i:1}\r${RESET}"
        sleep 0.1
    done
    echo -ne "\r"
}

run_hook() {
    # run_hook <phase> <pkgdir> [env...]
    local phase="$1"; local pkgdir="$2"
    # hooks no build.txt (funções) têm prioridade
    if declare -f "$phase" >/dev/null; then
        "$phase"
        return
    fi
    # hooks por arquivo no pacote: $pkgdir/hooks/<phase>
    if [ -x "$pkgdir/hooks/$phase" ]; then
        ( cd "$pkgdir" && "hooks/$phase" )
        return
    fi
    # hooks globais
    if [ -x "$GLOBAL_HOOKS_DIR/$phase" ]; then
        ( cd "$pkgdir" && "$GLOBAL_HOOKS_DIR/$phase" )
    fi
}

# -------- repo lookup --------
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

# -------- checksum helper --------
_check_sha256() {
    # _check_sha256 <file> <expected>
    local file="$1"; local expected="$2"
    if ! command -v sha256sum >/dev/null 2>&1; then
        warn "sha256sum não encontrado; pulando verificação"
        return 0
    fi
    local have
    have="$(sha256sum "$file" | awk '{print $1}')"
    if [ "$have" != "$expected" ]; then
        error "SHA256 inválido para $file
  esperado: $expected
  obtido : $have"
        return 1
    fi
    return 0
}

# -------- FETCH (download + extract) --------
pkg_fetch_one() {
    # pkg_fetch_one <pkg>   (função interna usada no paralelismo)
    local pkg="$1"
    local dir
    dir="$(find_pkg "$pkg")" || { error "Pacote $pkg não encontrado"; return 1; }
    # shellcheck disable=SC1090
    source "$dir/build.txt"

    mkdir -p "$SRC_DIR" "$BUILD_DIR"
    local logf; logf="$(logfile "$name-fetch")"

    pushd "$SRC_DIR" >/dev/null

    # normaliza arrays
    declare -a _sources=()
    for u in "${source[@]}"; do _sources+=("$(eval echo "$u")"); done

    for idx in "${!_sources[@]}"; do
        local url="${_sources[$idx]}"
        local file="$(basename "$url")"

        if [ ! -f "$file" ]; then
            msg "[$name] Baixando $file"
            if [ -n "$DOWNLOADER" ]; then
                # shellcheck disable=SC2086
                { $DOWNLOADER "$url"; } >>"$logf" 2>&1 || { error "Download falhou: $url"; return 1; }
            else
                error "Nenhum downloader disponível (wget/curl)"
                return 1
            fi
        else
            echo "[cache] $file" >>"$logf"
        fi

        if [ "${CHECKSUMS}" = "on" ] && declare -p sha256sums >/dev/null 2>&1; then
            local exp="${sha256sums[$idx]:-}"
            if [ -n "$exp" ]; then
                _check_sha256 "$file" "$exp" >>"$logf" 2>&1
            else
                warn "[$name] checksum ausente para $file (índice $idx)"
            fi
        fi

        msg "[$name] Extraindo $file → $BUILD_DIR"
        tar -xf "$file" -C "$BUILD_DIR" >>"$logf" 2>&1
    done

    popd >/dev/null
    success "[$name] Fetch concluído"
}

pkg_fetch() {
    # pkg_fetch <pkg> [<pkg>...]
    local -a pkgs=("$@")
    if [ "${#pkgs[@]}" -eq 1 ]; then
        pkg_fetch_one "${pkgs[0]}"; return
    fi
    # paraleliza downloads até PKG_JOBS
    local -a pids=(); local inflight=0
    for p in "${pkgs[@]}"; do
        ( pkg_fetch_one "$p" ) &
        pids+=("$!")
        inflight=$((inflight+1))
        if [ "$inflight" -ge "$PKG_JOBS" ]; then
            for pid in "${pids[@]}"; do wait "$pid"; done
            pids=(); inflight=0
        fi
    done
    for pid in "${pids[@]}"; do wait "$pid"; done
}

# -------- PREPARE (patches + hook pre_build) --------
pkg_prepare() {
    local pkg="$1"
    local dir
    dir="$(find_pkg "$pkg")" || { error "Pacote $pkg não encontrado"; exit 1; }
    # shellcheck disable=SC1090
    source "$dir/build.txt"
    local logf; logf="$(logfile "$name-prepare")"

    # tenta localizar diretório de fonte (name-version*)
    local buildsrc="$BUILD_DIR/$name-$version"
    if [ ! -d "$buildsrc" ]; then
        buildsrc="$(find "$BUILD_DIR" -maxdepth 1 -type d -name "${name}-${version}*" | head -n1)"
        [ -z "$buildsrc" ] && { error "Árvore de fonte não encontrada para $name-$version"; exit 1; }
    fi
    pushd "$buildsrc" >/dev/null

    # aplicar patches listados
    local applied=0
    if declare -p patches >/dev/null 2>&1; then
        for p in "${patches[@]}"; do
            local patchfile="$dir/$p"
            if [ -f "$patchfile" ]; then
                msg "[$name] Patch (lista): $(basename "$patchfile")"
                patch -p1 < "$patchfile" >>"$logf" 2>&1
                applied=1
            else
                warn "[$name] Patch não encontrado: $patchfile"
            fi
        done
    fi
    # aplicar patches do diretório
    if [ -d "$dir/patches" ]; then
        shopt -s nullglob
        for patchfile in "$dir"/patches/*.patch; do
            msg "[$name] Patch (dir): $(basename "$patchfile")"
            patch -p1 < "$patchfile" >>"$logf" 2>&1
            applied=1
        done
        shopt -u nullglob
    fi
    [ "$applied" -eq 1 ] && success "[$name] Patches aplicados" || warn "[$name] Sem patches"

    # hook pre_build
    run_hook "pre_build" "$dir" >>"$logf" 2>&1 || true

    popd >/dev/null
}

# -------- BUILD (função build() + hook post_build) --------
pkg_build() {
    local pkg="$1"
    local dir
    dir="$(find_pkg "$pkg")" || { error "Pacote $pkg não encontrado"; exit 1; }
    # shellcheck disable=SC1090
    source "$dir/build.txt"
    local logf; logf="$(logfile "$name-build")"

    local buildsrc="$BUILD_DIR/$name-$version"
    if [ ! -d "$buildsrc" ]; then
        buildsrc="$(find "$BUILD_DIR" -maxdepth 1 -type d -name "${name}-${version}*" | head -n1)"
        [ -z "$buildsrc" ] && { error "Fonte de $name-$version não preparada"; exit 1; }
    fi
    pushd "$buildsrc" >/dev/null

    if ! declare -f build >/dev/null; then
        error "[$name] build() não definida no build.txt"
        exit 1
    fi

    msg "[$name] Compilando… (veja $(basename "$logf"))"
    ( build >>"$logf" 2>&1 ) &
    local pid=$!; spinner "$pid" "compilando"; wait "$pid"

    # hook post_build
    run_hook "post_build" "$dir" >>"$logf" 2>&1 || true

    popd >/dev/null
    success "[$name] Build concluído"
}

# -------- INSTALL (fakeroot + cópia + hooks + DB) --------
_sql_init() {
    # inicializa schema se necessário
    [ -f "$SQLITE_DB" ] || touch "$SQLITE_DB"
    sqlite3 "$SQLITE_DB" <<'SQL'
PRAGMA journal_mode=WAL;
CREATE TABLE IF NOT EXISTS packages (
  name TEXT PRIMARY KEY,
  version TEXT NOT NULL,
  release INTEGER DEFAULT 1,
  installed_at TEXT DEFAULT (datetime('now'))
);
CREATE TABLE IF NOT EXISTS files (
  package TEXT NOT NULL,
  path TEXT NOT NULL,
  PRIMARY KEY (package, path)
);
CREATE TABLE IF NOT EXISTS deps (
  package TEXT NOT NULL,
  dep TEXT NOT NULL,
  PRIMARY KEY (package, dep)
);
SQL
}

_sql_register_pkg() {
    local name="$1" version="$2" release="${3:-1}"
    sqlite3 "$SQLITE_DB" "INSERT OR REPLACE INTO packages(name,version,release,installed_at) VALUES('$name','$version',$release,datetime('now'))"
}

_sql_register_files() {
    local name="$1" fakeroot="$2"
    # importa lista de arquivos para a tabela files
    while IFS= read -r f; do
        sqlite3 "$SQLITE_DB" "INSERT OR REPLACE INTO files(package,path) VALUES('$name','$f')"
    done < <(cd "$fakeroot" && find . -type f -print0 | tr '\0' '\n' | sed 's#^\./##')
}

_sql_register_deps() {
    local name="$1"; shift
    for d in "$@"; do
        sqlite3 "$SQLITE_DB" "INSERT OR REPLACE INTO deps(package,dep) VALUES('$name','$d')"
    done
}

pkg_install() {
    local pkg="$1"
    local force="${2:-0}"
    local dir
    dir="$(find_pkg "$pkg")" || { error "Pacote $pkg não encontrado"; exit 1; }
    # shellcheck disable=SC1090
    source "$dir/build.txt"
    local logf; logf="$(logfile "$name-install")"

    _sql_init

    local fakeroot="$PKG_DIR/$name"
    local pkgdb_dir="$DB_DIR/$name"
    mkdir -p "$fakeroot" "$pkgdb_dir"

    # hook pre_install
    run_hook "pre_install" "$dir" >>"$logf" 2>&1 || true

    # localizar árvore fonte
    local buildsrc="$BUILD_DIR/$name-$version"
    if [ ! -d "$buildsrc" ]; then
        buildsrc="$(find "$BUILD_DIR" -maxdepth 1 -type d -name "${name}-${version}*" | head -n1)"
        [ -z "$buildsrc" ] && { error "Fonte de $name-$version não preparada"; exit 1; }
    fi

    pushd "$buildsrc" >/dev/null
    export PKG="$fakeroot"
    export DESTDIR="$fakeroot"

    if declare -f install >/dev/null; then
        msg "[$name] Instalando em fakeroot…"
        ( install >>"$logf" 2>&1 ) &
        local pid=$!; spinner "$pid" "instalando"; wait "$pid"
    else
        msg "[$name] make install (padrão)…"
        ( make install >>"$logf" 2>&1 ) &
        local pid=$!; spinner "$pid" "make install"; wait "$pid"
    fi
    popd >/dev/null

    msg "[$name] Copiando para $ROOT_DIR"
    cp -a "$fakeroot"/* "$ROOT_DIR" >>"$logf" 2>&1

    # Manifesto de arquivos (texto) para compatibilidade e DB SQLite
    ( cd "$fakeroot" && find . -type f -print0 | tr '\0' '\n' | sed 's#^\./##' ) > "$pkgdb_dir/files.lst"
    echo "$version" > "$pkgdb_dir/installed"

    # DB
    local rel="${release:-1}"
    _sql_register_pkg "$name" "$version" "$rel"
    if declare -p depends >/dev/null 2>&1; then
        _sql_register_deps "$name" "${depends[@]}"
    fi
    _sql_register_files "$name" "$fakeroot"

    # hook post_install
    run_hook "post_install" "$dir" >>"$logf" 2>&1 || true

    success "[$name] Instalação concluída"
}
