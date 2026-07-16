#!/usr/bin/env bash
#
# build_and_verify.sh
# -----------------------------------------------------------------------------
# 想定実行環境: RHEL 9.6 の EC2 インスタンス (bash / GNU coreutils / Docker CE)。
#
# build_and_push.sh の「ビルドのみ実行する処理」を切り出した専用スクリプト。
# compose.yml で定義したローカルベースイメージ (既定: j1/base.local) を
# docker compose build でビルドする。ECR ログイン/タグ付け/プッシュ/
# imagedefinition.json の出力は一切行わない。
#
# ビルドに加えて、以下の 2 つの確認を任意で行える:
#   (1) --verify-startup : ビルドしたイメージをコンテナとして起動し、
#                          jbosseap (WildFly/JBoss EAP) サーバーの起動完了を
#                          ログから確認する。
#   (2) --verify-url URL : 起動確認後、指定 URL へ HTTP リクエストを送り、
#                          その応答 (ステータスコード/本文) を確認する。
#
# --verify-startup / --verify-url いずれも指定しなければ、純粋にビルドのみを
# 行って終了する (従来の build_and_push.sh --build-only 相当)。
#
# JBoss マスターパスワード (BuildKit シークレット):
#   - ビルド前に、パラメータストアの指定キー (--jboss-password-param) から
#     JBoss のマスターパスワードを取得できる (直接指定 --jboss-password も可)。
#   - 取得した値は環境変数 (--jboss-password-env, 既定: JBOSS_MASTER_PASSWORD)
#     へ export し、compose.yml の environment 型シークレット定義を通じて
#     BuildKit シークレットとして安全にビルドへ注入する。
#   - パラメータストアを使う場合のみ AWS 認証 (aws login --remote 実施済み) が
#     必要で、未認証の場合は認証を促す警告を表示して終了する。
#
# 使い方:
#   # ビルドのみ
#   ./build_and_verify.sh
#
#   # ビルド + jbosseap 起動確認
#   ./build_and_verify.sh --verify-startup
#
#   # ビルド + 起動確認 + URL 応答確認 (例: ヘルスチェックエンドポイント)
#   ./build_and_verify.sh --verify-startup \
#       --verify-url http://localhost:8080/health --expect-status 200
#
#   # base を先行ビルド後、複数サービスを同時にビルド・起動し、
#   # app サービスのみ起動確認する
#   ./build_and_verify.sh --compose-service app --compose-service db \
#       --startup-service app
#   # (カンマ区切りでも指定可: --compose-service app,db)
# -----------------------------------------------------------------------------

set -uo pipefail

# ---- 既定値 -----------------------------------------------------------------
LOCAL_IMAGE="j1/base.local"       # compose build で生成されるローカルベースイメージ名
COMPOSE_FILE="compose.yml"
COMPOSE_SERVICES=()               # 指定時はそのサービスのみビルド/起動 (複数指定可、空なら全サービス)
BASE_SERVICE="base"              # 複数サービス指定時に必ず先行ビルドするベースサービス名
NO_CACHE="false"                  # true: キャッシュを破棄してビルド (--no-cache)
DRY_RUN="false"                   # true: 実際の変更は行わず、実行内容のプレビューのみ表示
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-ap-northeast-1}}"  # パラメータストア参照時に使用

# JBoss マスターパスワード (BuildKit シークレット) 関連
JBOSS_PASSWORD_PARAM=""           # パラメータストアのキー名 (--jboss-password-param)
JBOSS_PASSWORD_VALUE=""           # 直接指定されたマスターパスワード (--jboss-password)
JBOSS_PASSWORD_ENV="JBOSS_MASTER_PASSWORD"  # シークレット受け渡しに使う環境変数名
JBOSS_PASSWORD_ENV_SET="false"    # --jboss-password-env が明示指定されたか
JBOSS_SECRET_ENABLED="false"      # マスターパスワードをビルドシークレットとして注入するか

# ビルド前に一時コピーし、ビルド後に自動削除するファイル群
# COPY_SPECS: "SRC:DEST_DIR" の配列 (--copy-file で繰り返し指定)
# COPIED_FILES: 実際にコピーしたコピー先ファイルパス (削除対象として記録)
COPY_SPECS=()
COPIED_FILES=()

# ---- 起動確認 (jbosseap) 関連 ----------------------------------------------
VERIFY_STARTUP="false"            # true: ビルド後にコンテナを起動し起動完了を確認
STARTUP_SERVICES=()               # 起動完了チェックの対象サービス (複数指定可)。
                                  # 空なら対象サービス全体のログをまとめて確認する。
# 起動完了とみなすログのパターン (拡張正規表現)。
# 既定は JBoss EAP / WildFly の起動完了メッセージ:
#   WFLYSRV0025: JBoss EAP x.y.z (WildFly Core ...) started in NNNms
#   WFLYSRV0026: ... started (with errors) in NNNms
STARTUP_LOG_PATTERN='WFLYSRV002[56]|JBoss EAP.*started in'
STARTUP_TIMEOUT="120"             # 起動完了を待つ最大秒数
STARTUP_INTERVAL="3"              # 起動確認ポーリング間隔 (秒)
KEEP_CONTAINER="false"            # true: 確認後もコンテナを停止・削除せずに残す

# ---- URL 応答確認 関連 ------------------------------------------------------
VERIFY_URL=""                     # 空でなければ起動確認後にこの URL を呼び出して確認
EXPECT_STATUS="200"               # 期待する HTTP ステータスコード
URL_METHOD="GET"                  # HTTP メソッド
URL_CONTENT_TYPE=""               # Content-Type ヘッダ値 (未指定時は curl 既定)
URL_BODY_JSON=""                  # JSON 文字列をリクエストボディとして送る
URL_BODY_FORM=""                  # form 文字列 (key=value&...) をリクエストボディとして送る
URL_TIMEOUT="60"                  # URL が期待応答を返すまで待つ最大秒数 (リトライ)
URL_INTERVAL="3"                  # URL 呼び出しリトライ間隔 (秒)
URL_INSECURE="false"             # true: TLS 証明書検証を無効化して呼び出す (curl -k)

# ---- ログ用ヘルパ -----------------------------------------------------------
log()  { printf '[%s] %s\n'  "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
warn() { printf '[%s] [WARN] %s\n'  "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }
err()  { printf '[%s] [ERROR] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }
# 診断ガイド等の整形出力用 (タイムスタンプ等の接頭辞を付けず、そのまま表示する)
diag() { printf '%s\n' "$*" >&2; }
# dry-run 時は実行内容を表示するだけ、通常時はそのままコマンドを実行する。
run()  {
  if [ "$DRY_RUN" = "true" ]; then
    printf '[%s] [DRY-RUN] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
    return 0
  fi
  "$@"
}

usage() {
  cat <<'EOF'
Usage: build_and_verify.sh [OPTIONS]

build_and_push.sh の「ビルドのみ」処理を切り出した専用スクリプト。
compose build でローカルイメージをビルドし、必要に応じて起動確認・URL 応答確認を行う。
ECR ログイン/タグ付け/プッシュ/imagedefinition.json の出力は行わない。

ビルド関連:
  --local-image NAME       compose build で生成されるローカルイメージ名 (既定: j1/base.local)
  --compose-file FILE      compose ファイル (既定: compose.yml)
  --compose-service NAME   ビルド/起動対象サービス名 (未指定なら全サービス)。
                           繰り返し指定またはカンマ区切りで複数指定できる。
                           複数指定時は base サービスを必ず単独で先行ビルドし、
                           ベースイメージの生成確認後、base を除く指定サービスを
                           まとめて並列ビルドする。指定したサービスは同時に起動する。
                           base が指定に含まれなくても先行ビルドするが、起動はしない。
                           例: --compose-service app --compose-service db
                               --compose-service app,db
  --no-cache               キャッシュを破棄して compose build する
  --dry-run                実際のビルド/起動/URL 呼び出し/ファイル操作は行わず、
                           実行される内容のプレビューのみ表示する

  --copy-file SRC:DEST_DIR ビルド前に SRC を DEST_DIR ディレクトリへコピーし、
                           処理終了後 (成功・失敗を問わず) に自動削除する。
                           複数ファイルに対応するため繰り返し指定できる。
                           例: --copy-file .npmrc:./app --copy-file cert.pem:./app/certs
                           - DEST_DIR は既存ディレクトリである必要がある
                           - コピー先に同名ファイルが既存の場合は事故防止のため中止する

JBoss マスターパスワード (BuildKit シークレット):
  --jboss-password-param NAME
                           JBoss のマスターパスワードを AWS パラメータストア
                           (SSM Parameter Store) の指定キー NAME から取得する
                           (aws ssm get-parameter --with-decryption)。
                           取得した値は --jboss-password-env の環境変数へ export され、
                           compose.yml の environment 型シークレット定義を通じて
                           BuildKit シークレットとしてビルドに注入される。
                           このオプション使用時は aws コマンドと AWS 認証
                           (aws login --remote 実施済み) が必要で、未認証の場合は
                           認証を促す警告を表示して終了する (exit 1)。
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
  --region REGION          パラメータストア参照時の AWS リージョン
                           (既定: ap-northeast-1 / env: AWS_REGION)

起動確認 (jbosseap / WildFly):
  --verify-startup         ビルド後にコンテナを起動し、jbosseap サーバーの起動完了を
                           ログから確認する。確認後はコンテナを停止・削除する
                           (--keep-container 指定時は残す)。
  --startup-service NAME   起動完了チェックを行うサービス名。繰り返し指定または
                           カンマ区切りで複数指定でき、指定した全サービスの起動完了を
                           それぞれのログから個別に確認する。指定時は --verify-startup
                           を暗黙に有効化する。未指定なら対象サービス全体のログを
                           まとめて確認する (従来動作)。
                           例: --compose-service app,db --startup-service app
  --startup-log-pattern P  起動完了とみなすログのパターン (拡張正規表現)。
                           既定: 'WFLYSRV002[56]|JBoss EAP.*started in'
  --startup-timeout SEC    起動完了を待つ最大秒数 (既定: 120)
  --startup-interval SEC   起動確認のポーリング間隔・秒 (既定: 3)
  --keep-container         確認後もコンテナを停止・削除せずに残す (調査用)

URL 応答確認:
  --verify-url URL         起動確認後、この URL へ HTTP リクエストを送り応答を確認する。
                           (単独指定でもコンテナを起動して確認する)
  --expect-status CODE     期待する HTTP ステータスコード (既定: 200)
  --url-method METHOD      HTTP メソッド (既定: GET)
  --url-content-type TYPE  verify-url 時の Content-Type ヘッダ値
  --url-body-json JSON     verify-url 時のリクエストボディに JSON を設定する。
                           Content-Type 未指定時は application/json を自動設定する
  --url-body-form DATA     verify-url 時のリクエストボディに form データ
                           (key=value&...) を設定する。Content-Type 未指定時は
                           application/x-www-form-urlencoded を自動設定する
  --url-timeout SEC        期待する応答を得るまで待つ最大秒数・リトライ (既定: 60)
  --url-interval SEC       URL 呼び出しのリトライ間隔・秒 (既定: 3)
  --url-insecure           TLS 証明書検証を無効化して呼び出す (curl -k)

  -h, --help               このヘルプを表示
EOF
}

# ---- 引数パース -------------------------------------------------------------
# カンマ区切りの値を分割して配列変数 (名前を $1 で受ける) に追加する。
# 例: append_services COMPOSE_SERVICES "app,db"
append_services() {
  local _var="$1" _value="$2" _s
  local -a _parts=()
  IFS=',' read -r -a _parts <<< "$_value"
  for _s in "${_parts[@]}"; do
    [ -n "$_s" ] && eval "$_var+=(\"\$_s\")"
  done
}

while [ $# -gt 0 ]; do
  case "$1" in
    --local-image)         LOCAL_IMAGE="$2"; shift 2 ;;
    --compose-file)        COMPOSE_FILE="$2"; shift 2 ;;
    --compose-service)     append_services COMPOSE_SERVICES "$2"; shift 2 ;;
    --no-cache)            NO_CACHE="true"; shift ;;
    --dry-run)             DRY_RUN="true"; shift ;;
    --copy-file)           COPY_SPECS+=("$2"); shift 2 ;;
    --region)              REGION="$2"; shift 2 ;;
    --jboss-password-param) JBOSS_PASSWORD_PARAM="$2"; shift 2 ;;
    --jboss-password)       JBOSS_PASSWORD_VALUE="$2"; shift 2 ;;
    --jboss-password-env)   JBOSS_PASSWORD_ENV="$2"; JBOSS_PASSWORD_ENV_SET="true"; shift 2 ;;
    --verify-startup)      VERIFY_STARTUP="true"; shift ;;
    --startup-service)     append_services STARTUP_SERVICES "$2"; VERIFY_STARTUP="true"; shift 2 ;;
    --startup-log-pattern) STARTUP_LOG_PATTERN="$2"; shift 2 ;;
    --startup-timeout)     STARTUP_TIMEOUT="$2"; shift 2 ;;
    --startup-interval)    STARTUP_INTERVAL="$2"; shift 2 ;;
    --keep-container)      KEEP_CONTAINER="true"; shift ;;
    --verify-url)          VERIFY_URL="$2"; shift 2 ;;
    --expect-status)       EXPECT_STATUS="$2"; shift 2 ;;
    --url-method)          URL_METHOD="$2"; shift 2 ;;
    --url-content-type)    URL_CONTENT_TYPE="$2"; shift 2 ;;
    --url-body-json)       URL_BODY_JSON="$2"; shift 2 ;;
    --url-body-form)       URL_BODY_FORM="$2"; shift 2 ;;
    --url-timeout)         URL_TIMEOUT="$2"; shift 2 ;;
    --url-interval)        URL_INTERVAL="$2"; shift 2 ;;
    --url-insecure)        URL_INSECURE="true"; shift ;;
    -h|--help)             usage; exit 0 ;;
    *) err "不明なオプション: $1"; usage; exit 2 ;;
  esac
done

# --startup-service が --compose-service の対象に含まれているか検証する。
# (--compose-service 未指定 = 全サービス対象なので、その場合は検証不要)
if [ ${#STARTUP_SERVICES[@]} -gt 0 ] && [ ${#COMPOSE_SERVICES[@]} -gt 0 ]; then
  for _ss in "${STARTUP_SERVICES[@]}"; do
    _found="false"
    for _cs in "${COMPOSE_SERVICES[@]}"; do
      [ "$_ss" = "$_cs" ] && _found="true"
    done
    if [ "$_found" != "true" ]; then
      err "--startup-service '$_ss' が --compose-service で指定した対象 (${COMPOSE_SERVICES[*]}) に含まれていません"
      exit 2
    fi
  done
fi

# --verify-url が指定されている場合、コンテナ起動が前提となる。
# 明示的に --verify-startup が付いていなくてもコンテナは起動する
# (起動完了のログ確認を行うかどうかは VERIFY_STARTUP で制御)。
NEED_CONTAINER="false"
if [ "$VERIFY_STARTUP" = "true" ] || [ -n "$VERIFY_URL" ]; then
  NEED_CONTAINER="true"
fi

# URL ボディ指定は JSON / form のどちらか一方のみ許可する。
if [ -n "$URL_BODY_JSON" ] && [ -n "$URL_BODY_FORM" ]; then
  err "--url-body-json と --url-body-form は同時に指定できません"
  exit 2
fi

# verify-url 用の追加指定は --verify-url と組み合わせて使う。
if [ -z "$VERIFY_URL" ] && { [ -n "$URL_CONTENT_TYPE" ] || [ -n "$URL_BODY_JSON" ] || [ -n "$URL_BODY_FORM" ]; }; then
  err "--url-content-type / --url-body-json / --url-body-form は --verify-url と併用してください"
  exit 2
fi

# ボディ形式に応じて Content-Type の既定値を補う。
if [ -z "$URL_CONTENT_TYPE" ]; then
  if [ -n "$URL_BODY_JSON" ]; then
    URL_CONTENT_TYPE="application/json"
  elif [ -n "$URL_BODY_FORM" ]; then
    URL_CONTENT_TYPE="application/x-www-form-urlencoded"
  fi
fi

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
# ビルドには docker が必須。URL 応答確認を行う場合は curl も必須。
# パラメータストアからパスワードを取得する場合は aws も必須。
REQUIRED_CMDS=(docker)
[ -n "$VERIFY_URL" ] && REQUIRED_CMDS+=(curl)
[ -n "$JBOSS_PASSWORD_PARAM" ] && REQUIRED_CMDS+=(aws)
for cmd in "${REQUIRED_CMDS[@]}"; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    err "必須コマンドが見つかりません: $cmd"
    exit 1
  fi
done

# ---- AWS 認証 (aws login --remote) 済みかのチェック --------------------------
# このスクリプトは通常 AWS を操作しないが、パラメータストアからパスワードを
# 取得する場合のみ AWS 認証が必要になる。事前に aws login --remote による認証
# 操作が実行されているかを sts get-caller-identity で確認し、未認証なら
# 認証を促して終了する。
if [ -n "$JBOSS_PASSWORD_PARAM" ]; then
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
fi

# docker compose (v2) / docker-compose (v1) の判定。
# 複数サービス指定時は Compose の並列実行オプションも準備する。v2 はグローバルの
# --parallel N、v1 は build サブコマンドの --parallel を使用する。
COMPOSE_PARALLEL_OPTS=()
COMPOSE_BUILD_PARALLEL_OPTS=()
if docker compose version >/dev/null 2>&1; then
  COMPOSE_CMD=(docker compose)
  if [ ${#COMPOSE_SERVICES[@]} -gt 1 ]; then
    COMPOSE_PARALLEL_OPTS=(--parallel "${#COMPOSE_SERVICES[@]}")
  fi
elif command -v docker-compose >/dev/null 2>&1; then
  COMPOSE_CMD=(docker-compose)
  if [ ${#COMPOSE_SERVICES[@]} -gt 1 ]; then
    if docker-compose build --help 2>&1 | grep -q -- '--parallel'; then
      COMPOSE_BUILD_PARALLEL_OPTS=(--parallel)
    else
      err "複数サービスの並列ビルドには --parallel 対応の docker-compose が必要です"
      exit 1
    fi
  fi
else
  err "docker compose / docker-compose が見つかりません"
  exit 1
fi

if [ "$DRY_RUN" = "true" ]; then
  log "*** DRY-RUN モードです。実際のビルド/起動/URL 呼び出し/ファイル操作は行いません。 ***"
fi

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
      log "[DRY-RUN] cp $src -> $dest (処理後に自動削除)"
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

# コピーしたファイルのみ削除する (EXIT トラップから呼び出す)。
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

# ---- 起動確認 / URL 確認 用ヘルパ -------------------------------------------
STARTED_CONTAINER="false"          # コンテナを起動したか (teardown 判定用)

# 対象コンテナの ID を取得する (引数でサービスを指定、未指定なら対象サービス全体)。
compose_container_ids() {
  if [ $# -gt 0 ]; then
    "${COMPOSE_CMD[@]}" -f "$COMPOSE_FILE" ps -q "$@" 2>/dev/null
  else
    "${COMPOSE_CMD[@]}" -f "$COMPOSE_FILE" ps -q ${COMPOSE_SERVICES[@]+"${COMPOSE_SERVICES[@]}"} 2>/dev/null
  fi
}

# ログを取得する (スナップショット)。引数でサービスを指定、未指定なら対象サービス全体。
compose_logs() {
  if [ $# -gt 0 ]; then
    "${COMPOSE_CMD[@]}" -f "$COMPOSE_FILE" logs --no-color "$@" 2>&1
  else
    "${COMPOSE_CMD[@]}" -f "$COMPOSE_FILE" logs --no-color ${COMPOSE_SERVICES[@]+"${COMPOSE_SERVICES[@]}"} 2>&1
  fi
}

# 対象コンテナがすべて実行中か確認する (途中停止 = 起動失敗の早期検知用)。
# 停止しているコンテナがあれば 1 を返す。
containers_all_running() {
  local cid running
  while IFS= read -r cid; do
    [ -n "$cid" ] || continue
    running="$(docker inspect -f '{{.State.Running}}' "$cid" 2>/dev/null)"
    if [ "$running" != "true" ]; then
      return 1
    fi
  done < <(compose_container_ids "$@")
  return 0
}

# コンテナを起動する (バックグラウンド)。対象サービスは 1 回の compose up で
# 同時に起動される。
start_container() {
  if [ ${#COMPOSE_SERVICES[@]} -gt 0 ]; then
    log "コンテナを同時に起動します (compose up -d, 対象サービス: ${COMPOSE_SERVICES[*]}) ..."
  else
    log "コンテナを起動します (compose up -d, 全サービス) ..."
  fi
  local up_args=(-f "$COMPOSE_FILE" up -d --no-build)
  up_args+=(${COMPOSE_SERVICES[@]+"${COMPOSE_SERVICES[@]}"})
  if ! run "${COMPOSE_CMD[@]}" ${COMPOSE_PARALLEL_OPTS[@]+"${COMPOSE_PARALLEL_OPTS[@]}"} "${up_args[@]}"; then
    err "コンテナの起動に失敗しました (compose up)"
    return 1
  fi
  STARTED_CONTAINER="true"
  return 0
}

# コンテナを停止・削除する (EXIT トラップから呼び出す)。
teardown_container() {
  [ "$STARTED_CONTAINER" = "true" ] || return 0
  if [ "$KEEP_CONTAINER" = "true" ]; then
    log "コンテナを残します (--keep-container)。手動で停止する場合: ${COMPOSE_CMD[*]} -f $COMPOSE_FILE down"
    return 0
  fi
  log "コンテナを停止・削除します (compose down) ..."
  if ! run "${COMPOSE_CMD[@]}" -f "$COMPOSE_FILE" down; then
    warn "コンテナの停止・削除に失敗しました。手動で確認してください: ${COMPOSE_CMD[*]} -f $COMPOSE_FILE down"
  fi
}

# jbosseap サーバーの起動完了をログから待つ。
# --startup-service 指定時は各サービスのログを個別に確認し、全サービスの
# 起動完了をもって成功とする。未指定時は対象サービス全体のログをまとめて確認する。
wait_for_startup() {
  local -a pending=()
  if [ ${#STARTUP_SERVICES[@]} -gt 0 ]; then
    pending=("${STARTUP_SERVICES[@]}")
    log "jbosseap サーバーの起動完了を確認します (対象サービス: ${pending[*]}, 最大 ${STARTUP_TIMEOUT}s, パターン: /${STARTUP_LOG_PATTERN}/) ..."
  else
    log "jbosseap サーバーの起動完了を確認します (最大 ${STARTUP_TIMEOUT}s, パターン: /${STARTUP_LOG_PATTERN}/) ..."
  fi
  if [ "$DRY_RUN" = "true" ]; then
    log "[DRY-RUN] compose logs を ${STARTUP_INTERVAL}s 間隔でポーリングし、上記パターンに一致するまで待ちます。"
    return 0
  fi
  local deadline now logs svc
  local -a remaining=()
  now="$(date +%s)"
  deadline=$(( now + STARTUP_TIMEOUT ))
  while :; do
    if [ ${#pending[@]} -gt 0 ]; then
      # サービスごとにログを確認し、起動完了したものを pending から外す。
      remaining=()
      for svc in "${pending[@]}"; do
        logs="$(compose_logs "$svc")"
        if printf '%s' "$logs" | grep -qE "$STARTUP_LOG_PATTERN"; then
          log "jbosseap サーバーの起動完了を確認しました: サービス '${svc}'"
          printf '%s' "$logs" | grep -E "$STARTUP_LOG_PATTERN" | tail -n1 | while IFS= read -r line; do
            diag "  起動ログ: ${line}"
          done
        else
          remaining+=("$svc")
        fi
      done
      pending=(${remaining[@]+"${remaining[@]}"})
      if [ ${#pending[@]} -eq 0 ]; then
        log "指定した全サービスの起動完了を確認しました。"
        return 0
      fi
    else
      logs="$(compose_logs)"
      if printf '%s' "$logs" | grep -qE "$STARTUP_LOG_PATTERN"; then
        log "jbosseap サーバーの起動完了を確認しました。"
        printf '%s' "$logs" | grep -E "$STARTUP_LOG_PATTERN" | tail -n1 | while IFS= read -r line; do
          diag "  起動ログ: ${line}"
        done
        return 0
      fi
    fi
    # コンテナが途中で停止していないか確認する (起動失敗の早期検知)。
    if ! containers_all_running ${pending[@]+"${pending[@]}"}; then
      err "コンテナが起動途中で停止しました。jbosseap の起動に失敗した可能性があります。"
      dump_startup_logs ${pending[@]+"${pending[@]}"}
      return 1
    fi
    now="$(date +%s)"
    if [ "$now" -ge "$deadline" ]; then
      if [ ${#pending[@]} -gt 0 ]; then
        err "起動確認がタイムアウトしました (${STARTUP_TIMEOUT}s 以内に起動完了ログを検出できなかったサービス: ${pending[*]})。"
      else
        err "起動確認がタイムアウトしました (${STARTUP_TIMEOUT}s 以内に起動完了ログを検出できませんでした)。"
      fi
      dump_startup_logs ${pending[@]+"${pending[@]}"}
      return 1
    fi
    sleep "$STARTUP_INTERVAL"
  done
}

# 失敗時にコンテナログの末尾を出力する (原因調査用)。
# 引数でサービスを指定した場合はそのサービスのログのみ出力する。
dump_startup_logs() {
  diag ""
  diag "───────────────────────────────────────────────────────────────────"
  if [ $# -gt 0 ]; then
    diag "コンテナログ (対象サービス: $*, 末尾 50 行):"
  else
    diag "コンテナログ (末尾 50 行):"
  fi
  diag "───────────────────────────────────────────────────────────────────"
  compose_logs "$@" | tail -n 50 >&2
  diag "───────────────────────────────────────────────────────────────────"
}

# 指定 URL へ HTTP リクエストを送り、期待するステータスコードを確認する。
verify_url() {
  local request_desc="[${URL_METHOD}] ${VERIFY_URL}"
  if [ -n "$URL_CONTENT_TYPE" ]; then
    request_desc="${request_desc} (Content-Type: ${URL_CONTENT_TYPE})"
  fi
  log "URL 応答を確認します: ${request_desc} (期待ステータス: ${EXPECT_STATUS}, 最大 ${URL_TIMEOUT}s) ..."
  if [ "$DRY_RUN" = "true" ]; then
    if [ -n "$URL_BODY_JSON" ]; then
      log "[DRY-RUN] JSON ボディ付きで curl を ${URL_INTERVAL}s 間隔で呼び出し、ステータス ${EXPECT_STATUS} を確認します。"
    elif [ -n "$URL_BODY_FORM" ]; then
      log "[DRY-RUN] form ボディ付きで curl を ${URL_INTERVAL}s 間隔で呼び出し、ステータス ${EXPECT_STATUS} を確認します。"
    else
      log "[DRY-RUN] curl で ${VERIFY_URL} を ${URL_INTERVAL}s 間隔で呼び出し、ステータス ${EXPECT_STATUS} を確認します。"
    fi
    return 0
  fi

  local curl_opts=(-s -S -m 30 -o "$URL_BODY_FILE" -w '%{http_code}' -X "$URL_METHOD")
  [ "$URL_INSECURE" = "true" ] && curl_opts+=(-k)
  [ -n "$URL_CONTENT_TYPE" ] && curl_opts+=(-H "Content-Type: ${URL_CONTENT_TYPE}")
  if [ -n "$URL_BODY_JSON" ]; then
    curl_opts+=(--data "$URL_BODY_JSON")
  elif [ -n "$URL_BODY_FORM" ]; then
    curl_opts+=(--data "$URL_BODY_FORM")
  fi

  local deadline now code last_code=""
  now="$(date +%s)"
  deadline=$(( now + URL_TIMEOUT ))
  while :; do
    # curl 失敗 (接続不可等) の場合は code が空/000 になるため、|| true で継続する。
    code="$(curl "${curl_opts[@]}" "$VERIFY_URL" 2>/dev/null || true)"
    [ -z "$code" ] && code="000"
    last_code="$code"
    if [ "$code" = "$EXPECT_STATUS" ]; then
      log "URL 応答を確認しました: HTTP ${code} (期待通り)。"
      show_url_body
      return 0
    fi
    now="$(date +%s)"
    if [ "$now" -ge "$deadline" ]; then
      err "URL 応答の確認に失敗しました: 最後の応答 HTTP ${last_code} (期待: ${EXPECT_STATUS})。"
      show_url_body
      return 1
    fi
    log "  HTTP ${code} (期待 ${EXPECT_STATUS} と不一致)。${URL_INTERVAL}s 後に再試行します ..."
    sleep "$URL_INTERVAL"
  done
}

# 直近の URL 応答本文を (先頭のみ) 表示する。
show_url_body() {
  [ -f "$URL_BODY_FILE" ] || return 0
  diag ""
  diag "───────────────────────────────────────────────────────────────────"
  diag "URL 応答本文 (先頭 20 行):"
  diag "───────────────────────────────────────────────────────────────────"
  head -n 20 "$URL_BODY_FILE" >&2
  diag "───────────────────────────────────────────────────────────────────"
}

# ---- 後始末 (コンテナ停止 → 一時ファイル削除 → 応答本文ファイル削除) --------
URL_BODY_FILE=""
cleanup_all() {
  teardown_container
  cleanup_copied_files
  [ -n "$URL_BODY_FILE" ] && rm -f "$URL_BODY_FILE"
}
# ビルド成功・失敗いずれの経路 (途中の exit を含む) でも確実に後始末する
trap cleanup_all EXIT

# URL 応答本文の一時ファイル (URL 確認時のみ使用)
if [ -n "$VERIFY_URL" ]; then
  URL_BODY_FILE="$(mktemp 2>/dev/null || printf '%s' "${TMPDIR:-/tmp}/url_body.$$")"
fi

# ---- JBoss マスターパスワードの取得 / シークレット注入準備 -------------------
prepare_jboss_password

# compose.yml の environment 型シークレット (既定: JBOSS_MASTER_PASSWORD) は、
# 環境変数が未定義だと compose build が失敗するため、シークレットを使わない
# 場合でも空文字で定義しておく (既に値が入っていればそのまま維持する)。
export JBOSS_MASTER_PASSWORD="${JBOSS_MASTER_PASSWORD:-}"

# ---- ビルド前の一時ファイルコピー -------------------------------------------
# ここでコピーしたファイルは EXIT トラップ (cleanup_all) により
# 処理終了後 / 途中終了時のいずれでも自動削除される。
prepare_copy_files

# ---- ビルド -----------------------------------------------------------------
BUILD_OPTS=()
if [ "$NO_CACHE" = "true" ]; then
  BUILD_OPTS+=(--no-cache)
  log "キャッシュを破棄して (--no-cache) ビルドします。"
fi

# ローカルベースイメージが生成されたか確認する。
# 複数サービス指定時は base の先行ビルド直後に確認し、問題があれば他サービスを
# ビルドする前に中止する。dry-run では実際にビルドしていないため確認をスキップする。
verify_local_image() {
  if [ "$DRY_RUN" = "true" ]; then
    log "[DRY-RUN] ローカルベースイメージの存在確認をスキップします: $LOCAL_IMAGE"
  elif ! docker image inspect "$LOCAL_IMAGE" >/dev/null 2>&1; then
    err "ローカルベースイメージが見つかりません: $LOCAL_IMAGE (compose.yml の image 指定を確認してください)"
    return 1
  else
    log "ローカルベースイメージを確認しました: $LOCAL_IMAGE"
  fi
  return 0
}

if [ ${#COMPOSE_SERVICES[@]} -gt 1 ]; then
  # ベースイメージを参照するサービス群と base を同時にビルドすると、base の
  # 完成前に他サービスのビルドが始まる可能性がある。そこで base を第 1 フェーズで
  # 必ず単独ビルドし、成功確認後に残りを 1 回の compose build で並列ビルドする。
  log "複数の compose サービスが指定されました。ベースサービス '${BASE_SERVICE}' を先行ビルドします ..."
  if ! run "${COMPOSE_CMD[@]}" ${COMPOSE_PARALLEL_OPTS[@]+"${COMPOSE_PARALLEL_OPTS[@]}"} -f "$COMPOSE_FILE" build ${COMPOSE_BUILD_PARALLEL_OPTS[@]+"${COMPOSE_BUILD_PARALLEL_OPTS[@]}"} ${BUILD_OPTS[@]+"${BUILD_OPTS[@]}"} "$BASE_SERVICE"; then
    err "ベースサービス '${BASE_SERVICE}' の先行ビルドに失敗しました"
    exit 1
  fi
  if ! verify_local_image; then
    exit 1
  fi

  # base が明示的な指定に含まれていても再ビルドしない。含まれていない場合も
  # base はビルド専用の前提サービスとして扱い、起動対象には追加しない。
  REMAINING_SERVICES=()
  for _service in "${COMPOSE_SERVICES[@]}"; do
    [ "$_service" = "$BASE_SERVICE" ] || REMAINING_SERVICES+=("$_service")
  done

  if [ ${#REMAINING_SERVICES[@]} -gt 0 ]; then
    log "ベースサービス以外をまとめて並列ビルドします (${COMPOSE_FILE}, 対象サービス: ${REMAINING_SERVICES[*]}) ..."
    if ! run "${COMPOSE_CMD[@]}" ${COMPOSE_PARALLEL_OPTS[@]+"${COMPOSE_PARALLEL_OPTS[@]}"} -f "$COMPOSE_FILE" build ${COMPOSE_BUILD_PARALLEL_OPTS[@]+"${COMPOSE_BUILD_PARALLEL_OPTS[@]}"} ${BUILD_OPTS[@]+"${BUILD_OPTS[@]}"} "${REMAINING_SERVICES[@]}"; then
      err "ベースサービス以外の compose build に失敗しました (対象サービス: ${REMAINING_SERVICES[*]})"
      exit 1
    fi
  else
    log "ベースサービス以外のビルド対象はありません。"
  fi
else
  if [ ${#COMPOSE_SERVICES[@]} -gt 0 ]; then
    log "docker compose build を実行します (${COMPOSE_FILE}, 対象サービス: ${COMPOSE_SERVICES[*]}) ..."
  else
    log "docker compose build を実行します (${COMPOSE_FILE}, 全サービス) ..."
  fi
  if ! run "${COMPOSE_CMD[@]}" ${COMPOSE_PARALLEL_OPTS[@]+"${COMPOSE_PARALLEL_OPTS[@]}"} -f "$COMPOSE_FILE" build ${COMPOSE_BUILD_PARALLEL_OPTS[@]+"${COMPOSE_BUILD_PARALLEL_OPTS[@]}"} ${BUILD_OPTS[@]+"${BUILD_OPTS[@]}"} ${COMPOSE_SERVICES[@]+"${COMPOSE_SERVICES[@]}"}; then
    err "compose build に失敗しました"
    exit 1
  fi
  if ! verify_local_image; then
    exit 1
  fi
fi

# ---- 起動確認が不要ならここで終了 -------------------------------------------
if [ "$NEED_CONTAINER" != "true" ]; then
  if [ "$DRY_RUN" = "true" ]; then
    log "[DRY-RUN] ビルドのみが完了しました (実際のビルドは行われていません)。"
  else
    log "ビルドのみが完了しました。"
  fi
  exit 0
fi

# ---- コンテナ起動 -----------------------------------------------------------
if ! start_container; then
  exit 1
fi

# ---- jbosseap 起動確認 ------------------------------------------------------
# --verify-startup 指定時はログから起動完了を確認する。
# (--verify-url のみの場合は起動ログ確認をスキップし、URL のリトライで readiness を担保する)
if [ "$VERIFY_STARTUP" = "true" ]; then
  if ! wait_for_startup; then
    err "起動確認に失敗しました。"
    exit 1
  fi
fi

# ---- URL 応答確認 -----------------------------------------------------------
if [ -n "$VERIFY_URL" ]; then
  if ! verify_url; then
    err "URL 応答確認に失敗しました。"
    exit 1
  fi
fi

if [ "$DRY_RUN" = "true" ]; then
  log "DRY-RUN が完了しました (実際の変更は行われていません)。"
else
  log "ビルドおよび確認が完了しました。"
fi
exit 0
