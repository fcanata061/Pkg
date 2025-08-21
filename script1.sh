#!/bin/bash
# ================================================
# script1.sh - responsável por baixar, preparar,
# compilar e instalar em fakeroot
# ================================================

. ./pkg.conf

# Baixar fontes e extrair
baixar() {
    local pkg="$1"
    source "$pkg/build.txt"

    mkdir -p "$SRC_DIR/$name" "$BUILD_DIR"

    echo "🌐 Baixando fontes de $name-$version..."
    for url in "${source[@]}"; do
        file=$(basename "$url")
        dest="$SRC_DIR/$name/$file"
        if [ ! -f "$dest" ]; then
            if command -v wget >/dev/null; then
                wget -O "$dest" "$url"
            elif command -v curl >/dev/null; then
                curl -L -o "$dest" "$url"
            else
                echo "❌ Nenhum downloader disponível (wget/curl)"
                exit 1
            fi
        fi

        echo "📦 Extraindo $file..."
        tar -xf "$dest" -C "$BUILD_DIR"
    done
}

# Aplicar patches
prepare() {
    local pkg="$1"
    source "$pkg/build.txt"

    cd "$BUILD_DIR/$name-$version" || exit 1

    if [ -n "${patches[*]}" ]; then
        for patch in "${patches[@]}"; do
            local patch_file="$SRC_DIR/$name/$patch"
            if [ -f "$patch_file" ]; then
                if ! grep -q "Applied-$patch" ".patches-applied" 2>/dev/null; then
                    echo "📌 Aplicando patch: $patch"
                    patch -p1 < "$patch_file" || exit 1
                    echo "Applied-$patch" >> .patches-applied
                else
                    echo "✔ Patch $patch já aplicado."
                fi
            fi
        done
    fi
}

# Compilar
build() {
    local pkg="$1"
    source "$pkg/build.txt"

    echo "⚙️ Compilando $name-$version..."
    cd "$BUILD_DIR/$name-$version" || exit 1

    # Aplicar patches automaticamente (garantia extra)
    prepare "$pkg"

    build || {
        echo "❌ Erro durante compilação de $name"
        exit 1
    }
}

# Instalar em fakeroot
install() {
    local pkg="$1"
    source "$pkg/build.txt"

    echo "📂 Instalando $name-$version no fakeroot..."

    cd "$BUILD_DIR/$name-$version" || exit 1

    local DEST="$PKG_DIR/$name"
    mkdir -p "$DEST"

    if declare -f install >/dev/null; then
        install || {
            echo "❌ Erro na instalação em fakeroot"
            exit 1
        }
    else
        echo "⚠ Nenhuma função install() em build.txt, usando padrão..."
        make DESTDIR="$DEST" install || exit 1
    fi

    echo "✅ Instalado no fakeroot: $DEST"
}

case "$1" in
    baixar)  baixar "$2" ;;
    prepare) prepare "$2" ;;
    build)   build "$2" ;;
    install) install "$2" ;;
    *) echo "Uso: $0 {baixar|prepare|build|install} <pacote>" ;;
esac
