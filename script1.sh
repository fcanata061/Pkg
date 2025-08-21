#!/bin/bash
# ================================================
# script1.sh - Funções de fetch, prepare, build, install
# ================================================

. ./pkg.conf   # carrega variáveis globais

# ------------------------------------------------
# Baixar fontes
# ------------------------------------------------
baixar() {
    local pkg="$1"
    source "$pkg/build.txt"

    echo "📥 Baixando fontes de $name-$version..."

    mkdir -p "$SRC_DIR" "$BUILD_DIR/$name-$version"
    cd "$SRC_DIR" || exit 1

    for url in "${source[@]}"; do
        echo "➡ Baixando: $url"
        $DOWNLOADER "$url" >> "$LOG_DIR/$name-fetch.log" 2>&1 || {
            echo "❌ Falha no download: $url"
            exit 1
        }
    done

    # Extrair no diretório de build
    for file in "${source[@]##*/}"; do
        tar xf "$file" -C "$BUILD_DIR" >> "$LOG_DIR/$name-fetch.log" 2>&1 || {
            echo "❌ Falha ao extrair $file"
            exit 1
        }
    done

    echo "✅ Fontes prontos em $BUILD_DIR/$name-$version"
}

# ------------------------------------------------
# Aplicar patches (prepare)
# ------------------------------------------------
prepare() {
    local pkg="$1"
    source "$pkg/build.txt"

    cd "$BUILD_DIR/$name-$version" || exit 1

    if [ "${#patches[@]}" -gt 0 ]; then
        echo "🩹 Aplicando patches..."
        for patch in "${patches[@]}"; do
            patch -p1 < "$pkg/$patch" >> "$LOG_DIR/$name-prepare.log" 2>&1 || {
                echo "❌ Erro aplicando patch $patch"
                exit 1
            }
        done
    fi

    echo "✅ Prepare concluído"
}

# ------------------------------------------------
# Compilar
# ------------------------------------------------
build() {
    local pkg="$1"
    source "$pkg/build.txt"

    echo "⚙️  Compilando $name-$version..."
    cd "$BUILD_DIR/$name-$version" || exit 1

    if declare -f build >/dev/null; then
        build >> "$LOG_DIR/$name-build.log" 2>&1 || {
            echo "❌ Erro na compilação (veja $LOG_DIR/$name-build.log)"
            exit 1
        }
    else
        echo "⚠ Nenhuma função build() definida em build.txt"
    fi

    echo "✅ Build concluído"
}

# ------------------------------------------------
# Instalar em fakeroot
# ------------------------------------------------
install() {
    local pkg="$1"
    source "$pkg/build.txt"

    echo "📂 Instalando $name-$version no fakeroot..."
    cd "$BUILD_DIR/$name-$version" || exit 1

    local DEST="$PKG_DIR/$name"
    mkdir -p "$DEST"

    if declare -f install >/dev/null; then
        install >> "$LOG_DIR/$name-install.log" 2>&1 || {
            echo "❌ Erro na instalação em fakeroot (veja $LOG_DIR/$name-install.log)"
            exit 1
        }
    else
        echo "⚠ Nenhuma função install() definida em build.txt, rodando padrão..."
        make DESTDIR="$DEST" install >> "$LOG_DIR/$name-install.log" 2>&1 || exit 1
    fi

    echo "✅ Instalado no fakeroot: $DEST"
}

# ------------------------------------------------
# Entrada
# ------------------------------------------------
case "$1" in
    baixar) baixar "$2" ;;
    prepare) prepare "$2" ;;
    build) build "$2" ;;
    install) install "$2" ;;
    *) echo "Uso: $0 {baixar|prepare|build|install} <pacote>" ;;
esac
