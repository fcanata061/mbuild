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
#   ./mbuild.sh remove hello                         # remove e roda pós-remove
#   VAR=valor ./mbuild.sh ...                        # sobrepõe variáveis
#
# Recipe: arquivo POSIX que define ao menos:
#   pkgname, pkgver, pkgrel, arch, source (URLs separados por espaço, opcional patches)
#   (opcional) sha256sums (na mesma ordem de source)
#   (opcional) prepare(), build(), check(), package()
#   Hooks pós-remove: coloque um script em $M_PKGROOT/CONTROL/post-remove dentro da função package()
#   (Ex.: durante package():  install -Dm755 ./post-remove "$M_PKGROOT/CONTROL/post-remove")
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
: "${PKG_COMP:=zst}"                  # gz|bz2|xz|zst|none
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
logfile(){ b=${1:-general}; printf '%s/%s-%s.log' "$M_LOGS" "$b" "$(date +%Y%m%d-%H%M%S)"; }
INFO(){ printf "%s[*]%s %s\n" "$C_BLU" "$C_RST" "$*"; }
OK(){   printf "%s[OK]%s %s\n" "$C_GRN" "$C_RST" "$*"; }
WARN(){ printf "%s[!]%s %s\n" "$C_YLW" "$C_RST" "$*"; }
ERR(){  printf "%s[ERR]%s %s\n" "$C_RED" "$C_RST" "$*"; }

# -------------------- Spinner --------------------
_spinner(){ msg=$1; i=0; s='|/-\\'; while :; do i=$(( (i+1) % 4 )); printf "\r[%c] %s" "$(printf %s "$s" | cut -c $((i+1)))" "$msg"; sleep 0.1; done; }
runspin(){ msg=$1; shift; _spinner "$msg" & _spid=$!; ("$@") >>"$RUN_LOG" 2>&1 || _rc=$?; kill "$_spid" 2>/dev/null || true; wait "$_spid" 2>/dev/null || true; printf "\r"; return ${_rc:-0}; }

# -------------------- Utilitários --------------------
mkdirs(){ mkdir -p "$M_SRC" "$M_BUILD" "$M_PKGROOT" "$M_PKGS" "$M_LOGS" "$M_STATE/pkgs" "$M_RECIPES" "$M_HOOKS/post-remove"; }

need_one(){ # any of args must exist
  for b in "$@"; do command -v "$b" >/dev/null 2>&1 && return 0; done
  return 1
}

check_deps(){
  need_one curl wget || { ERR "precisa de curl ou wget"; exit 1; }
  command -v tar >/dev/null 2>&1 || { ERR "precisa de tar"; exit 1; }
  command -v patch >/dev/null 2>&1 || WARN "patch não encontrado (aplicar patches pode falhar)"
  command -v make  >/dev/null 2>&1 || WARN "make não encontrado (build pode falhar)"
  command -v file  >/dev/null 2>&1 || WARN "file não encontrado (detecção de ELF p/ strip limitada)"
  command -v unzip >/dev/null 2>&1 || WARN "unzip não encontrado (extração .zip indisponível)"
}

sha256_check(){ # args: file expected_sum
  [ -n "${2:-}" ] || return 0
  if command -v sha256sum >/dev/null 2>&1; then
    echo "$2  $1" | sha256sum -c - >/dev/null
  elif command -v shasum >/dev/null 2>&1; then
    echo "$2  $1" | shasum -a 256 -c - >/dev/null
  else
    WARN "sha256sum/shasum não disponível; pulando verificação"
  fi
}

_fetch_curl(){ curl $CURL_OPTS -o "$2" "$1"; }
_fetch_wget(){ wget -O "$2" "$1"; }

fetch(){ url=$1; out=$2; sum=${3:-}; [ -f "$out" ] || {
  INFO "Baixando $url"
  i=0
  while [ $i -lt "$DOWNLOAD_RETRIES" ]; do
    i=$((i+1))
    if command -v curl >/dev/null 2>&1; then _fetch_curl "$url" "$out" >>"$RUN_LOG" 2>&1
    else _fetch_wget "$url" "$out" >>"$RUN_LOG" 2>&1
    fi && break
    WARN "retry $i"
    sleep $i
  done
}
  [ -n "$sum" ] && sha256_check "$out" "$sum"
}

extract(){ arc=$1; dest=$2; INFO "Extraindo $(basename "$arc")"; mkdir -p "$dest"
  case "$arc" in
    *.tar.gz|*.tgz)   tar -xzf "$arc" -C "$dest" ;;
    *.tar.bz2|*.tbz2) tar -xjf "$arc" -C "$dest" ;;
    *.tar.xz|*.txz)   tar -xJf "$arc" -C "$dest" ;;
    *.tar.zst|*.tzst)
       if tar --help 2>/dev/null | grep -q zstd; then
         tar --zstd -xf "$arc" -C "$dest"
       elif command -v zstd >/dev/null 2>&1; then
         zstd -dc "$arc" | tar -xf - -C "$dest"
       else
         ERR "tar zstd não suportado e zstd ausente"
         return 2
       fi ;;
    *.zip)            unzip -q "$arc" -d "$dest" ;;
    *)                tar -xf "$arc" -C "$dest" ;;
  esac >>"$RUN_LOG" 2>&1
}

apply_patch(){ p=$1; [ -f "$p" ] || return 0; INFO "Aplicando patch $(basename "$p")"; patch -Np1 < "$p" >>"$RUN_LOG" 2>&1; }

mkmeta(){ # escreve CONTROL/meta a partir das variáveis da recipe
  d=$1; { echo "name=$pkgname"; echo "version=$pkgver"; echo "release=$pkgrel"; echo "arch=$arch"; echo "prefix=$PREFIX"; } > "$d/CONTROL/meta"
}

mkmanifest(){ root=$1; man=$2; : > "$man"; ( cd "$root" && find . -type f -o -type l | while IFS= read -r f; do printf '%s\n' "$f"; done ) > "$man"; }

pack_pkg(){ # cria .ppkg a partir de $M_PKGROOT
  out="$M_PKGS/${pkgname}-${pkgver}-${pkgrel}.${arch}.ppkg"
  INFO "Empacotando $(basename "$out")"
  mkdir -p "$M_PKGROOT/CONTROL"
  mkmeta "$M_PKGROOT"
  mkmanifest "$M_PKGROOT" "$M_PKGROOT/CONTROL/manifest"
  case "$PKG_COMP" in
    gz)  compflag=-z ;;
    bz2) compflag=-j ;;
    xz)  compflag=-J ;;
    zst) compflag=--zstd ;;
    none|"") compflag= ;;
    *) WARN "PKG_COMP desconhecido: $PKG_COMP; usando sem compressão"; compflag= ;;
  esac
  ( cd "$M_PKGROOT" && tar ${compflag:+$compflag} -cf "$out" . ) >>"$RUN_LOG" 2>&1
  OK "Pacote: $out"; echo "$out"
}

ldconf(){ command -v ldconfig >/dev/null 2>&1 && ldconfig >>"$RUN_LOG" 2>&1 || true; }

# -------------------- Defaults de build/package --------------------
default_prepare(){ :; }
default_build(){ if [ -x ./configure ]; then CC="$CC" CFLAGS="$CFLAGS" LDFLAGS="$LDFLAGS" ./configure --prefix="$PREFIX"; fi; make -j"$JOBS"; }
default_check(){ make -k check || true; }
default_package(){ make DESTDIR="$M_PKGROOT" install; }

# -------------------- Carregar recipe --------------------
fn_or_default(){ command -v "$1" >/dev/null 2>&1 && printf %s "$1" || printf %s "$2"; }

load_recipe(){
  RECIPE=$1
  # shellcheck disable=SC1090
  set +u; . "$RECIPE"; set -u
  : "${pkgname:?recipe: defina pkgname}"
  : "${pkgver:?defina pkgver}"
  : "${pkgrel:=1}"
  : "${arch:=$(uname -m)}"
  : "${source:?defina source}"
  : "${patches:=}"
  : "${sha256sums:=}"
  PREPARE=$(fn_or_default prepare default_prepare)
  BUILD=$(fn_or_default build default_build)
  CHECK=$(fn_or_default check default_check)
  PACKAGE=$(fn_or_default package default_package)
}

# -------------------- Fluxo run (source→build→pack) --------------------
cmd_run(){
  check_deps
  recipe=$1; mkdirs
  INFO "Recipe: $recipe"
  load_recipe "$recipe"
  RUN_LOG=$(logfile "${pkgname}-run")
  INFO "Log: $RUN_LOG"

  # 1) Fetch todas as fontes
  i=1
  set +f
  OLD_IFS=$IFS; IFS=' '
  for url in $source; do
    sum=$(printf '%s\n' "$sha256sums" | awk -v n=$i '{print $n}')
    arc="$M_SRC/$(basename "$url")"
    runspin "fetch $(basename "$url")" fetch "$url" "$arc" "${sum:-}" || { ERR "Falha no download de $(basename "$url")"; exit 3; }
    i=$((i+1))
  done
  IFS=$OLD_IFS; set -f

  # 2) Extrair primeira fonte em M_BUILD/pkgname-pkgver
  rm -rf "$M_BUILD/${pkgname}-${pkgver}" "$M_PKGROOT"
  mkdir -p "$M_BUILD" "$M_PKGROOT"
  first=$(printf '%s\n' $source | awk 'NR==1{print}')
  extract "$M_SRC/$(basename "$first")" "$M_BUILD"
  SRCDIR="$M_BUILD/${pkgname}-${pkgver}"
  [ -d "$SRCDIR" ] || SRCDIR=$(find "$M_BUILD" -maxdepth 1 -type d -name "${pkgname}*" | head -n1)
  [ -n "$SRCDIR" ] && [ -d "$SRCDIR" ] || { ERR "Diretório de fonte não encontrado"; exit 4; }
  cd "$SRCDIR"

  # 3) Patches
  for p in $patches; do apply_patch "$p"; done

  # 4) prepare/build/check/package (chama funções diretamente)
  runspin "prepare $pkgname" "$PREPARE" || true
  runspin "build $pkgname"   "$BUILD"
  runspin "check $pkgname"   "$CHECK" || true
  runspin "package $pkgname" "$PACKAGE"

  # 5) strip opcional (corrige passagem de args ao sh -c)
  if [ "$STRIP" = "1" ] && command -v strip >/dev/null 2>&1; then
    INFO "Strip ELF"
    find "$M_PKGROOT" -type f -perm -111 -exec sh -c '
      f=$1
      if command -v file >/dev/null 2>&1; then
        if file -bi "$f" | grep -qi "executable\|sharedlib"; then
          strip --strip-unneeded "$f" || true
        fi
      else
        # fallback tosco: tenta strip de qualquer executável
        strip --strip-unneeded "$f" 2>/dev/null || true
      fi
    ' sh {} \; >>"$RUN_LOG" 2>&1
  fi

  # 6) empacotar
  PKGFILE=$(pack_pkg)
  OK "Build concluído: $PKGFILE"
}

# -------------------- Instalar pacote binário no ROOT --------------------
cmd_install(){
  pkg=$1; mkdirs; RUN_LOG=$(logfile install)
  INFO "Instalando $pkg em $ROOT"
  tmp=$(mktemp -d)
  case "$pkg" in /*) src="$pkg";; *) src="$M_PKGS/$pkg";; esac
  [ -f "$src" ] || { ERR "Pacote não encontrado: $src"; rm -rf "$tmp"; exit 2; }
  ( cd "$tmp" && tar -xf "$src" ) >>"$RUN_LOG" 2>&1

  # Scripts de controle
  if [ -d "$tmp/CONTROL/scripts" ]; then PR="$tmp/CONTROL/scripts"; else PR="$tmp/CONTROL"; fi

  # Copiar DATA para ROOT (tudo que não é CONTROL)
  ( cd "$tmp" && { for f in ./*; do [ "$(basename "$f")" = "CONTROL" ] && continue; tar -cf - "$f"; done; } ) | ( cd "$ROOT" && tar -xf - )

  # Registrar manifest
  name=$(grep '^name=' "$tmp/CONTROL/meta" | cut -d= -f2)
  ver=$(grep '^version=' "$tmp/CONTROL/meta" | cut -d= -f2)
  rel=$(grep '^release=' "$tmp/CONTROL/meta" | cut -d= -f2)
  pkgid="$name-$ver-$rel"
  instdir="$M_STATE/pkgs/$name"
  mkdir -p "$instdir"
  cp "$tmp/CONTROL/meta" "$instdir/meta"
  cp "$tmp/CONTROL/manifest" "$instdir/manifest"
  [ -f "$PR/post-remove" ] && install -Dm755 "$PR/post-remove" "$instdir/post-remove" || true
  printf '%s %s\n' "$(date +%FT%T)" "$pkgid" >> "$M_STATE/installed.index" 2>/dev/null || true

  OK "Instalado: $pkgid"
  ldconf
  rm -rf "$tmp"
}

# -------------------- Remover pacote do ROOT --------------------
cmd_remove(){
  name=$1; mkdirs; RUN_LOG=$(logfile remove)
  instdir="$M_STATE/pkgs/$name"; [ -d "$instdir" ] || { ERR "$name não está instalado"; exit 2; }
  INFO "Removendo $name de $ROOT"
  man="$instdir/manifest"

  # remover na ordem inversa
  tac_cmd(){
    if command -v tac >/dev/null 2>&1; then tac "$1"
    elif command -v tail >/dev/null 2>&1 && tail -r /dev/null >/dev/null 2>&1; then tail -r "$1"   # BSD
    else awk '{a[NR]=$0} END{ for(i=NR;i>=1;i--) print a[i] }' "$1"
    fi
  }
  tac_cmd "$man" | while IFS= read -r f; do
    [ -z "$f" ] && continue
    path="$ROOT/${f#./}"
    [ -e "$path" -o -L "$path" ] && rm -f "$path" || true
  done >>"$RUN_LOG" 2>&1

  # Limpar diretórios vazios (melhor esforço)
  awk -F/ '{p=""; for(i=1;i<=NF;i++){p=p (i==1?$1:"/"$i); print p}}' "$man" \
    | sort -u -r | while IFS= read -r d; do
      dp="$ROOT/${d#./}"; [ -d "$dp" ] && rmdir "$dp" 2>/dev/null || true
    done >>"$RUN_LOG" 2>&1

  # Hooks pós-remove: globais e do pacote (se existir)
  if [ -x "$M_HOOKS/post-remove/$name" ]; then INFO "Hook global pós-remove ($name)"; sh "$M_HOOKS/post-remove/$name" "$name" "$ROOT" >>"$RUN_LOG" 2>&1 || true; fi
  if [ -x "$instdir/post-remove" ]; then INFO "Hook pkg pós-remove"; sh "$instdir/post-remove" "$name" "$ROOT" >>"$RUN_LOG" 2>&1 || true; fi

  rm -rf "$instdir"
  OK "Removido: $name"
  ldconf
}

# -------------------- Empacotar DESTDIR atual (sem build) --------------------
cmd_pack(){ [ -d "$M_PKGROOT" ] || { ERR "Nada em $M_PKGROOT"; exit 2; }; RUN_LOG=$(logfile pack); pack_pkg >/dev/null; }

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

main(){
  cmd=${1:-}; shift 2>/dev/null || true
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
# sha256sums="SUBSTITUA_PELO_SHA256_REAL"
#
# prepare(){ :; }
# build(){ CC="$CC" CFLAGS="$CFLAGS" ./configure --prefix="$PREFIX"; make -j"$JOBS"; }
# check(){ make -k check || true; }
# package(){
#   make DESTDIR="$M_PKGROOT" install
#   # (opcional) inclua hook pós-remove no pacote:
#   # install -Dm755 "./post-remove.sh" "$M_PKGROOT/CONTROL/post-remove"
# }
# RECIPE
