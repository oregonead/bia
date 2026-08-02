#!/bin/bash

# ============================================================
# deploy-com-ia.sh — Deploy e Rollback no ECS para o Projeto BIA
# ============================================================

set -e

# ─── Configurações ───────────────────────────────────────────
REGION="us-east-1"
ECR_REGISTRY="310189683227.dkr.ecr.us-east-1.amazonaws.com"
ECR_REPO="bia"
REPOSITORY_URI="$ECR_REGISTRY/$ECR_REPO"

# ─── Cores para output ───────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# ─── Funções utilitárias ─────────────────────────────────────
log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[AVISO]${NC} $1"; }
log_error()   { echo -e "${RED}[ERRO]${NC} $1"; exit 1; }
log_step()    { echo -e "\n${CYAN}${BOLD}>>> $1${NC}"; }

# ─── Selecionar ambiente ─────────────────────────────────────
selecionar_ambiente() {
  echo ""
  echo -e "${BOLD}Selecione o ambiente:${NC}"
  echo "  1) Sem ALB  (cluster-bia / service-bia / task-def-bia)"
  echo "  2) Com ALB  (cluster-bia-alb / service-bia-alb / task-def-bia-alb)"
  echo ""
  read -rp "Opção [1/2]: " opcao_env

  case "$opcao_env" in
    1)
      CLUSTER="cluster-bia"
      SERVICE="service-bia"
      TASK_FAMILY="task-def-bia"
      log_info "Ambiente selecionado: ${BOLD}Sem ALB${NC}"
      ;;
    2)
      CLUSTER="cluster-bia-alb"
      SERVICE="service-bia-alb"
      TASK_FAMILY="task-def-bia-alb"
      log_info "Ambiente selecionado: ${BOLD}Com ALB${NC}"
      ;;
    *)
      log_error "Opção inválida. Execute o script novamente."
      ;;
  esac
}

# ─── DEPLOY ──────────────────────────────────────────────────
executar_deploy() {
  log_step "INICIANDO DEPLOY"

  # 1. Obter o short commit hash
  COMMIT_HASH=$(git -C "$(dirname "$0")" rev-parse --short HEAD 2>/dev/null) \
    || log_error "Não foi possível obter o commit hash. Certifique-se de estar em um repositório Git."

  log_info "Commit hash: ${BOLD}$COMMIT_HASH${NC}"
  IMAGE_TAG="$COMMIT_HASH"
  FULL_IMAGE_URI="$REPOSITORY_URI:$IMAGE_TAG"

  # 2. Login no ECR
  log_step "Login no ECR"
  aws ecr get-login-password --region "$REGION" \
    | docker login --username AWS --password-stdin "$ECR_REGISTRY" \
    || log_error "Falha ao autenticar no ECR."
  log_success "Autenticado no ECR com sucesso."

  # 3. Build da imagem Docker
  log_step "Build da imagem Docker — tag: $IMAGE_TAG"
  SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
  docker build -t "$REPOSITORY_URI:latest" "$SCRIPT_DIR" \
    || log_error "Falha no build da imagem Docker."
  docker tag "$REPOSITORY_URI:latest" "$FULL_IMAGE_URI"
  log_success "Imagem criada: $FULL_IMAGE_URI"

  # 4. Push para o ECR
  log_step "Push da imagem para o ECR"
  docker push "$REPOSITORY_URI:latest" \
    || log_error "Falha ao fazer push da tag latest."
  docker push "$FULL_IMAGE_URI" \
    || log_error "Falha ao fazer push da tag $IMAGE_TAG."
  log_success "Imagem enviada para o ECR com sucesso."

  # 5. Obter a Task Definition atual e criar nova revisão
  log_step "Registrando nova revisão da Task Definition: $TASK_FAMILY"

  TASK_DEF_JSON=$(aws ecs describe-task-definition \
    --region "$REGION" \
    --task-definition "$TASK_FAMILY" \
    --query "taskDefinition" \
    --output json) \
    || log_error "Não foi possível obter a Task Definition '$TASK_FAMILY'."

  # Extrair o nome do container da task definition atual
  CONTAINER_NAME=$(echo "$TASK_DEF_JSON" | python3 -c \
    "import sys,json; td=json.load(sys.stdin); print(td['containerDefinitions'][0]['name'])")

  # Montar nova containerDefinition com a nova imagem
  NEW_TASK_DEF=$(echo "$TASK_DEF_JSON" | python3 -c "
import sys, json
td = json.load(sys.stdin)
td['containerDefinitions'][0]['image'] = '$FULL_IMAGE_URI'
# Remover campos que não podem ser enviados no registro
for field in ['taskDefinitionArn','revision','status','requiresAttributes',
              'compatibilities','registeredAt','registeredBy']:
    td.pop(field, None)
print(json.dumps(td))
")

  NEW_REVISION=$(aws ecs register-task-definition \
    --region "$REGION" \
    --cli-input-json "$NEW_TASK_DEF" \
    --query "taskDefinition.revision" \
    --output text) \
    || log_error "Falha ao registrar nova Task Definition."

  log_success "Nova revisão registrada: ${BOLD}$TASK_FAMILY:$NEW_REVISION${NC}"

  # 6. Atualizar o ECS Service
  log_step "Atualizando ECS Service: $SERVICE"
  aws ecs update-service \
    --region "$REGION" \
    --cluster "$CLUSTER" \
    --service "$SERVICE" \
    --task-definition "$TASK_FAMILY:$NEW_REVISION" \
    --output json > /dev/null \
    || log_error "Falha ao atualizar o ECS Service."
  log_success "Service atualizado para $TASK_FAMILY:$NEW_REVISION"

  # 7. Aguardar estabilização
  log_step "Aguardando estabilização do serviço (timeout: 10 min)..."
  log_warn "Pressione Ctrl+C para cancelar a espera (o deploy continuará em background)."
  aws ecs wait services-stable \
    --region "$REGION" \
    --cluster "$CLUSTER" \
    --services "$SERVICE" \
    || log_error "Timeout ou falha na estabilização do serviço. Verifique os logs no CloudWatch."

  echo ""
  log_success "✅ Deploy concluído com sucesso!"
  echo -e "   Ambiente : ${BOLD}$CLUSTER${NC}"
  echo -e "   Imagem   : ${BOLD}$FULL_IMAGE_URI${NC}"
  echo -e "   Revisão  : ${BOLD}$TASK_FAMILY:$NEW_REVISION${NC}"
}

# ─── ROLLBACK ────────────────────────────────────────────────
executar_rollback() {
  log_step "INICIANDO ROLLBACK"

  # 1. Listar revisões ativas da Task Definition
  log_info "Buscando revisões da Task Definition: ${BOLD}$TASK_FAMILY${NC}"

  REVISIONS=$(aws ecs list-task-definitions \
    --region "$REGION" \
    --family-prefix "$TASK_FAMILY" \
    --status ACTIVE \
    --sort DESC \
    --query "taskDefinitionArns" \
    --output json) \
    || log_error "Não foi possível listar as revisões da Task Definition."

  REVISION_COUNT=$(echo "$REVISIONS" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))")

  if [ "$REVISION_COUNT" -eq 0 ]; then
    log_error "Nenhuma revisão ativa encontrada para '$TASK_FAMILY'."
  fi

  # 2. Exibir lista de revisões com a imagem de cada uma
  echo ""
  echo -e "${BOLD}Revisões disponíveis para $TASK_FAMILY:${NC}"
  echo -e "─────────────────────────────────────────────────────────"
  printf "  %-5s %-12s %-50s\n" "Nº" "Revisão" "Imagem (tag)"
  echo -e "─────────────────────────────────────────────────────────"

  declare -a REVISION_NUMBERS

  while IFS= read -r arn; do
    REV_NUM=$(echo "$arn" | grep -oP ':\d+$' | tr -d ':')
    IMAGE=$(aws ecs describe-task-definition \
      --region "$REGION" \
      --task-definition "$arn" \
      --query "taskDefinition.containerDefinitions[0].image" \
      --output text 2>/dev/null || echo "N/A")
    IMAGE_TAG=$(echo "$IMAGE" | grep -oP ':[^:]+$' | tr -d ':')
    printf "  %-5s %-12s %-50s\n" "$REV_NUM" "$TASK_FAMILY:$REV_NUM" "$IMAGE_TAG"
    REVISION_NUMBERS+=("$REV_NUM")
  done < <(echo "$REVISIONS" | python3 -c "import sys,json; [print(r) for r in json.load(sys.stdin)]")

  echo -e "─────────────────────────────────────────────────────────"
  echo ""

  # 3. Solicitar escolha do usuário
  read -rp "Digite o número da revisão para fazer rollback: " CHOSEN_REV

  # Validar se a revisão escolhida existe na lista
  VALID=false
  for rev in "${REVISION_NUMBERS[@]}"; do
    if [ "$rev" == "$CHOSEN_REV" ]; then
      VALID=true
      break
    fi
  done

  if [ "$VALID" = false ]; then
    log_error "Revisão '$CHOSEN_REV' não encontrada na lista. Execute o script novamente."
  fi

  TARGET_TASK_DEF="$TASK_FAMILY:$CHOSEN_REV"
  log_info "Revisão selecionada: ${BOLD}$TARGET_TASK_DEF${NC}"

  # 4. Confirmar rollback
  echo ""
  log_warn "Você está prestes a fazer rollback para ${BOLD}$TARGET_TASK_DEF${NC} no cluster ${BOLD}$CLUSTER${NC}."
  read -rp "Confirmar? [s/N]: " CONFIRM

  if [[ "$CONFIRM" != "s" && "$CONFIRM" != "S" ]]; then
    log_warn "Rollback cancelado pelo usuário."
    exit 0
  fi

  # 5. Atualizar o ECS Service para a revisão escolhida
  log_step "Aplicando rollback para $TARGET_TASK_DEF"
  aws ecs update-service \
    --region "$REGION" \
    --cluster "$CLUSTER" \
    --service "$SERVICE" \
    --task-definition "$TARGET_TASK_DEF" \
    --output json > /dev/null \
    || log_error "Falha ao atualizar o ECS Service."
  log_success "Service atualizado para $TARGET_TASK_DEF"

  # 6. Aguardar estabilização
  log_step "Aguardando estabilização do serviço (timeout: 10 min)..."
  log_warn "Pressione Ctrl+C para cancelar a espera (o rollback continuará em background)."
  aws ecs wait services-stable \
    --region "$REGION" \
    --cluster "$CLUSTER" \
    --services "$SERVICE" \
    || log_error "Timeout ou falha na estabilização do serviço. Verifique os logs no CloudWatch."

  echo ""
  log_success "✅ Rollback concluído com sucesso!"
  echo -e "   Ambiente  : ${BOLD}$CLUSTER${NC}"
  echo -e "   Revisão   : ${BOLD}$TARGET_TASK_DEF${NC}"
}

# ─── MENU PRINCIPAL ──────────────────────────────────────────
echo ""
echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${CYAN}║     BIA — Deploy & Rollback no ECS       ║${NC}"
echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════╝${NC}"
echo ""
echo -e "${BOLD}O que deseja fazer?${NC}"
echo "  1) Deploy  (build + push + nova revisão + atualizar service)"
echo "  2) Rollback (listar revisões e reverter)"
echo ""
read -rp "Opção [1/2]: " opcao_acao

case "$opcao_acao" in
  1) selecionar_ambiente; executar_deploy   ;;
  2) selecionar_ambiente; executar_rollback ;;
  *) log_error "Opção inválida. Execute o script novamente." ;;
esac
