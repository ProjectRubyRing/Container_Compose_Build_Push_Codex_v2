#!/usr/bin/env bash
#
# build_and_push.sh
# -----------------------------------------------------------------------------
# 想定実行環境: RHEL 9.6 の EC2 インスタンス (bash / GNU coreutils / Docker CE)。
#
# compose.yml で定義したローカルベースイメージ (既定: j1/base.local) を
# docker compose build でビルドし、ECR へタグ付けしてプッシュ、結果として
# imagedefinition.json を出力する。
#
# 権限まわりの前提:
#   - スクリプト開始時に、事前に aws login --remote による認証操作が実行されて
#     いるかをチェックし、未認証の場合は認証を促す警告を出して終了する (exit 1)。
#   - このステージでは CodeCommit の操作は不要。ECR の操作権限のみが必要。
#   - 現在の操作権限で ECR を操作できない場合の挙動を 2 通りから選べる:
#       (A) 既定 (--warn-only)  : スイッチバックを促す警告を出して終了 (exit 1)
#       (B)     (--auto-switchback): 別チーム提供のスイッチバック用シェルを
#                                    source で呼び出し、自動的にスイッチバック
#                                    してから処理を継続する。
#   - スイッチバック用シェルの配置場所は --switchback-shell で指定可能。
#
# JBoss マスターパスワード (BuildKit シークレット):
#   - ビルド前に、パラメータストアの指定キー (--jboss-password-param) から
#     JBoss のマスターパスワードを取得できる。パラメータストアから取得せず
#     直接渡す (--jboss-password) ことも可能。
#   - 取得したマスターパスワードは環境変数 (--jboss-password-env, 既定:
#     JBOSS_MASTER_PASSWORD) へ export し、compose.yml の environment 型
#     シークレット定義を通じて BuildKit シークレットとして安全にビルドへ
#     注入する (イメージのレイヤや履歴には残らない)。
#
# 使い方:
#   ./build_and_push.sh --account-id 123456789012 --region ap-northeast-1 \
#       --jboss-password-param /j1/jboss/master-password \
#       --auto-switchback --switchback-shell /opt/team/switchback.sh
# -----------------------------------------------------------------------------

set -uo pipefail

# ---- 既定値 -----------------------------------------------------------------
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-ap-northeast-1}}"
ACCOUNT_ID="${AWS_ACCOUNT_ID:-}"
REGISTRY="${ECR_REGISTRY:-}"      # ECR レジストリ名(URL)。未指定なら <account>.dkr.ecr.<region>.amazonaws.com を組み立てる
REPOSITORY="BaseImage"            # ECR 側リポジトリ名 (= プッシュするイメージ名)
TAG_PREFIX="BaseImage"            # イメージタグの接頭辞。タグは <TAG_PREFIX>-<YYYYMMDDHHMMSS> となる (リポジトリ名とは独立)
LOCAL_IMAGE="j1/base.local"       # compose build で生成されるローカルベースイメージ名
CONTAINER_NAME=""                 # imagedefinition.json の name。未指定なら REPOSITORY を使用
COMPOSE_FILE="compose.yml"
COMPOSE_SERVICE=""                # 指定時はそのサービスのみビルド
NO_CACHE="false"                  # true: キャッシュを破棄してビルド (--no-cache)
OUTPUT_FILE="imagedefinition.json"
ECR_USERNAME="AWS"                # ECR ログイン時の固定ユーザー名
DRY_RUN="false"                   # true: 実際の変更は行わず、実行内容のプレビューのみ表示
LOG_DIR=""                        # 指定時: コンソール出力をこのディレクトリのログファイルにも保存する
LOG_FILE=""                       # --log-dir 指定時に組み立てる実際のログファイルパス

# ビルドのみを実行する処理は build_and_verify.sh に切り出した。
# --build-only 指定時はこのスクリプト冒頭で build_and_verify.sh に委譲する。
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_VERIFY_SCRIPT="${SCRIPT_DIR}/build_and_verify.sh"

# ビルド前に一時コピーし、ビルド後に自動削除するファイル群
# COPY_SPECS: "SRC:DEST_DIR" の配列 (--copy-file で繰り返し指定)
# COPIED_FILES: 実際にコピーしたコピー先ファイルパス (削除対象として記録)
COPY_SPECS=()
COPIED_FILES=()

# スイッチバック関連
SWITCHBACK_SHELL="${SWITCHBACK_SHELL:-}"
AUTO_SWITCHBACK="false"           # false: 警告して終了 / true: 自動スイッチバック

# JBoss マスターパスワード (BuildKit シークレット) 関連
JBOSS_PASSWORD_PARAM=""           # パラメータストアのキー名 (--jboss-password-param)
JBOSS_PASSWORD_VALUE=""           # 直接指定されたマスターパスワード (--jboss-password)
JBOSS_PASSWORD_ENV="JBOSS_MASTER_PASSWORD"  # シークレット受け渡しに使う環境変数名
JBOSS_PASSWORD_ENV_SET="false"    # --jboss-password-env が明示指定されたか
JBOSS_SECRET_ENABLED="false"      # マスターパスワードをビルドシークレットとして注入するか

# ---- ログ用ヘルパ -----------------------------------------------------------
# スクリプト開始時刻 (処理実行時間の算出に使用)
START_EPOCH="$(date +%s)"
log()  { printf '[%s] %s\n'  "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
warn() { printf '[%s] [WARN] %s\n'  "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }
err()  { printf '[%s] [ERROR] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }
# 診断ガイド出力用 (タイムスタンプ等の接頭辞を付けず、そのまま整形表示する)
diag() { printf '%s\n' "$*" >&2; }
# dry-run 時は実行内容を表示するだけ、通常時はそのままコマンドを実行する。
run()  {
  if [ "$DRY_RUN" = "true" ]; then
    printf '[%s] [DRY-RUN] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
    return 0
  fi
  "$@"
}

# 開始時刻からの経過時間 (処理実行時間) を人間可読な形式でログ出力する。
# EXIT トラップから呼ばれるため、成功・失敗いずれの経路でも記録される。
log_elapsed() {
  local end_epoch elapsed
  end_epoch="$(date +%s)"
  elapsed=$(( end_epoch - START_EPOCH ))
  log "処理実行時間: ${elapsed} 秒 ($(printf '%02d:%02d:%02d' \
      "$(( elapsed / 3600 ))" "$(( (elapsed % 3600) / 60 ))" "$(( elapsed % 60 ))"))"
}

usage() {
  cat <<'EOF'
Usage: build_and_push.sh [OPTIONS]

Options:
  --account-id ID          ECR レジストリの AWS アカウント ID (env: AWS_ACCOUNT_ID)
  --region REGION          AWS リージョン (既定: ap-northeast-1 / env: AWS_REGION)
  --registry URL           ECR レジストリ名(URL) を明示指定 (env: ECR_REGISTRY)
                           例: 123456789012.dkr.ecr.ap-northeast-1.amazonaws.com
                           (未指定時は <account-id>.dkr.ecr.<region>.amazonaws.com を組み立て)
  --repository NAME        ECR リポジトリ名 = プッシュするイメージ名 (既定: BaseImage)
  --tag-prefix PREFIX      イメージタグの接頭辞 (既定: BaseImage)。リポジトリ名とは独立に
                           指定でき、タグは <PREFIX>-<YYYYMMDDHHMMSS> となる
                           例: BaseImage-20260702153000
  --local-image NAME       compose build で生成されるローカルイメージ名 (既定: j1/base.local)
  --container-name NAME    imagedefinition.json の name (既定: --repository の値)
  --compose-file FILE      compose ファイル (既定: compose.yml)
  --compose-service NAME   ビルド対象サービス名 (未指定なら全サービス)
  --no-cache               キャッシュを破棄して compose build する
  --output FILE            imagedefinition の出力先 (既定: imagedefinition.json)
  --log-dir DIR            コンソールに出力されるログを、DIR 配下のログファイルにも
                           保存する (画面表示は従来どおり継続)。ログ末尾には処理実行
                           時間 (経過秒数) も記録される。
                           - DIR が存在しない場合は自動作成する (mkdir -p)
                           - ファイル名は build_and_push_<YYYYMMDDHHMMSS>.log
                           - --build-only 委譲時も、委譲先の出力を含めて記録する
  --dry-run                実際のビルド/ログイン/タグ付け/プッシュ/ファイル出力は
                           行わず、実行される内容のプレビューのみ表示する
  --build-only             ビルドのみを実行する (処理は build_and_verify.sh に委譲)。
                           ECR 権限チェック/ログイン/タグ付け/プッシュ/imagedefinition の
                           出力は行わない。--copy-file が指定されている場合は、ビルド前に
                           事前ファイルコピーを行い (ビルド後に自動削除)、その上でビルドする。
                           起動確認 (--verify-startup) や URL 応答確認 (--verify-url) 等の
                           追加オプションも build_and_verify.sh に委譲されるため利用できる。
                           詳細は ./build_and_verify.sh --help を参照。

  --copy-file SRC:DEST_DIR ビルド前に SRC を DEST_DIR ディレクトリへコピーし、
                           ビルド終了後 (成功・失敗を問わず) に自動削除する。
                           複数ファイルに対応するため繰り返し指定できる。
                           例: --copy-file .npmrc ./app --copy-file cert.pem ./app/certs
                           - DEST_DIR は既存ディレクトリである必要がある
                           - コピー先に同名ファイルが既存の場合は事故防止のため中止する

  --jboss-password-param NAME
                           JBoss のマスターパスワードを AWS パラメータストア
                           (SSM Parameter Store) の指定キー NAME から取得する
                           (aws ssm get-parameter --with-decryption)。
                           取得した値は --jboss-password-env の環境変数へ export され、
                           compose.yml の environment 型シークレット定義を通じて
                           BuildKit シークレットとしてビルドに注入される。
  --jboss-password VALUE   JBoss のマスターパスワードを直接指定する
                           (パラメータストアから取得しない場合)。
                           --jboss-password-param とは同時に指定できない。
                           ※ コマンドライン (ps / シェル履歴) に平文が残るため、
                             可能なら --jboss-password-param か、事前 export +
                             --jboss-password-env の利用を推奨。
  --jboss-password-env NAME
                           シークレットの受け渡しに使う環境変数名
                           (既定: JBOSS_MASTER_PASSWORD)。compose.yml の
                           secrets の environment: と一致させること。
                           このオプションのみを指定した場合は、事前に export
                           済みの環境変数の値をそのままパスワードとして使う。

  --switchback-shell PATH  別チーム提供のスイッチバック用シェルのパス (source で呼び出し)
  --auto-switchback        ECR 権限が無い場合に自動でスイッチバックして継続する
  --warn-only              ECR 権限が無い場合に警告して終了する (既定)

  -h, --help               このヘルプを表示

備考:
  スクリプト開始時に AWS 認証 (aws login --remote 実施済みか) を確認し、
  未認証の場合は認証を促す警告を表示して終了する (exit 1)。
EOF
}

# ---- ログファイル出力の準備 (build-only 委譲より前に行う) --------------------
# --log-dir を先に解釈し、以降のコンソール出力 (stdout/stderr) を tee でログファイル
# へ複製する。画面表示はそのまま継続し、時系列の順序を保つため stdout/stderr を
# 同一の tee にまとめる。--build-only による委譲時 (下の for ループ) にも出力を
# 取りこぼさないよう、引数パースより前のこの位置で設定しておく。
# ここでは --log-dir の値取得のみを行い、後段の本パースでも同オプションを受理する。
_prev_arg=""
for _arg in "$@"; do
  if [ "$_prev_arg" = "--log-dir" ]; then LOG_DIR="$_arg"; break; fi
  _prev_arg="$_arg"
done
if [ -n "$LOG_DIR" ]; then
  if ! mkdir -p "$LOG_DIR"; then
    err "ログ出力先ディレクトリを作成できませんでした: $LOG_DIR"
    exit 1
  fi
  LOG_FILE="${LOG_DIR%/}/build_and_push_$(date '+%Y%m%d%H%M%S').log"
  # 以降の全出力を tee で LOG_FILE にも書き込む (画面にも出力)
  exec > >(tee -a "$LOG_FILE") 2>&1
  # このパス以降のどの経路 (build-only 委譲・途中 exit 含む) でも処理実行時間を残す。
  # 後段でコピーファイル削除も伴うトラップに差し替える。
  trap log_elapsed EXIT
  log "コンソール出力をログファイルにも保存します: $LOG_FILE"
fi

# ---- --build-only は build_and_verify.sh へ委譲する -------------------------
# ビルドのみを実行する処理は build_and_verify.sh に切り出してある。
# --build-only が指定されていれば、--build-only を除いた残りの引数をそのまま
# build_and_verify.sh に渡して委譲する (起動確認/URL 応答確認オプション等も
# そのまま透過する)。以降の ECR 関連処理は実行されない。
for _arg in "$@"; do
  if [ "$_arg" = "--build-only" ]; then
    if [ ! -f "$BUILD_VERIFY_SCRIPT" ]; then
      err "ビルド専用スクリプトが見つかりません: $BUILD_VERIFY_SCRIPT"
      exit 1
    fi
    FORWARD_ARGS=()
    _skip_next="false"
    for a in "$@"; do
      if [ "$_skip_next" = "true" ]; then _skip_next="false"; continue; fi
      [ "$a" = "--build-only" ] && continue
      # --log-dir はこのスクリプトで処理済み (build_and_verify.sh は未対応) のため除去する
      if [ "$a" = "--log-dir" ]; then _skip_next="true"; continue; fi
      FORWARD_ARGS+=("$a")
    done
    log "--build-only が指定されました。ビルド処理を ${BUILD_VERIFY_SCRIPT} に委譲します。"
    if [ -n "$LOG_DIR" ]; then
      # ログ複製が有効な場合は、経過時間も記録するため exec せず子プロセスで実行する。
      # 子プロセスは複製先の fd を継承するため、委譲先の出力もログファイルに残る。
      _bv_status=0
      bash "$BUILD_VERIFY_SCRIPT" "${FORWARD_ARGS[@]}" || _bv_status=$?
      exit "$_bv_status"
    else
      # ログ複製が無い通常時は従来どおり exec で完全に委譲する。
      exec bash "$BUILD_VERIFY_SCRIPT" "${FORWARD_ARGS[@]}"
    fi
  fi
done

# ---- 引数パース -------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --account-id)       ACCOUNT_ID="$2"; shift 2 ;;
    --region)           REGION="$2"; shift 2 ;;
    --registry)         REGISTRY="$2"; shift 2 ;;
    --repository)       REPOSITORY="$2"; shift 2 ;;
    --tag-prefix)       TAG_PREFIX="$2"; shift 2 ;;
    --local-image)      LOCAL_IMAGE="$2"; shift 2 ;;
    --container-name)   CONTAINER_NAME="$2"; shift 2 ;;
    --compose-file)     COMPOSE_FILE="$2"; shift 2 ;;
    --compose-service)  COMPOSE_SERVICE="$2"; shift 2 ;;
    --no-cache)         NO_CACHE="true"; shift ;;
    --output)           OUTPUT_FILE="$2"; shift 2 ;;
    --log-dir)          LOG_DIR="$2"; shift 2 ;;  # 冒頭でログ複製を設定済み (値の再取得のみ)
    --dry-run)          DRY_RUN="true"; shift ;;
    --build-only)       shift ;;  # 冒頭で build_and_verify.sh に委譲済み (ここには到達しない)
    --copy-file)        COPY_SPECS+=("$2"); shift 2 ;;
    --jboss-password-param) JBOSS_PASSWORD_PARAM="$2"; shift 2 ;;
    --jboss-password)       JBOSS_PASSWORD_VALUE="$2"; shift 2 ;;
    --jboss-password-env)   JBOSS_PASSWORD_ENV="$2"; JBOSS_PASSWORD_ENV_SET="true"; shift 2 ;;
    --switchback-shell) SWITCHBACK_SHELL="$2"; shift 2 ;;
    --auto-switchback)  AUTO_SWITCHBACK="true"; shift ;;
    --warn-only)        AUTO_SWITCHBACK="false"; shift ;;
    -h|--help)          usage; exit 0 ;;
    *) err "不明なオプション: $1"; usage; exit 2 ;;
  esac
done

# 本パース以降のどの経路 (途中の exit を含む) でも処理実行時間を記録する。
# --help / 不明オプションはパース中に exit するため、この行には到達せず経過時間は
# 出力されない。後段で一時ファイル削除も伴うトラップに差し替える。
trap log_elapsed EXIT

# ---- JBoss マスターパスワード関連オプションの検証 ----------------------------
# 取得元はパラメータストア (--jboss-password-param) / 直接指定 (--jboss-password) /
# 事前 export 済み環境変数 (--jboss-password-env のみ指定) のいずれか 1 つ。
if [ -n "$JBOSS_PASSWORD_PARAM" ] && [ -n "$JBOSS_PASSWORD_VALUE" ]; then
  err "--jboss-password-param と --jboss-password は同時に指定できません (どちらか一方を指定してください)"
  exit 2
fi
if [ -n "$JBOSS_PASSWORD_PARAM" ] || [ -n "$JBOSS_PASSWORD_VALUE" ] || [ "$JBOSS_PASSWORD_ENV_SET" = "true" ]; then
  JBOSS_SECRET_ENABLED="true"
fi
if ! printf '%s' "$JBOSS_PASSWORD_ENV" | grep -qE '^[A-Za-z_][A-Za-z0-9_]*$'; then
  err "--jboss-password-env に不正な環境変数名が指定されました: $JBOSS_PASSWORD_ENV"
  exit 2
fi

# ---- 依存コマンド確認 -------------------------------------------------------
# ECR へプッシュするため docker と aws が必須。
REQUIRED_CMDS=(docker aws)
for cmd in "${REQUIRED_CMDS[@]}"; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    err "必須コマンドが見つかりません: $cmd"
    exit 1
  fi
done

# ---- AWS 認証 (aws login --remote) 済みかのチェック --------------------------
# スクリプト実行開始時に、事前に aws login --remote による認証操作が実行されて
# いるかを sts get-caller-identity で確認する。未認証なら認証を促して終了する。
log "AWS 認証状態を確認します (aws login --remote 実施済みか) ..."
if aws sts get-caller-identity >/dev/null 2>&1; then
  log "AWS 認証を確認しました。"
elif [ "$DRY_RUN" = "true" ]; then
  warn "AWS 認証が確認できませんが、DRY-RUN のため中止せずにプレビューを継続します。"
  warn "  実際に実行する場合は、事前に 'aws login --remote' で認証してください。"
else
  err "AWS 認証が確認できません (aws sts get-caller-identity に失敗)。未認証の状態です。"
  err "  事前に 'aws login --remote' を実行して認証してから、再実行してください。"
  exit 1
fi

# docker compose (v2) / docker-compose (v1) の判定
if docker compose version >/dev/null 2>&1; then
  COMPOSE_CMD=(docker compose)
elif command -v docker-compose >/dev/null 2>&1; then
  COMPOSE_CMD=(docker-compose)
else
  err "docker compose / docker-compose が見つかりません"
  exit 1
fi

# ---- レジストリ URL の組み立て ---------------------------------------------
if [ -z "$REGISTRY" ]; then
  if [ -z "$ACCOUNT_ID" ]; then
    err "--account-id もしくは --registry を指定してください (レジストリ URL を決定できません)"
    exit 2
  fi
  REGISTRY="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"
fi

[ -n "$CONTAINER_NAME" ] || CONTAINER_NAME="$REPOSITORY"

if [ "$DRY_RUN" = "true" ]; then
  log "*** DRY-RUN モードです。実際のビルド/ログイン/タグ付け/プッシュ/ファイル出力は行いません。 ***"
fi

# ---- ECR 操作権限チェック ---------------------------------------------------
# ecr:GetAuthorizationToken を要求する get-login-password を叩けるかどうかで判定する。
# 成功すればパスワードを取得できるので、そのまま docker login に流用する。
ECR_PASSWORD=""
check_ecr_permission() {
  ECR_PASSWORD="$(aws ecr get-login-password --region "$REGION" 2>/dev/null)"
  if [ $? -ne 0 ] || [ -z "$ECR_PASSWORD" ]; then
    return 1
  fi
  return 0
}

# ---- スイッチバック処理 -----------------------------------------------------
do_switchback() {
  if [ -z "$SWITCHBACK_SHELL" ]; then
    err "スイッチバック用シェルのパスが未指定です。--switchback-shell で指定してください。"
    return 1
  fi
  if [ ! -f "$SWITCHBACK_SHELL" ]; then
    err "スイッチバック用シェルが見つかりません: $SWITCHBACK_SHELL"
    return 1
  fi
  log "スイッチバック用シェルを source で呼び出します: $SWITCHBACK_SHELL"
  # 別チーム提供のシェルを現在のシェルに source して認証情報 / ロールを切り替える。
  # shellcheck disable=SC1090
  source "$SWITCHBACK_SHELL"
  return 0
}

# ---- JBoss マスターパスワードの取得 / BuildKit シークレット注入準備 ----------
# --jboss-password-param / --jboss-password / --jboss-password-env のいずれかが
# 指定された場合に、マスターパスワードを取得して環境変数へ export する。
# compose.yml 側で secrets の environment: に同じ環境変数名を定義しておくことで、
# BuildKit シークレット (RUN --mount=type=secret) としてビルドから参照できる。
# パスワードの値そのものは、ログにもコマンドラインにも出力しない。
prepare_jboss_password() {
  [ "$JBOSS_SECRET_ENABLED" = "true" ] || return 0
  local password=""
  if [ -n "$JBOSS_PASSWORD_PARAM" ]; then
    log "パラメータストアから JBoss マスターパスワードを取得します: ${JBOSS_PASSWORD_PARAM} (region=${REGION}) ..."
    if [ "$DRY_RUN" = "true" ]; then
      log "[DRY-RUN] aws ssm get-parameter --name ${JBOSS_PASSWORD_PARAM} --with-decryption --region ${REGION} (値の取得・表示は行いません)"
    else
      local ssm_errfile
      ssm_errfile="$(mktemp 2>/dev/null || printf '%s' "${TMPDIR:-/tmp}/ssm_err.$$")"
      if ! password="$(aws ssm get-parameter --name "$JBOSS_PASSWORD_PARAM" \
            --with-decryption --region "$REGION" \
            --query 'Parameter.Value' --output text 2>"$ssm_errfile")"; then
        err "パラメータストアからの取得に失敗しました: ${JBOSS_PASSWORD_PARAM}"
        sed 's/^/  /' "$ssm_errfile" >&2
        rm -f "$ssm_errfile"
        err "  パラメータ名 / リージョン (${REGION}) / ssm:GetParameter 権限を確認してください。"
        exit 1
      fi
      rm -f "$ssm_errfile"
      if [ -z "$password" ] || [ "$password" = "None" ]; then
        err "パラメータストアから取得した値が空です: ${JBOSS_PASSWORD_PARAM}"
        exit 1
      fi
      log "パラメータストアから取得しました (値はログに出力しません)。"
    fi
  elif [ -n "$JBOSS_PASSWORD_VALUE" ]; then
    log "直接指定された JBoss マスターパスワードを使用します (値はログに出力しません)。"
    password="$JBOSS_PASSWORD_VALUE"
  else
    # --jboss-password-env のみ指定: 事前に export 済みの環境変数の値をそのまま使う
    password="${!JBOSS_PASSWORD_ENV:-}"
    if [ -z "$password" ] && [ "$DRY_RUN" != "true" ]; then
      err "環境変数 ${JBOSS_PASSWORD_ENV} が未設定または空です。"
      err "  --jboss-password-param / --jboss-password で渡すか、事前に export してから再実行してください。"
      exit 1
    fi
    log "既存の環境変数 ${JBOSS_PASSWORD_ENV} の値を JBoss マスターパスワードとして使用します。"
  fi
  export "${JBOSS_PASSWORD_ENV}=${password}"
  log "JBoss マスターパスワードを環境変数 ${JBOSS_PASSWORD_ENV} 経由で BuildKit シークレットとして注入します。"
  log "  (compose.yml の secrets で environment: ${JBOSS_PASSWORD_ENV} を定義しておくこと)"
}

# ---- ビルド前後の一時ファイルコピー / 自動削除 ------------------------------
# --copy-file で指定した SRC:DEST_DIR を検証し、SRC を DEST_DIR へコピーする。
# コピーしたコピー先パスは COPIED_FILES に記録し、EXIT トラップで自動削除する。
prepare_copy_files() {
  [ ${#COPY_SPECS[@]} -eq 0 ] && return 0
  log "ビルド前の一時ファイルコピーを実行します (${#COPY_SPECS[@]} 件) ..."
  local spec src dest_dir dest
  for spec in "${COPY_SPECS[@]}"; do
    # 最初の ':' で SRC と DEST_DIR に分割する (':' が無ければ書式エラー)
    if [ "${spec%%:*}" = "$spec" ]; then
      err "--copy-file の書式が不正です: '$spec' (SRC:DEST_DIR 形式で指定してください)"
      exit 2
    fi
    src="${spec%%:*}"
    dest_dir="${spec#*:}"
    if [ -z "$src" ] || [ -z "$dest_dir" ]; then
      err "--copy-file の書式が不正です: '$spec' (SRC / DEST_DIR が空です)"
      exit 2
    fi
    if [ ! -f "$src" ]; then
      err "コピー元ファイルが見つかりません: $src"
      exit 1
    fi
    if [ ! -d "$dest_dir" ]; then
      err "コピー先ディレクトリが存在しません: $dest_dir"
      exit 1
    fi
    dest="${dest_dir%/}/$(basename "$src")"
    # 既存ファイルを上書き→後で削除すると元ファイルを消してしまうため中止する
    if [ -e "$dest" ]; then
      err "コピー先に同名ファイルが既に存在します: $dest (自動削除による事故防止のため中止します)"
      exit 1
    fi
    if [ "$DRY_RUN" = "true" ]; then
      log "[DRY-RUN] cp $src -> $dest (ビルド後に自動削除)"
    else
      if ! cp "$src" "$dest"; then
        err "ファイルのコピーに失敗しました: $src -> $dest"
        exit 1
      fi
      log "コピーしました: $src -> $dest"
    fi
    # dry-run でも記録し、削除プレビューを表示できるようにする
    COPIED_FILES+=("$dest")
  done
}

# EXIT トラップから呼び出す削除処理。コピーしたファイルのみ削除する。
cleanup_copied_files() {
  [ ${#COPIED_FILES[@]} -eq 0 ] && return 0
  log "コピーした一時ファイルを削除します (${#COPIED_FILES[@]} 件) ..."
  local f
  for f in "${COPIED_FILES[@]}"; do
    if [ "$DRY_RUN" = "true" ]; then
      log "[DRY-RUN] rm -f $f"
    elif rm -f "$f"; then
      log "削除しました: $f"
    else
      warn "一時ファイルの削除に失敗しました: $f (手動で削除してください)"
    fi
  done
  COPIED_FILES=()
}
# ビルド成功・失敗いずれの経路 (途中の exit を含む) でも確実に削除する。
# 併せて処理実行時間 (経過秒数) を末尾に記録する (冒頭の暫定トラップを差し替える)。
trap 'cleanup_copied_files; log_elapsed' EXIT

# ---- docker push 失敗時の原因診断 / 調査ガイド ------------------------------
# 各原因カテゴリごとの詳細な説明・AWS CLI 調査コマンド・AWS コンソール確認箇所を出力する。
# ${ACCOUNT_ID:-<account-id>} 等でアカウント ID 未指定時も雛形として読める形にする。
_repo_arn() { printf 'arn:aws:ecr:%s:%s:repository/%s' "$REGION" "${ACCOUNT_ID:-<account-id>}" "$REPOSITORY"; }

guide_iam() {
  diag ""
  diag "───────────────────────────────────────────────────────────────────"
  diag "【原因候補 A】IAM 権限エラー (ecr:* アクションの許可不足)"
  diag "───────────────────────────────────────────────────────────────────"
  diag "  docker push は内部で以下の ECR API を順に呼び出します。いずれかの"
  diag "  権限が不足すると 'denied' / 'not authorized to perform' になります:"
  diag "    - ecr:GetAuthorizationToken       (ログイン)"
  diag "    - ecr:BatchCheckLayerAvailability (レイヤ存在確認)"
  diag "    - ecr:InitiateLayerUpload         (アップロード開始)"
  diag "    - ecr:UploadLayerPart             (レイヤ送信)"
  diag "    - ecr:CompleteLayerUpload         (アップロード完了)"
  diag "    - ecr:PutImage                    (マニフェスト登録)"
  diag ""
  diag "  ▼ AWS CLI での調査:"
  diag "    # 1) 今どの IAM プリンシパルとして実行しているか"
  diag "    aws sts get-caller-identity"
  diag "    # 2) トークン取得可否 (= ecr:GetAuthorizationToken の可否)"
  diag "    aws ecr get-login-password --region ${REGION} >/dev/null && echo OK"
  diag "    # 3) 実際に拒否されているアクションをポリシーシミュレータで特定"
  diag "    aws iam simulate-principal-policy \\"
  diag "      --policy-source-arn <上記 get-caller-identity の Arn> \\"
  diag "      --action-names ecr:InitiateLayerUpload ecr:UploadLayerPart \\"
  diag "                     ecr:CompleteLayerUpload ecr:PutImage \\"
  diag "                     ecr:BatchCheckLayerAvailability \\"
  diag "      --resource-arns $(_repo_arn)"
  diag ""
  diag "  ▼ AWS コンソールでの確認:"
  diag "    - IAM > ユーザー/ロール > (get-caller-identity のプリンシパル) >"
  diag "      「アクセス許可」で ECR 系ポリシーがアタッチされているか"
  diag "    - CloudTrail > イベント履歴 で errorCode=AccessDenied を検索し、"
  diag "      eventName (どの ecr:* が拒否されたか) と userIdentity を確認"
}

guide_endpoint_policy() {
  diag ""
  diag "───────────────────────────────────────────────────────────────────"
  diag "【原因候補 B】ECR エンドポイント権限設定エラー (ポリシーによる拒否)"
  diag "───────────────────────────────────────────────────────────────────"
  diag "  IAM 権限があっても、次のポリシーが拒否していると 'denied' になります:"
  diag "    (1) ECR リポジトリポリシー (リポジトリ単位のリソースベースポリシー)"
  diag "    (2) VPC エンドポイントポリシー (com.amazonaws.${REGION}.ecr.api /"
  diag "        .ecr.dkr のインターフェース型, および S3 ゲートウェイ型)"
  diag ""
  diag "  ▼ AWS CLI での調査:"
  diag "    # リポジトリポリシー (拒否ステートメントが無いか)"
  diag "    aws ecr get-repository-policy --repository-name ${REPOSITORY} --region ${REGION}"
  diag "    # ECR インターフェース型エンドポイントのポリシー/状態"
  diag "    aws ec2 describe-vpc-endpoints --region ${REGION} \\"
  diag "      --filters Name=service-name,Values=com.amazonaws.${REGION}.ecr.dkr \\"
  diag "      --query 'VpcEndpoints[].{Id:VpcEndpointId,State:State,PrivateDns:PrivateDnsEnabled,Policy:PolicyDocument}'"
  diag "    # ecr.api / s3 についても Values を差し替えて同様に確認"
  diag ""
  diag "  ▼ AWS コンソールでの確認:"
  diag "    - ECR > リポジトリ > ${REPOSITORY} > 「アクセス許可」タブ (リポジトリポリシー)"
  diag "    - VPC > エンドポイント > ecr.api / ecr.dkr / s3 の「ポリシー」タブが"
  diag "      当該操作/プリンシパルを許可しているか (フルアクセスまたは明示 Allow)"
}

guide_endpoint_missing() {
  diag ""
  diag "───────────────────────────────────────────────────────────────────"
  diag "【原因候補 C】ECR エンドポイント不存在疑い (ネットワーク到達不可)"
  diag "───────────────────────────────────────────────────────────────────"
  diag "  'no such host' / 'timeout' / 'dial tcp' / 'connection refused' 等は"
  diag "  DNS 解決失敗または TCP 到達失敗です。インターネットに出られない"
  diag "  プライベートサブネットでは、ECR 用の VPC エンドポイントが必須です:"
  diag "    - com.amazonaws.${REGION}.ecr.api  (インターフェース型)"
  diag "    - com.amazonaws.${REGION}.ecr.dkr  (インターフェース型, レイヤ転送)"
  diag "    - com.amazonaws.${REGION}.s3       (ゲートウェイ型, レイヤ実体は S3)"
  diag "  これらが未作成 / PrivateDNS 無効 / SG・ルートテーブル不備だと失敗します。"
  diag ""
  diag "  ▼ 到達性・DNS の調査 (EC2 上で実行):"
  diag "    getent hosts ${REGISTRY}          # 名前解決できるか"
  diag "    curl -v https://${REGISTRY}/v2/   # 443 で到達できるか (401 なら到達OK)"
  diag ""
  diag "  ▼ AWS CLI での調査:"
  diag "    aws ec2 describe-vpc-endpoints --region ${REGION} \\"
  diag "      --filters Name=service-name,Values=com.amazonaws.${REGION}.ecr.dkr \\"
  diag "      --query 'VpcEndpoints[].{Id:VpcEndpointId,State:State,PrivateDns:PrivateDnsEnabled,Subnets:SubnetIds,SG:Groups}'"
  diag "    # ecr.api / s3 についても Values を差し替えて存在と State=available を確認"
  diag ""
  diag "  ▼ AWS コンソールでの確認:"
  diag "    - VPC > エンドポイント: ecr.api / ecr.dkr が『available』かつ"
  diag "      『プライベート DNS 名を有効化』が ON、s3 ゲートウェイ型が存在するか"
  diag "    - EC2 のサブネットのルートテーブル (s3 ゲートウェイへの経路)"
  diag "    - エンドポイントの SG / EC2 の SG のアウトバウンドで 443/tcp が許可か"
}

guide_repo_not_found() {
  diag ""
  diag "───────────────────────────────────────────────────────────────────"
  diag "【原因候補 D】ECR リポジトリが存在しない"
  diag "───────────────────────────────────────────────────────────────────"
  diag "  'name unknown' / 'does not exist in the registry' は、プッシュ先の"
  diag "  リポジトリ '${REPOSITORY}' が (このリージョン/アカウントに) 未作成です。"
  diag "  ECR は push 時に自動作成しません。リージョン取り違えも多い原因です。"
  diag ""
  diag "  ▼ AWS CLI での調査 / 対処:"
  diag "    # 一覧して存在とリージョンを確認"
  diag "    aws ecr describe-repositories --region ${REGION} \\"
  diag "      --query 'repositories[].repositoryName'"
  diag "    # 無ければ作成"
  diag "    aws ecr create-repository --repository-name ${REPOSITORY} --region ${REGION}"
  diag ""
  diag "  ▼ AWS コンソールでの確認:"
  diag "    - 画面右上のリージョンが ${REGION} になっているか"
  diag "    - ECR > リポジトリ 一覧に ${REPOSITORY} が存在するか"
}

guide_token_expired() {
  diag ""
  diag "───────────────────────────────────────────────────────────────────"
  diag "【原因候補 E】認証トークンの期限切れ / 未ログイン"
  diag "───────────────────────────────────────────────────────────────────"
  diag "  'authorization token has expired' / 'no basic auth credentials' /"
  diag "  '401 Unauthorized' は、ECR ログインが無効化 (トークン有効期限 12h) 済み。"
  diag ""
  diag "  ▼ 再ログイン:"
  diag "    aws ecr get-login-password --region ${REGION} \\"
  diag "      | docker login --username AWS --password-stdin ${REGISTRY}"
}

# docker push の出力 (push_log) を解析し、該当する原因ガイドを出力する。
diagnose_push_failure() {
  local push_log="$1"
  local out=""
  [ -f "$push_log" ] && out="$(cat "$push_log")"

  err "==================================================================="
  err "docker push に失敗しました: ${TARGET_IMAGE}"
  err "AWS API の応答を確認し、原因の切り分けと詳細な調査方法を表示します。"
  err "==================================================================="

  # --- AWS API を実際に呼び出して事実確認する (読み取り専用) ---
  diag ""
  diag "▼ 現在の認証情報 (aws sts get-caller-identity):"
  local identity
  if identity="$(aws sts get-caller-identity --output text 2>&1)"; then
    diag "  ${identity}"
  else
    diag "  取得に失敗: ${identity}"
    diag "  → 認証情報が無効/期限切れの可能性大 (スイッチバックが必要かもしれません)。"
  fi

  diag ""
  diag "▼ ECR リポジトリの実在確認 (aws ecr describe-repositories):"
  local repo_out repo_exists="unknown"
  if repo_out="$(aws ecr describe-repositories --repository-names "$REPOSITORY" --region "$REGION" --output text 2>&1)"; then
    diag "  リポジトリ '${REPOSITORY}' は ${REGION} に存在します。"
    repo_exists="yes"
  else
    diag "  確認できませんでした:"
    diag "    ${repo_out}"
    if printf '%s' "$repo_out" | grep -qiE 'RepositoryNotFoundException|does not exist'; then
      repo_exists="no"
    elif printf '%s' "$repo_out" | grep -qiE 'AccessDenied|not authorized'; then
      diag "  → describe すら AccessDenied。IAM 権限不足の可能性が高いです。"
    fi
  fi

  # --- push 出力のパターンから原因カテゴリを判定 ---
  diag ""
  diag "▼ docker push の出力から推定される原因:"
  local matched=0

  if [ "$repo_exists" = "no" ] || printf '%s' "$out" | grep -qiE 'name unknown|does not exist in the registry|repositorynotfoundexception|repository .* does not exist'; then
    guide_repo_not_found; matched=1
  fi

  if printf '%s' "$out" | grep -qiE 'no such host|server misbehaving|dial tcp|i/o timeout|deadline exceeded|connection refused|tls handshake|could not resolve|temporary failure in name resolution|network is unreachable|no route to host'; then
    guide_endpoint_missing; matched=1
  fi

  if printf '%s' "$out" | grep -qiE 'authorization token has expired|no basic auth credentials|401 unauthorized|authentication required'; then
    guide_token_expired; matched=1
  fi

  # 'denied' 系は IAM 権限とエンドポイント/リポジトリポリシーの双方が候補
  if printf '%s' "$out" | grep -qiE 'not authorized to perform|access ?denied|is not authorized|denied: |ecr:(initiatelayerupload|uploadlayerpart|completelayerupload|putimage|batchchecklayeravailability|getauthorizationtoken)'; then
    guide_iam; guide_endpoint_policy; matched=1
  fi

  if [ "$matched" -eq 0 ]; then
    diag "  出力から自動判定できるパターンに一致しませんでした。"
    diag "  以下の全観点で切り分けてください。"
    guide_iam
    guide_endpoint_policy
    guide_endpoint_missing
    guide_repo_not_found
    guide_token_expired
  fi

  diag ""
  err "==================================================================="
  err "上記の調査コマンド/コンソール確認で原因を特定してください。"
  err "==================================================================="
}

if { log "ECR 操作権限を確認します (region=${REGION}) ..."; ! check_ecr_permission; }; then
  warn "現在の操作権限では ECR を操作できません。"
  if [ "$AUTO_SWITCHBACK" = "true" ]; then
    # (B) 終了せず、自動的にスイッチバックして継続する
    log "自動スイッチバックモードです。スイッチバックを実行します。"
    if ! do_switchback; then
      err "スイッチバックに失敗しました。処理を中止します。"
      exit 1
    fi
    log "スイッチバック後に再度 ECR 操作権限を確認します ..."
    if ! check_ecr_permission; then
      err "スイッチバック後も ECR を操作できません。権限設定を確認してください。"
      exit 1
    fi
    log "スイッチバックにより ECR 操作が可能になりました。処理を継続します。"
  elif [ "$DRY_RUN" = "true" ]; then
    # dry-run では中止せず、権限が無い旨を警告してプレビューを継続する
    warn "ECR 操作権限がありませんが、DRY-RUN のため中止せずにプレビューを継続します。"
    warn "  実際に実行する場合はスイッチバック (--auto-switchback など) が必要です。"
  else
    # (A) 警告して終了する
    err "ECR への操作権限がありません。スイッチバックしてから再実行してください。"
    if [ -n "$SWITCHBACK_SHELL" ]; then
      err "  例) source \"$SWITCHBACK_SHELL\" を実行してスイッチバックしてください。"
    else
      err "  スイッチバック用シェル (別チーム提供) を source で読み込んでスイッチバックしてください。"
    fi
    err "  自動でスイッチバックする場合は --auto-switchback を付けて再実行してください。"
    exit 1
  fi
fi

# ---- JBoss マスターパスワードの取得 / シークレット注入準備 -------------------
# パラメータストアへのアクセスに AWS 権限が必要なため、スイッチバック確定後に行う。
prepare_jboss_password

# compose.yml の environment 型シークレット (既定: JBOSS_MASTER_PASSWORD) は、
# 環境変数が未定義だと compose build が失敗するため、シークレットを使わない
# 場合でも空文字で定義しておく (既に値が入っていればそのまま維持する)。
export JBOSS_MASTER_PASSWORD="${JBOSS_MASTER_PASSWORD:-}"

# ---- ビルド前の一時ファイルコピー -------------------------------------------
# ここでコピーしたファイルは EXIT トラップ (cleanup_copied_files) により
# ビルド終了後 / 途中終了時のいずれでも自動削除される。
prepare_copy_files

# ---- ビルド -----------------------------------------------------------------
BUILD_OPTS=()
if [ "$NO_CACHE" = "true" ]; then
  BUILD_OPTS+=(--no-cache)
  log "キャッシュを破棄して (--no-cache) ビルドします。"
fi

log "docker compose build を実行します (${COMPOSE_FILE}) ..."
if [ -n "$COMPOSE_SERVICE" ]; then
  run "${COMPOSE_CMD[@]}" -f "$COMPOSE_FILE" build "${BUILD_OPTS[@]}" "$COMPOSE_SERVICE" || { err "compose build に失敗しました"; exit 1; }
else
  run "${COMPOSE_CMD[@]}" -f "$COMPOSE_FILE" build "${BUILD_OPTS[@]}" || { err "compose build に失敗しました"; exit 1; }
fi

# ローカルベースイメージが生成されたか確認 (dry-run ではビルドしていないためスキップ)
if [ "$DRY_RUN" = "true" ]; then
  log "[DRY-RUN] ローカルベースイメージの存在確認をスキップします: $LOCAL_IMAGE"
elif ! docker image inspect "$LOCAL_IMAGE" >/dev/null 2>&1; then
  err "ローカルベースイメージが見つかりません: $LOCAL_IMAGE (compose.yml の image 指定を確認してください)"
  exit 1
else
  log "ローカルベースイメージを確認しました: $LOCAL_IMAGE"
fi

# ---- タグ (<接頭辞>-<処理年月日時分秒>) -------------------------------------
# タグの接頭辞 (TAG_PREFIX) はリポジトリ名とは独立に --tag-prefix で指定できる。
# 例: TAG_PREFIX=BaseImage のとき BaseImage-20260702153000
IMAGE_TAG="${TAG_PREFIX}-$(date '+%Y%m%d%H%M%S')"
TARGET_IMAGE="${REGISTRY}/${REPOSITORY}:${IMAGE_TAG}"

# ---- ECR ログイン (get-login-password | docker login --password-stdin) -----
log "ECR にログインします: $REGISTRY (user=${ECR_USERNAME}) ..."
# ECR_PASSWORD は権限チェック時に取得済み。--password-stdin で安全に渡す。
if [ "$DRY_RUN" = "true" ]; then
  log "[DRY-RUN] docker login --username ${ECR_USERNAME} --password-stdin ${REGISTRY} (password は非表示)"
elif ! printf '%s' "$ECR_PASSWORD" | docker login --username "$ECR_USERNAME" --password-stdin "$REGISTRY"; then
  err "docker login に失敗しました: $REGISTRY"
  exit 1
fi

# ---- タグ付け & プッシュ ----------------------------------------------------
log "docker image tag ${LOCAL_IMAGE} -> ${TARGET_IMAGE}"
if ! run docker image tag "$LOCAL_IMAGE" "$TARGET_IMAGE"; then
  err "docker image tag に失敗しました"
  exit 1
fi

log "docker push ${TARGET_IMAGE} ..."
if [ "$DRY_RUN" = "true" ]; then
  log "[DRY-RUN] docker push ${TARGET_IMAGE}"
else
  # push の出力を画面に流しつつ (tee) ログへ保存し、失敗時に原因解析へ回す。
  # pipefail 有効のため、docker push 失敗時はパイプライン全体も失敗扱いになる。
  PUSH_LOG="$(mktemp 2>/dev/null || printf '%s' "${TMPDIR:-/tmp}/push.$$.log")"
  if docker push "$TARGET_IMAGE" 2>&1 | tee "$PUSH_LOG"; then
    log "docker push に成功しました。"
  else
    diagnose_push_failure "$PUSH_LOG"
    rm -f "$PUSH_LOG"
    exit 1
  fi
  rm -f "$PUSH_LOG"
fi

# ---- imagedefinition.json 出力 ---------------------------------------------
# CodePipeline の ECS デプロイ等で使われる標準フォーマット。
IMAGEDEF_CONTENT="$(cat <<EOF
[
  {
    "name": "${CONTAINER_NAME}",
    "imageUri": "${TARGET_IMAGE}"
  }
]
EOF
)"

if [ "$DRY_RUN" = "true" ]; then
  log "[DRY-RUN] ${OUTPUT_FILE} に以下を出力します (実際には書き込みません):"
  printf '%s\n' "$IMAGEDEF_CONTENT"
else
  printf '%s\n' "$IMAGEDEF_CONTENT" > "$OUTPUT_FILE"
  log "imagedefinition を出力しました: ${OUTPUT_FILE}"
fi

log "  name     = ${CONTAINER_NAME}"
log "  imageUri = ${TARGET_IMAGE}"
if [ "$DRY_RUN" = "true" ]; then
  log "DRY-RUN が完了しました (実際の変更は行われていません)。"
else
  log "完了しました。"
fi
