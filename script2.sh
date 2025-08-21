#!/bin/bash
# ============================================================
# script2.sh - Gerenciador avançado (remoção + dependências)
# ============================================================

PKG_DB="/var/db/pkg"
PKG_DIR="/tmp/pkg"

# ------------------------------------------------------------
# Função: Remover programa
# ------------------------------------------------------------
remover() {
    nome=$1
    versao=$2

    if [ -z "$nome" ] || [ -z "$versao" ]; then
        echo "⚠️ Uso: $0 remover <nome> <versão>"
        exit 1
    fi

    METADIR="$PKG_DB/$nome-$versao"
    if [ ! -d "$METADIR" ]; then
        echo "❌ Pacote $nome-$versao não registrado em $PKG_DB"
        exit 1
    fi

    echo "🗑 Removendo $nome-$versao..."
    while IFS= read -r arquivo; do
        if [ -e "$arquivo" ]; then
            sudo rm -rf "$arquivo"
            echo "➡ Apagado: $arquivo"
        fi
    done < "$METADIR/files.list"

    echo "🧹 Limpando metadados..."
    sudo rm -rf "$METADIR"

    echo "✅ $nome-$versao removido com sucesso!"
}

# ------------------------------------------------------------
# Função: Verificar dependências quebradas
# ------------------------------------------------------------
revdep() {
    echo "🔍 Verificando dependências de binários e bibliotecas..."
    for bin in $(find /usr/bin /usr/lib -type f 2>/dev/null); do
        if file "$bin" | grep -q ELF; then
            faltando=$(ldd "$bin" 2>/dev/null | grep "not found")
            if [ -n "$faltando" ]; then
                echo "⚠️ Binário $bin com dependências ausentes:"
                echo "$faltando"
            fi
        fi
    done
    echo "✅ Verificação concluída!"
}

# ------------------------------------------------------------
# Função: Resolver dependências recursivas
# ------------------------------------------------------------
resolver_dependencias() {
    pacote=$1
    if [ -z "$pacote" ]; then
        echo "⚠️ Uso: $0 deps <pacote>"
        exit 1
    fi

    echo "🔗 Resolvendo dependências para $pacote..."

    METADIR="$PKG_DB/$pacote"
    if [ ! -f "$METADIR/deps.list" ]; then
        echo "ℹ️ Nenhuma dependência registrada para $pacote"
        return
    fi

    while IFS= read -r dep; do
        echo "➡ Dependência encontrada: $dep"
        if [ ! -d "$PKG_DB/$dep" ]; then
            echo "📦 Instalando dependência faltante: $dep"
            # Aqui chamaria o script1.sh automaticamente
            ./script1.sh baixar "$dep"
            ./script1.sh prepare "$dep"
            ./script1.sh build "$dep"
            ./script1.sh install "$dep"
        fi
        resolver_dependencias "$dep"
    done < "$METADIR/deps.list"
}

# ------------------------------------------------------------
# Execução
# ------------------------------------------------------------
case "$1" in
    remover) remover "$2" "$3" ;;
    revdep) revdep ;;
    deps) resolver_dependencias "$2" ;;
    *) echo "Uso: $0 {remover <nome> <versão>|revdep|deps <pacote>}" ;;
esac
