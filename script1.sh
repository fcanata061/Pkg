#!/bin/bash
# ============================================================
# script1.sh - Script estilo PKGBUILD simplificado
# ============================================================

SRC_DIR="/var/db/pkg/sources"
BUILD_DIR="/tmp"
PKG_DIR="/tmp/pkg"
DB_DIR="/var/db/pkg"
INSTRUCOES="build.txt"

# ------------------------------------------------------------
# Carregar instruções
# ------------------------------------------------------------
carregar_instrucoes() {
    if [ ! -f "$INSTRUCOES" ]; then
        echo "❌ Arquivo '$INSTRUCOES' não encontrado!"
        exit 1
    fi
    source "$INSTRUCOES"   # carrega name, version, release, source(), funções prepare, build, install
}

# ------------------------------------------------------------
# Baixar sources
# ------------------------------------------------------------
baixar_sources() {
    carregar_instrucoes
    mkdir -p "$SRC_DIR" "$BUILD_DIR"

    for url in "${source[@]}"; do
        arquivo="$SRC_DIR/$(basename "$url")"
        echo "🔽 Baixando $url..."
        if [[ "$url" =~ \.git$ ]]; then
            git clone "$url" "$BUILD_DIR/$name-$version"
        elif command -v wget >/dev/null 2>&1; then
            wget -c "$url" -O "$arquivo"
        elif command -v curl >/dev/null 2>&1; then
            curl -L "$url" -o "$arquivo"
        else
            echo "❌ Nem wget, curl ou git disponíveis!"
            exit 1
        fi

        # Extrair tarballs
        if [[ "$arquivo" =~ \.tar\.(gz|xz|bz2|bz)$ ]]; then
            echo "📦 Extraindo $arquivo em $BUILD_DIR..."
            tar -xf "$arquivo" -C "$BUILD_DIR"
        fi
    done
}

# ------------------------------------------------------------
# Preparar source (patches, ajustes)
# ------------------------------------------------------------
prepare_source() {
    carregar_instrucoes
    WORKDIR="$BUILD_DIR/$name-$version"
    [ ! -d "$WORKDIR" ] && { echo "❌ Diretório $WORKDIR não encontrado!"; exit 1; }
    cd "$WORKDIR" || exit 1

    if declare -f prepare >/dev/null; then
        echo "🛠 Rodando prepare()..."
        prepare
    else
        echo "ℹ️ Nenhuma função prepare() definida, pulando."
    fi
}

# ------------------------------------------------------------
# Compilar programa
# ------------------------------------------------------------
compilar_programa() {
    carregar_instrucoes
    WORKDIR="$BUILD_DIR/$name-$version"
    [ ! -d "$WORKDIR" ] && { echo "❌ Diretório $WORKDIR não encontrado!"; exit 1; }
    cd "$WORKDIR" || exit 1

    echo "🔧 Compilando $name-$version..."
    build
}

# ------------------------------------------------------------
# Instalar programa + registrar arquivos
# ------------------------------------------------------------
instalar_programa() {
    carregar_instrucoes
    WORKDIR="$BUILD_DIR/$name-$version"
    PKG="$PKG_DIR/$name-$version"
    METADIR="$DB_DIR/$name-$version"

    mkdir -p "$PKG" "$METADIR"
    cd "$WORKDIR" || exit 1

    if declare -f install >/dev/null; then
        echo "📦 Instalando em $PKG..."
        install
    else
        echo "ℹ️ Nenhuma função install() definida, pulando."
    fi

    echo "📝 Registrando metadados em $METADIR..."

    # Lista de arquivos instalados
    find "$PKG" -type f | sed "s|$PKG||" > "$METADIR/files.list"

    # Dependências (se declaradas no build.txt)
    if [ -n "${depends[*]}" ]; then
        printf "%s\n" "${depends[@]}" > "$METADIR/deps.list"
    fi

    # Info do pacote
    {
        echo "name=$name"
        echo "version=$version"
        echo "release=$release"
    } > "$METADIR/meta.info"

    echo "✅ Instalação registrada em $METADIR"
}

# ------------------------------------------------------------
# Execução
# ------------------------------------------------------------
case "$1" in
    baixar)   baixar_sources ;;
    prepare)  prepare_source ;;
    build)    compilar_programa ;;
    install)  instalar_programa ;;
    *) echo "Uso: $0 {baixar|prepare|build|install}" ;;
esac
