#!/usr/bin/env bash
# Abre o OpenCode isolado em um container Podman rootless.
# Ele enxerga apenas a pasta do projeto e a rede interna (so o Ollama).
#
# Uso:
#   opencode                      abre na pasta em que voce esta agora
#   opencode ~/dev/projeto        abre na pasta indicada
#   opencode ~/dev/projeto -c     argumentos extras vao para o OpenCode
#
# Modo online (manutencao), para instalar plugins npm ou usar algo que precise
# de internet. Pede confirmacao e vale so para esta sessao:
#   OPENCODE_ONLINE=1 opencode
# O que for instalado fica no volume opencode-cache e continua funcionando
# depois, no modo normal (offline).
#
# Skills e plugins locais: se existirem, estas pastas sao montadas somente
# leitura nas pastas globais do OpenCode:
#   ~/.config/hub-llm/skills   ->  /root/.config/opencode/skills
#   ~/.config/hub-llm/plugins  ->  /root/.config/opencode/plugins
#
# Versao da imagem oficial (ghcr.io/anomalyco/opencode):
#   OPENCODE_TAG=1.15.0 opencode        ou edite o valor padrao abaixo.
#   Para descobrir a versao atual:
#     podman run --rm ghcr.io/anomalyco/opencode:latest --version
#   Para reconstruir apos mudar a versao ou o Containerfile:
#     podman rmi localhost/opencode-hub:<tag>
#
# Arquivos de apoio (Containerfile.opencode e opencode.json): o script procura,
# nesta ordem, em:
#   1. $OPENCODE_HUB_DIR (se definida)
#   2. a pasta onde o proprio script esta
#   3. ~/.config/hub-llm            <- recomendado quando o script esta no PATH
#
# Requer que o Ollama ja esteja de pe (compose.rocm.yml ou compose.vulkan.yml).
set -euo pipefail

# Resolve o caminho real do script, mesmo quando chamado por symlink ou alias
SCRIPT="$(readlink -f "${BASH_SOURCE[0]}")"
HERE="$(dirname "$SCRIPT")"
OPENCODE_TAG="${OPENCODE_TAG:-latest}"     # recomendado: fixar uma versao
IMAGE="localhost/opencode-hub:${OPENCODE_TAG}"
NETWORK="hub-llm-backend"
EGRESS_NETWORK="hub-llm-egress"
ONLINE="${OPENCODE_ONLINE:-0}"

find_conf_dir() {
  local d
  for d in "${OPENCODE_HUB_DIR:-}" "$HERE" "$HOME/.config/hub-llm"; do
    if [ -n "$d" ] && [ -f "$d/Containerfile.opencode" ] && [ -f "$d/opencode.json" ]; then
      echo "$d"
      return 0
    fi
  done
  return 1
}

if ! CONF_DIR="$(find_conf_dir)"; then
  echo "Nao encontrei Containerfile.opencode e opencode.json." >&2
  echo "Copie os dois para ~/.config/hub-llm/ ou defina OPENCODE_HUB_DIR." >&2
  exit 1
fi

# Primeiro argumento: se for uma pasta existente, e o projeto.
# Caso contrario, usa a pasta atual e repassa os argumentos ao OpenCode.
if [ $# -gt 0 ] && [ -d "$1" ]; then
  PROJECT_DIR="$(realpath "$1")"
  shift
else
  PROJECT_DIR="$(pwd -P)"
fi

deny() {
  echo "Recusado: $PROJECT_DIR" >&2
  echo "Entre em uma pasta de projeto dedicada (ou passe o caminho dela) e tente de novo." >&2
  exit 1
}

# Protecao: nunca monte a home, a raiz, pastas de sistema nem pastas de credenciais
case "$PROJECT_DIR" in
  "$HOME"|/|/etc|/usr|/var|/boot|/root|/home|/mnt|/media|/tmp|/opt) deny ;;
esac
for d in .ssh .gnupg .aws .kube .azure .docker .config .local .password-store; do
  case "$PROJECT_DIR" in
    "$HOME/$d"|"$HOME/$d"/*) deny ;;
  esac
done

# O agente altera arquivos de verdade. Peca confirmacao fora de repositorios git.
if [ ! -d "$PROJECT_DIR/.git" ]; then
  echo "Aviso: $PROJECT_DIR nao e a raiz de um repositorio git."
  echo "O OpenCode vai poder ler e alterar tudo nesta pasta, e sem git fica dificil reverter."
  read -r -p "Continuar? [s/N] " resp
  case "$resp" in
    s|S|y|Y) ;;
    *) echo "Cancelado."; exit 1 ;;
  esac
fi

if ! podman network exists "$NETWORK"; then
  echo "Rede $NETWORK nao existe. Suba o compose primeiro." >&2
  exit 1
fi

NET_ARGS=(--network "$NETWORK")
case "$ONLINE" in
  1|true|yes|s|sim) ONLINE=1 ;;
  *) ONLINE=0 ;;
esac
if [ "$ONLINE" = 1 ]; then
  if ! podman network exists "$EGRESS_NETWORK"; then
    echo "Rede $EGRESS_NETWORK nao existe. Suba o compose primeiro." >&2
    exit 1
  fi
  echo "ATENCAO: modo ONLINE. O OpenCode vai ter acesso a internet nesta sessao."
  echo "Um prompt injection pode enviar o conteudo de $PROJECT_DIR para fora."
  echo "Use so para instalar plugins ou tarefas pontuais, e saia ao terminar."
  read -r -p "Liberar a internet para esta sessao? [s/N] " resp
  case "$resp" in
    s|S|y|Y) NET_ARGS+=(--network "$EGRESS_NETWORK") ;;
    *) echo "Cancelado."; exit 1 ;;
  esac
fi

# Skills e plugins locais, montados so se as pastas existirem
EXTRA_MOUNTS=()
for kind in skills plugins; do
  if [ -d "$CONF_DIR/$kind" ]; then
    EXTRA_MOUNTS+=(-v "$CONF_DIR/$kind":/root/.config/opencode/"$kind":ro,z)
  fi
done

if ! podman image exists "$IMAGE"; then
  podman build --pull=newer \
    --build-arg "OPENCODE_TAG=${OPENCODE_TAG}" \
    -t "$IMAGE" -f "$CONF_DIR/Containerfile.opencode" "$CONF_DIR"
fi

if [ "$ONLINE" = 1 ]; then
  echo "OpenCode em: $PROJECT_DIR (imagem $IMAGE) [ONLINE]"
else
  echo "OpenCode em: $PROJECT_DIR (imagem $IMAGE) [offline]"
fi

# A imagem roda como root. No Podman rootless, o root do container e mapeado para
# o seu usuario no host, entao os arquivos do projeto continuam sendo seus
# (por isso nao usamos --userns=keep-id aqui).
# OPENCODE_CONFIG aponta a config explicitamente, sem depender do $HOME da imagem.
# :Z (privado) na pasta do projeto; :z (compartilhado) no opencode.json, para
# varias sessoes simultaneas nao tirarem o acesso uma da outra.
# Sem --name fixo, para poder abrir varios projetos ao mesmo tempo.
# No modo online o container entra tambem na rede egress (podman aceita
# varios --network); no modo normal fica so na backend, sem internet.
exec podman run --rm -it \
  "${NET_ARGS[@]}" \
  --cap-drop=ALL \
  --security-opt no-new-privileges \
  --memory 4g \
  --pids-limit 512 \
  -w /workspace \
  -v "$PROJECT_DIR":/workspace:Z \
  -v "$CONF_DIR/opencode.json":/etc/opencode/opencode.json:ro,z \
  -e OPENCODE_CONFIG=/etc/opencode/opencode.json \
  -v opencode-data:/root/.local/share/opencode \
  -v opencode-cache:/root/.cache/opencode \
  "${EXTRA_MOUNTS[@]}" \
  "$IMAGE" "$@"
