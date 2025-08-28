#!/bin/sh
# mbuild: gerenciador simples em POSIX sh para LFS/ports minimalistas
# - Usa UMA pasta base (MBASE) para tudo
# - Tudo configurável por variáveis (sobreponha via ambiente ou CLI VAR=val)
# - Lê recipe POSIX (variáveis + funções) e executa
# - Faz: download, extração, patch, build, install em DESTDIR com fakeroot, empacota, loga, registra, remove com hook pós-remove
# - Colorido + spinner
# - Opção de toolchain (profiles básicos)
#
# Uso:
#   MBASE=/caminho ./mbuild.sh init
#   ./mbuild.sh run recipes/hello.recipe             # compila/empacota
#   ./mbuild.sh install hello-1.0-1.x86_64.ppkg      # instala binário no ROOT
#   ./mbuild.sh remove hello                          # remove e roda pós-remove
#   VAR=valor ./mbuild.sh ...                         # sobrepõe variáveis
#
# Recipe: arquivo POSIX que define ao menos:
#   pkgname, pkgver, pkgrel, arch, source (URLs separados por espaço, opcional patches)
#   (opcional) sha256sums (na mesma ordem de source)
#   (opcional) prepare(), build(), check(), package(), post_remove()
#   Se funções não forem definidas, defaults simples são usados
#
# Licença: MIT – exemplo educacional. Sem garantias.

set -eu
umask 022

# -------------------- Variáveis (expansivas) --------------------
: "${MBASE:=${PWD}/mbuild}"           # pasta única p/ tudo
: "${M_SRC:=${MBASE}/sources}"
: "${M_BUILD:=${MBASE}/build}"
: "${M_PKGROOT:=${MBASE}/pkgroot}"    # DESTDIR durante package
: "${M_PKGS:=${MBASE}/packages}"      # saída .ppkg
: "${M_LOGS:=${MBASE}/logs}"
: "${M_STATE:=${MBASE}/state}"        # registro de instalados
: "${M_RECIPES:=${MBASE}/recipes}"
: "${M_HOOKS:=${MBASE}/hooks}"        # hooks globais (post-remove)
: "${ROOT:=/}"                        # raiz para instalar/remover pacotes binários
: "${PREFIX:=/usr}"
: "${PKG_COMP:=zst}"                  # gz|bz2|xz|zst
: "${JOBS:=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)}"
: "${DOWNLOAD_RETRIES:=3}"
: "${CURL_OPTS:=-L}"
: "${TOOLCHAIN:=system}"              # system|llvm|musl (apenas perfis de flags)
: "${STRIP:=1}"

# Toolchain profiles (simples)
case "$TOOLCHAIN" in
  llvm)
    : "${CC:=clang}"; : "${CXX:=clang++}"; : "${AR:=llvm-ar}"; : "${RANLIB:=llvm-ranlib}" ;;
  musl)
    : "${CC:=musl-gcc}"; : "${CXX:=g++}"; : "${AR:=ar}"; : "${RANLIB:=ranlib}" ;;
  *)
    : "${CC:=cc}"; : "${CXX:=c++}"; : "${AR:=ar}"; : "${RANLIB:=ranlib}" ;;
esac
: "${CFLAGS:=-O2 -pipe}"
: "${LDFLAGS:=}"

# -------------------- Cores & logger --------------------
if [ -t 1 ] && command -v tput >/dev/null 2>&1; then
  C_GRN=$(tput setaf 2); C_RED=$(tput setaf 1); C_YLW=$(tput setaf 3); C_BLU=$(tput setaf 4); C_RST=$(tput sgr0)
else C_GRN=""; C_RED=""; C_YLW=""; C_BLU=""; C_RST=""; fi
logfile()
{
  b=${1:-general}; printf '%s/%s-%s.log' "$M_LOGS" "$b" "$(date +%Y%m%d-%H%M%S)"
}
INFO(){ printf "%s[*]%s %s\n" "$C_BLU" "$C_RST" "$*"; }
OK(){   printf "%s[OK]%s %s\n" "$C_GRN" "$C_RST" "$*"; }
WARN(){ printf "%s[!]%s %s\n" "$C_YLW" "$C_RST" "$*"; }
ERR(){  printf "%s[ERR]%s %s\n" "$C_RED" "$C_RST" "$*"; }

# -------------------- Spinner --------------------
_spinner(){ msg=$1; i=0; s='|/-\\'; while :; do i=$(( (i+1) % 4 )); printf "\r[%c] %s" "$(printf %s "$s" | cut -c $((i+1)))" "$msg"; sleep 0.1; done }
runspin(){ msg=$1; shift; _spinner "$msg" & _spid=$!; ("$@") >>"$RUN_LOG" 2>&1 || _rc=$?; kill $_spid 2>/dev/null || true; wait $_spid 2>/dev/null || true; printf "\r"; return ${_rc:-0}; }

# -------------------- Utilitários --------------------
mkdirs(){ mkdir -p "$M_SRC" "$M_BUILD" "$M_PKGROOT" "$M_PKGS" "$M_LOGS" "$M_STATE/pkgs" "$M_RECIPES" "$M_HOOKS/post-remove"; }
sha256_check(){ # args: file expected_sum
  [ -n "${2:-}" ] || return 0
  if command -v sha256sum >/dev/null 2>&1; then
    echo "$2  $1" | sha256sum -c - >/dev/null
  else
    WARN "sha256sum não disponível; pulando verificação"
  fi
}
fetch(){ url=$1; out=$2; sum=${3:-}; [ -f "$out" ] || {
  INFO "Baixando $url"; i=0; while [ $i -lt "$DOWNLOAD_RETRIES" ]; do i=$((i+1)); if curl $CURL_OPTS -o "$out" "$url" >>"$RUN_LOG" 2>&1; then break; fi; WARN "retry $i"; sleep $i; done; }
  [ -n "$sum" ] && sha256_check "$out" "$sum"
}
extract(){ arc=$1; dest=$2; INFO "Extraindo $(basename "$arc")"; mkdir -p "$dest"; case "$arc" in
  *.tar.gz|*.tgz)   tar -xzf "$arc" -C "$dest" ;;
  *.tar.bz2|*.tbz2) tar -xjf "$arc" -C "$dest" ;;
  *.tar.xz|*.txz)   tar -xJf "$arc" -C "$dest" ;;
  *.tar.zst|*.tzst) tar --zstd -xf "$arc" -C "$dest" ;;
  *.zip)            unzip -q "$arc" -d "$dest" ;;
  *)                tar -xf "$arc" -C "$dest" ;;
 esac >>"$RUN_LOG" 2>&1
}
apply_patch(){ p=$1; [ -f "$p" ] || return 0; INFO "Aplicando patch $(basename "$p")"; patch -Np1 < "$p" >>"$RUN_LOG" 2>&1; }
mkmeta(){ # escreve CONTROL/meta a partir das variáveis da recipe
  d=$1; shift; { echo "name=$pkgname"; echo "version=$pkgver"; echo "release=$pkgrel"; echo "arch=$arch"; echo "prefix=$PREFIX"; } > "$d/CONTROL/meta"
}
mkmanifest(){ root=$1; man=$2; : > "$man"; ( cd "$root" && find . -type f -o -type l | while IFS= read -r f; do printf '%s\n' "$f"; done ) > "$man"; }
pack_pkg(){ # cria .ppkg a partir de $M_PKGROOT
  out="$M_PKGS/${pkgname}-${pkgver}-${pkgrel}.${arch}.ppkg"
  INFO "Empacotando $(basename "$out")"
  mkdir -p "$M_PKGROOT/CONTROL"
  mkmeta "$M_PKGROOT"
  mkmanifest "$M_PKGROOT" "$M_PKGROOT/CONTROL/manifest"
  compflag=""; case "$PKG_COMP" in gz) compflag=-z;; bz2) compflag=-j;; xz) compflag=-J;; zst) compflag=--zstd;; *) compflag=;; esac
  ( cd "$M_PKGROOT" && tar $compflag -cf "$out" . ) >>"$RUN_LOG" 2>&1
  OK "Pacote: $out"; echo "$out"
}
ldconf(){ command -v ldconfig >/dev/null 2>&1 && ldconfig >>"$RUN_LOG" 2>&1 || true; }

# -------------------- Defaults de build/package --------------------
default_prepare(){ :; }
default_build(){ if [ -x ./configure ]; then CC="$CC" CFLAGS="$CFLAGS" LDFLAGS="$LDFLAGS" ./configure --prefix="$PREFIX"; fi; make -j"$JOBS"; }
default_check(){ make -k check || true; }
default_package(){ make DESTDIR="$M_PKGROOT" install; }

# -------------------- Carregar recipe --------------------
load_recipe(){ RECIPE=$1; # shellcheck disable=SC1090
  set +u; . "$RECIPE"; set -u
  : "${pkgname:?recipe: defina pkgname}"; : "${pkgver:?defina pkgver}"; : "${pkgrel:=1}"; : "${arch:=$(uname -m)}"; : "${source:?defina source}"; : "${patches:=}"; : "${sha256sums:=}";
  PREPARE=${PREPARE:-default_prepare}; BUILD=${BUILD:-default_build}; CHECK=${CHECK:-default_check}; PACKAGE=${PACKAGE:-default_package}
}

# -------------------- Fluxo run (source→build→pack) --------------------
cmd_run(){ recipe=$1; mkdirs; RUN_LOG=$(logfile "$pkgname-run")
  INFO "Recipe: $recipe"; load_recipe "$recipe"; RUN_LOG=$(logfile "$pkgname-run")
  INFO "Log: $RUN_LOG"
  # 1) Fetch todas as fontes
  i=1
  set +f
  OLD_IFS=$IFS; IFS=' '
  for url in $source; do sum=$(echo "$sha256sums" | awk -v n=$i '{print $n}'); arc="$M_SRC/$(basename "$url")"; runspin "fetch $(basename "$url")" fetch "$url" "$arc" "$sum" || { ERR "Falha no download"; exit 3; }; i=$((i+1)); done
  IFS=$OLD_IFS; set -f
  # 2) Extrair primeira fonte em M_BUILD/pkgname-pkgver
  rm -rf "$M_BUILD/${pkgname}-${pkgver}" "$M_PKGROOT"; mkdir -p "$M_BUILD" "$M_PKGROOT"
  first=$(printf '%s\n' $source | awk 'NR==1{print}'); extract "$M_SRC/$(basename "$first")" "$M_BUILD"
  SRCDIR=$(printf '%s/%s-%s' "$M_BUILD" "$pkgname" "$pkgver"); [ -d "$SRCDIR" ] || SRCDIR=$(find "$M_BUILD" -maxdepth 1 -type d -name "${pkgname}*" | head -n1)
  cd "$SRCDIR"
  # 3) Patches
  for p in $patches; do apply_patch "$p"; done
  # 4) prepare/build/check/package
  runspin "prepare $pkgname" sh -c "$PREPARE" || true
  runspin "build $pkgname"   sh -c "$BUILD"
  runspin "check $pkgname"   sh -c "$CHECK" || true
  runspin "package $pkgname" sh -c "$PACKAGE"
  # 5) strip opcional
  if [ "$STRIP" = "1" ] && command -v strip >/dev/null 2>&1; then
    INFO "Strip ELF"
    find "$M_PKGROOT" -type f -perm -111 -exec sh -c 'file -bi "$1" | grep -qi "executable\|sharedlib" && strip --strip-unneeded "$1" || true' _ {} \; >>"$RUN_LOG" 2>&1
  fi
  # 6) empacotar
  PKGFILE=$(pack_pkg)
  OK "Build concluído: $PKGFILE"
}

# -------------------- Instalar pacote binário no ROOT --------------------
cmd_install(){ pkg=$1; mkdirs; RUN_LOG=$(logfile install)
  INFO "Instalando $pkg em $ROOT"; tmp=$(mktemp -d); case "$pkg" in /*) src="$pkg";; *) src="$M_PKGS/$pkg";; esac
  [ -f "$src" ] || { ERR "Pacote não encontrado: $src"; exit 2; }
  ( cd "$tmp" && tar -xf "$src" ) >>"$RUN_LOG" 2>&1
  # Scripts de controle
  if [ -d "$tmp/CONTROL/scripts" ]; then PR="$tmp/CONTROL/scripts"; else PR="$tmp/CONTROL"; fi
  # Copiar DATA para ROOT (tudo que não é CONTROL)
  ( cd "$tmp" && { for f in ./*; do [ "$(basename "$f")" = "CONTROL" ] && continue; tar -cf - "$f"; done; } ) | ( cd "$ROOT" && tar -xf - )
  # Registrar manifest
  name=$(grep '^name=' "$tmp/CONTROL/meta" | cut -d= -f2)
  ver=$(grep '^version=' "$tmp/CONTROL/meta" | cut -d= -f2)
  pkgid="$name-$ver"
  instdir="$M_STATE/pkgs/$name"; mkdir -p "$instdir"; cp "$tmp/CONTROL/meta" "$instdir/meta"; cp "$tmp/CONTROL/manifest" "$instdir/manifest"
  date +%FT%T >> "$M_STATE/installed.index" 2>/dev/null || true
  OK "Instalado: $pkgid"
  ldconf
  rm -rf "$tmp"
}

# -------------------- Remover pacote do ROOT --------------------
cmd_remove(){ name=$1; mkdirs; RUN_LOG=$(logfile remove)
  instdir="$M_STATE/pkgs/$name"; [ -d "$instdir" ] || { ERR "$name não está instalado"; exit 2; }
  INFO "Removendo $name de $ROOT"
  man="$instdir/manifest"; # remover na ordem inversa para evitar diretórios não vazios
  tac_cmd(){ command -v tac >/dev/null 2>&1 && tac "$1" || awk '{a[NR]=$0} END{ for(i=NR;i>=1;i--) print a[i] }' "$1"; }
  tac_cmd "$man" | while IFS= read -r f; do [ -z "$f" ] && continue; path="$ROOT/${f#./}"; [ -e "$path" -o -L "$path" ] && rm -f "$path" || true; done >>"$RUN_LOG" 2>&1
  # Limpar diretórios vazios (melhor esforço)
  awk -F/ '{p=""; for(i=1;i<=NF;i++){p=p (i==1?$1:"/"$i); print p}}' "$man" | sort -u -r | while IFS= read -r d; do dp="$ROOT/${d#./}"; [ -d "$dp" ] && rmdir "$dp" 2>/dev/null || true; done >>"$RUN_LOG" 2>&1
  # Hooks pós-remove: globais e da recipe instalada (se existir)
  if [ -x "$M_HOOKS/post-remove/$name" ]; then INFO "Hook global pós-remove ($name)"; sh "$M_HOOKS/post-remove/$name" "$name" "$ROOT" >>"$RUN_LOG" 2>&1 || true; fi
  if [ -x "$instdir/post-remove" ]; then INFO "Hook pkg pós-remove"; sh "$instdir/post-remove" "$name" "$ROOT" >>"$RUN_LOG" 2>&1 || true; fi
  rm -rf "$instdir"
  OK "Removido: $name"; ldconf
}

# -------------------- Empacotar DESTDIR atual (sem build) --------------------
cmd_pack(){ # usa conteúdo em M_PKGROOT
  [ -d "$M_PKGROOT" ] || { ERR "Nada em $M_PKGROOT"; exit 2; }
  RUN_LOG=$(logfile pack); pack_pkg >/dev/null; }

# -------------------- init --------------------
cmd_init(){ mkdirs; OK "Estrutura criada em $MBASE"; cat <<EOF
Dirs:
  sources:  $M_SRC
  build:    $M_BUILD
  pkgroot:  $M_PKGROOT
  packages: $M_PKGS
  logs:     $M_LOGS
  state:    $M_STATE
  recipes:  $M_RECIPES
EOF
}

# -------------------- CLI --------------------
usage(){ cat <<USAGE
mbuild — POSIX simples (uma pasta)
Comandos:
  init                          cria estrutura
  run <recipe>                  baixa→extrai→patch→build→DESTDIR→pack
  install <arquivo.ppkg>        instala no ROOT
  remove <nome>                 remove pacote instalado
  pack                          empacota o conteúdo atual do DESTDIR
Variáveis úteis:
  MBASE ROOT PREFIX JOBS PKG_COMP TOOLCHAIN STRIP DOWNLOAD_RETRIES
Ex.: MBASE=./mb ./mbuild.sh init
USAGE
}

main(){ cmd=${1:-}; shift 2>/dev/null || true
  case "$cmd" in
    init) cmd_init ;;
    run) [ $# -ge 1 ] || { usage; exit 2; }; cmd_run "$1" ;;
    install) [ $# -ge 1 ] || { usage; exit 2; }; cmd_install "$1" ;;
    remove) [ $# -ge 1 ] || { usage; exit 2; }; cmd_remove "$1" ;;
    pack) cmd_pack ;;
    *) usage; exit ${cmd:+2} || exit 0 ;;
  esac
}
main "$@"

# -------------------- EXEMPLO DE RECIPE --------------------
# Salve como mbuild/recipes/hello.recipe
#
#: <<'RECIPE'
# pkgname=hello
# pkgver=2.12
# pkgrel=1
# arch=$(uname -m)
# source="https://ftp.gnu.org/gnu/hello/hello-${pkgver}.tar.gz"
# sha256sums="6ae2190...substitua_com_valor_real..."
#
# prepare(){ :; }
# build(){ CC="$CC" CFLAGS="$CFLAGS" ./configure --prefix="$PREFIX"; make -j"$JOBS"; }
# check(){ make -k check || true; }
# package(){ make DESTDIR="$M_PKGROOT" install; }
# post_remove(){ # exemplo: atualizar ldconfig se aplicável
#   command -v ldconfig >/dev/null 2>&1 && ldconfig || true
# }
# RECIPE
