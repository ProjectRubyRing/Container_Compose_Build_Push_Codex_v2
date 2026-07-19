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
# ビルドに加えて、以下の確認・診断を任意で行える:
#   (1) --verify-startup : ビルドしたイメージをコンテナとして起動し、
#                          jbosseap (WildFly/JBoss EAP) サーバーの起動完了を
#                          ログから確認し、起動ログと重要ログの色分けを表示する。
#   (2) --verify-url URL : 起動確認後、指定 URL へ HTTP リクエストを送り、
#                          その応答 (ステータスコード/本文) を確認する。
#   (3) Compose サービスログ: 起動確認対象と同時に起動した他サービスのログを、
#                          起動ログの直後へサービス単位で順次表示する。
#   (4) ディレクトリツリー表示: 動作確認したコンテナのディレクトリを階層表示する。
#                          通常ファイルはオプション指定時のみ出力する。
#   (5) デプロイ構造表示    : JBoss デプロイ先、Web ルート、Java クラスパスルート、
#                          指定環境変数のディレクトリを検出して階層表示する。
#   (6) 全量レポート        : ビルド結果と全量の環境変数・ツリー・デプロイ構造を
#                          日時付きテキストファイルへ保存する。
#   (7) --keep-container-mode: 起動確認後もコンテナを残し、検証対象へ直接
#                          bash 接続するか、対話式の HTTP リクエストを実行する。
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
RUN_STARTED_AT="$(date '+%Y-%m-%d %H:%M:%S')"
RUN_TIMESTAMP="$(date '+%Y%m%d%H%M%S')"
LOCAL_IMAGE="j1/base.local"       # compose build で生成されるローカルベースイメージ名
COMPOSE_FILE="compose.yml"
COMPOSE_SERVICES=()               # 指定時はそのサービスのみビルド/起動 (複数指定可、空なら全サービス)
BASE_SERVICE="base"              # 複数サービス指定時に必ず先行ビルドするベースサービス名
NO_CACHE="false"                  # true: キャッシュを破棄してビルド (--no-cache)
DRY_RUN="false"                   # true: 実際の変更は行わず、実行内容のプレビューのみ表示
CLEANUP_ALL_DOCKER_DATA="false"   # true: 終了時に確認後、現在の Docker context の全データを削除
DOCKER_CLEANUP_CONFIRM_PHRASE="DELETE ALL DOCKER DATA"
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
# JBoss EAP 8.1 では WFLYSRV0025 が正常起動、WFLYSRV0026 はエラー付き起動を表す。
# 両者を成功扱いしないよう、正常系と異常系を明確に分離する。
STARTUP_LOG_PATTERN='WFLYSRV0025:'
STARTUP_FAILURE_LOG_PATTERN='WFLYSRV0026:|WFLYSRV0056:'
STARTUP_TIMEOUT="120"             # 起動完了を待つ最大秒数
STARTUP_INTERVAL="3"              # 起動確認ポーリング間隔 (秒)
KEEP_CONTAINER="false"            # true: 確認後もコンテナを停止・削除せずに残す
KEEP_CONTAINER_MODE=""            # bash/http: 確認後に実行する対話操作 (指定時はコンテナを残す)
SUPPRESS_REMOVED_LOGS="false"     # true: compose down の Removed ログ等を抑制する
SUPPRESS_STARTUP_LOGS="false"     # true: 起動確認対象と同時起動サービスのログ表示を抑制する
STARTUP_LOG_LINES="50"            # all: 全行表示 / 数値: 末尾からの最大表示行数
# EAP 8.1 の起動、ドライバー、データソース、リスナー、デプロイ、終了状態を
# 重要ログとして色分けする。
STARTUP_IMPORTANT_LOG_PATTERN='WFLYSRV0049|WFLYJCA0009|WFLYJCA0018|WFLYJCA0001|WFLYJCA0098|WFLYDS0013|WFLYSRV0027|WFLYSRV0207|WFLYUT0006|WFLYUT0021|WFLYSRV0010|WFLYSRV0051|WFLYSRV0060|WFLYSRV0025|WFLYSRV0026|WFLYSRV0056'
# 起動完了、ドライバー、データソース、HTTP リスナー、デプロイ完了は成功色で表示する。
STARTUP_SUCCESS_LOG_PATTERN='WFLYJCA0018|WFLYJCA0001|WFLYJCA0098|WFLYUT0006|WFLYUT0021|WFLYSRV0010|WFLYSRV0025'

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

# ---- 起動維持後の対話操作 関連 ----------------------------------------------
JBOSS_CONTEXT_ROOT=""             # HTTP モードで使うコンテキストルート (空ならログから検出)
JBOSS_HTTP_PORT=""                # JBoss EAP のコンテナ側 HTTP ポート (空ならログから検出)
INTERACTION_CONTAINER_ID=""
INTERACTION_SERVICE_NAME=""
INTERACTION_CONTAINER_NAME=""
INTERACTION_CONTEXT_ROOT=""
INTERACTION_CONTAINER_PORT=""
INTERACTION_HTTP_HOST=""
INTERACTION_HTTP_PORT=""
INTERACTIVE_HTTP_BODY_FILE=""
HTTP_REQUEST_METHOD=""
HTTP_REQUEST_PATH=""
HTTP_REQUEST_BODY=""
HTTP_REQUEST_CONTENT_TYPE=""

# BuildKit の tty 表示はログ保存時に途中経過が上書きされるため、未指定時は
# plain を使用して各ビルドステップの出力を確実に残す。利用者が環境変数を
# 明示している場合はその値を尊重する。
BUILD_PROGRESS="${BUILDKIT_PROGRESS:-plain}"

# ---- 環境変数一覧出力 --------------------------------------------------------
ENV_LIST_LIMIT="all"              # all: 全件表示 / 数値: 各コンテナごとの最大表示件数
ENV_LIST_FILE=""                  # 指定時は環境変数一覧をファイルにも出力
BUILD_ARG_ENV_NAMES_LOADED="false"
declare -A BUILD_ARG_ENV_NAME_SET=()

# ---- コンテナ内ディレクトリツリー出力 -----------------------------------------
DIRECTORY_TREE_DEPTH="all"        # all: 最下層まで / 数値: / 直下を 1 とする最大ディレクトリ深さ
DIRECTORY_TREE_DEPTH_SET="false"  # 深さが明示指定されたか (ビルドのみ実行時の警告用)
DIRECTORY_FILE_LIMIT="none"       # none: ファイル非表示 / all・数値: ファイル表示を有効化
DIRECTORY_FILE_LIMIT_SET="false"  # 表示上限が明示指定されたか (ビルドのみ実行時の警告用)
DEPLOYMENT_DIR_ENVS=()            # ディレクトリパスを値に持つ環境変数名 (複数指定可)
# コンテナ全体ツリーでは、巨大・仮想・実行基盤固有の各ディレクトリ配下を
# 探索しない。通常はディレクトリ自体を 1 ノードとして表示するが、
# DIRECTORY_TREE_HIDDEN_PATHS に含まれるパスはそのノードも表示しない。
# 個別のデプロイ構造表示には適用しない。
DIRECTORY_TREE_PRUNE_PATHS=(
  /afs
  /aws
  /etc
  /local/aws-cli
  /opt/jboss-eap/.galleon
  /opt/jboss-eap/modules/system/layers/base
  /proc
  /share/X11
  /share/doc
  /share/icons
  /share/licenses
  /share/man
  /share/osinfo
  /share/zoneinfo
  /sys
  /usr/lib
  /usr/lib64
)
# /share 配下の実行基盤固有ディレクトリは、枝刈りするだけでなく画面と
# 全量レポートの双方からディレクトリ自体も除外する。
DIRECTORY_TREE_HIDDEN_PATHS=(
  /share/X11
  /share/doc
  /share/icons
  /share/licenses
  /share/man
  /share/osinfo
  /share/zoneinfo
)

# ---- 全量ビルドレポート出力 --------------------------------------------------
BUILD_REPORT_DIR=""               # 指定時は日時付きテキストレポートをこの配下へ出力
BUILD_REPORT_DIR_SET="false"
BUILD_REPORT_FILE=""
BUILD_RESULT_STATUS="未実行"
BUILD_RESULT_DETAIL=""
BUILD_IMAGE_INFO=""

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

終了時の Docker 完全クリーンアップ:
  --cleanup-all-docker-data
                           処理終了時 (成功・失敗を問わず)、現在の Docker context にある
                           全コンテナ (Compose を含む。一時停止中は解除) を通常停止した後、
                           停止済みを含む全コンテナ、
                           全ローカルイメージ、全ローカルボリューム、未使用の
                           ユーザー定義ネットワーク、削除可能な全ビルドキャッシュを
                           削除する。
                           実行直前に削除対象と件数を表示し、確認フレーズの入力を
                           必須とする。確認できない場合は Docker 全体クリーンアップを
                           実行せず、終了コード 1 とする。
                           Docker daemon / Docker Desktop、標準ネットワーク、context、
                           認証情報、daemon 設定は削除・停止しない。
                           --keep-container とは同時に指定できない。

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
                           既定: 'WFLYSRV0025:' (WFLYSRV0026 は失敗扱い)
  --startup-timeout SEC    起動完了を待つ最大秒数 (既定: 120)
  --startup-interval SEC   起動確認のポーリング間隔・秒 (既定: 3)
  --startup-log-lines N|all
                           起動確認対象と、同時に起動した他 Compose サービスの
                           ログ画面表示行数。N は各サービスの末尾 N 行、all は
                           全行を表示する (既定: 50)
  --suppress-startup-logs  起動確認対象と同時起動サービスのログ表示を抑制する
                           (起動判定は継続)
  --keep-container         確認後もコンテナを停止・削除せずに残す (調査用)
  --keep-container-mode MODE
                           起動確認後もコンテナを残し、検証対象コンテナで MODE の
                           対話操作を実行する。指定時は --verify-startup と
                           --keep-container を暗黙に有効化する。
                           MODE:
                             bash  docker exec で /bin/bash へ直接接続する
                             http  JBoss EAP へ対話式の HTTP リクエストを送る
                           対象が複数ある場合は番号選択ダイアログを表示する。
  --jboss-context-root ROOT
                           http モードで使う JBoss EAP のコンテキストルート。
                           未指定時は WFLYUT0021 ログから検出し、複数なら選択する。
  --jboss-http-port PORT   http モードで使うコンテナ側 HTTP リスナーポート。
                           未指定時は WFLYUT0006 ログから検出する (検出不能時: 8080)。
                           Docker の公開ポートがあれば接続先ポートへ自動変換する。
  --suppress-removed-logs  compose down 実行時の "Container ... Removed" 等の
                           出力を抑制する (ログが煩雑な場合に使用)
  --env-list-limit N|all   動作確認成功時に表示する環境変数一覧の件数。
                           各対象コンテナごとに先頭 N 件を表示する。
                           既定: all (全件表示)
  --env-list-file FILE     動作確認成功時の環境変数一覧を FILE にも出力する。
                           画面表示は従来どおり継続する
  --directory-tree-depth N|all
                           環境変数一覧の後に表示するコンテナ内ディレクトリツリーの
                           最大深さ。/ 直下を深さ 1 とし、既定の all は最下層まで表示する。
                           JBoss EAP のデプロイ構造にも同じ深さを適用する
  --directory-file-limit N|all
                           通常ファイルの画面表示を有効にする。各ディレクトリ直下が
                           N 件以下なら全ファイル名、超過時は拡張子別件数を表示する。
                           all は件数にかかわらず全ファイル名を表示する。
                           未指定時はディレクトリのみを表示する
  --deployment-dir-env NAME
                           ディレクトリパスを値に持つコンテナ環境変数名。
                           JBoss デプロイ先、Web アプリケーションルート、
                           WEB-INF/classes と併せて、そのディレクトリ構造を表示する。
                           繰り返し指定またはカンマ区切りで複数指定できる
  --report-dir DIR         ビルド結果、環境変数一覧、コンテナ内ツリー、JBoss EAP
                           デプロイ構造を DIR/build_and_verify_<日時>.txt へ保存する。
                           保存内容は画面の制限にかかわらず全深度・全ファイル名となる

URL 応答確認:
  --verify-url URL         起動確認後、この URL へ HTTP リクエストを送り応答を確認する。
                           (単独指定でもコンテナを起動して確認する)
  --expect-status CODE     期待する HTTP ステータスコード (既定: 200)
  --url-method METHOD      HTTP メソッド (既定: GET)
  --url-content-type TYPE  verify-url 時の Content-Type ヘッダ値
  --url-body-json JSON     verify-url 時のリクエストボディに JSON を設定する。
                           Content-Type 未指定時は application/json を自動設定する。
  --url-body-form DATA     verify-url 時のリクエストボディに form データ
                           (key=value&...) を設定する。Content-Type 未指定時は
                           application/x-www-form-urlencoded を自動設定する。
  --url-timeout SEC        期待する応答を得るまで待つ最大秒数・リトライ。
                           対話式 http モードでは 1 リクエストの最大秒数 (既定: 60)
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
    --cleanup-all-docker-data) CLEANUP_ALL_DOCKER_DATA="true"; shift ;;
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
    --startup-log-lines)   STARTUP_LOG_LINES="$2"; shift 2 ;;
    --suppress-startup-logs) SUPPRESS_STARTUP_LOGS="true"; shift ;;
    --keep-container)      KEEP_CONTAINER="true"; shift ;;
    --keep-container-mode) KEEP_CONTAINER_MODE="$2"; shift 2 ;;
    --jboss-context-root)  JBOSS_CONTEXT_ROOT="$2"; shift 2 ;;
    --jboss-http-port)     JBOSS_HTTP_PORT="$2"; shift 2 ;;
    --suppress-removed-logs) SUPPRESS_REMOVED_LOGS="true"; shift ;;
    --env-list-limit)      ENV_LIST_LIMIT="$2"; shift 2 ;;
    --env-list-file)       ENV_LIST_FILE="$2"; shift 2 ;;
    --directory-tree-depth) DIRECTORY_TREE_DEPTH="$2"; DIRECTORY_TREE_DEPTH_SET="true"; shift 2 ;;
    --directory-file-limit) DIRECTORY_FILE_LIMIT="$2"; DIRECTORY_FILE_LIMIT_SET="true"; shift 2 ;;
    --deployment-dir-env) append_services DEPLOYMENT_DIR_ENVS "$2"; shift 2 ;;
    --report-dir)          BUILD_REPORT_DIR="$2"; BUILD_REPORT_DIR_SET="true"; shift 2 ;;
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

# 表示件数・階層深さは、何も表示されない指定を避けるため 1 以上に制限する。
validate_positive_integer() {
  local value="$1" opt_name="$2"
  case "$value" in
    ''|*[!0-9]*|0)
      err "${opt_name} には 1 以上の整数を指定してください: ${value}"
      return 1
    ;;
  esac
  return 0
}

if [ "$STARTUP_LOG_LINES" != "all" ]; then
  validate_positive_integer "$STARTUP_LOG_LINES" "--startup-log-lines" || exit 2
fi
validate_positive_integer "$STARTUP_TIMEOUT" "--startup-timeout" || exit 2
validate_positive_integer "$URL_TIMEOUT" "--url-timeout" || exit 2
if [ "$ENV_LIST_LIMIT" != "all" ]; then
  validate_positive_integer "$ENV_LIST_LIMIT" "--env-list-limit" || exit 2
fi
if [ "$DIRECTORY_TREE_DEPTH" != "all" ]; then
  validate_positive_integer "$DIRECTORY_TREE_DEPTH" "--directory-tree-depth" || exit 2
fi
if [ "$DIRECTORY_FILE_LIMIT_SET" = "true" ] && [ "$DIRECTORY_FILE_LIMIT" != "all" ]; then
  validate_positive_integer "$DIRECTORY_FILE_LIMIT" "--directory-file-limit" || exit 2
fi
for _deployment_env in "${DEPLOYMENT_DIR_ENVS[@]}"; do
  if ! printf '%s' "$_deployment_env" | grep -qE '^[A-Za-z_][A-Za-z0-9_]*$'; then
    err "--deployment-dir-env に不正な環境変数名が指定されました: $_deployment_env"
    exit 2
  fi
done
if [ "$BUILD_REPORT_DIR_SET" = "true" ] && { [ -z "$BUILD_REPORT_DIR" ] || [ "$BUILD_REPORT_DIR" = "-" ]; }; then
  err "--report-dir にはディレクトリパスを指定してください: $BUILD_REPORT_DIR"
  exit 2
fi

case "$KEEP_CONTAINER_MODE" in
  "") ;;
  bash|http)
    KEEP_CONTAINER="true"
    VERIFY_STARTUP="true"
    ;;
  *)
    err "--keep-container-mode には bash または http を指定してください: ${KEEP_CONTAINER_MODE}"
    exit 2
    ;;
esac

if [ -n "$JBOSS_HTTP_PORT" ]; then
  case "$JBOSS_HTTP_PORT" in
    *[!0-9]*)
      err "--jboss-http-port には 1 から 65535 の範囲を指定してください: ${JBOSS_HTTP_PORT}"
      exit 2
      ;;
  esac
  if [ "${#JBOSS_HTTP_PORT}" -gt 5 ] \
      || (( 10#$JBOSS_HTTP_PORT < 1 || 10#$JBOSS_HTTP_PORT > 65535 )); then
    err "--jboss-http-port には 1 から 65535 の範囲を指定してください: ${JBOSS_HTTP_PORT}"
    exit 2
  fi
fi

if { [ -n "$JBOSS_CONTEXT_ROOT" ] || [ -n "$JBOSS_HTTP_PORT" ]; } \
    && [ "$KEEP_CONTAINER_MODE" != "http" ]; then
  err "--jboss-context-root / --jboss-http-port は --keep-container-mode http と併用してください"
  exit 2
fi

if [ -n "$JBOSS_CONTEXT_ROOT" ]; then
  case "$JBOSS_CONTEXT_ROOT" in
    *://*|*\?*|*\#*|*[[:space:]]*)
      err "--jboss-context-root には URL ではなくコンテキストルートのパスだけを指定してください: ${JBOSS_CONTEXT_ROOT}"
      exit 2
      ;;
  esac
fi

if [ "$CLEANUP_ALL_DOCKER_DATA" = "true" ] && [ "$KEEP_CONTAINER" = "true" ]; then
  err "--cleanup-all-docker-data と --keep-container は同時に指定できません"
  exit 2
fi

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
  err "--url-body-json と --url-body-form は同時に指定できません (リクエストボディは一つのみ指定できます)"
  exit 2
fi

# verify-url 用の追加指定は --verify-url と組み合わせて使う。
HAS_URL_REQUEST_OPTIONS="false"
if [ -n "$URL_CONTENT_TYPE" ] || [ -n "$URL_BODY_JSON" ] || [ -n "$URL_BODY_FORM" ]; then
  HAS_URL_REQUEST_OPTIONS="true"
fi
if [ -z "$VERIFY_URL" ] && [ "$HAS_URL_REQUEST_OPTIONS" = "true" ]; then
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
# ビルドには docker が必須。URL 応答確認または対話式 HTTP 通信では curl も必須。
# パラメータストアからパスワードを取得する場合は aws も必須。
REQUIRED_CMDS=(docker)
if [ -n "$VERIFY_URL" ] || [ "$KEEP_CONTAINER_MODE" = "http" ]; then
  REQUIRED_CMDS+=(curl)
fi
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
CONTAINER_LOG_SINCE=""             # 今回の起動より前のコンテナログを除外する基準時刻

# 対象コンテナの ID を取得する (引数でサービスを指定、未指定なら対象サービス全体)。
compose_container_ids() {
  if [ $# -gt 0 ]; then
    "${COMPOSE_CMD[@]}" -f "$COMPOSE_FILE" ps -q "$@" 2>/dev/null
  else
    "${COMPOSE_CMD[@]}" -f "$COMPOSE_FILE" ps -q ${COMPOSE_SERVICES[@]+"${COMPOSE_SERVICES[@]}"} 2>/dev/null
  fi
}

# 環境変数一覧とディレクトリツリーで共通して使う対象コンテナ ID を取得する。
# 起動確認サービスが明示されている場合はその対象を優先し、それ以外はビルド・起動
# 対象の Compose サービス (未指定なら全サービス) を対象とする。
verification_target_container_ids() {
  if [ ${#STARTUP_SERVICES[@]} -gt 0 ]; then
    compose_container_ids "${STARTUP_SERVICES[@]}"
  elif [ ${#COMPOSE_SERVICES[@]} -gt 0 ]; then
    compose_container_ids "${COMPOSE_SERVICES[@]}"
  else
    compose_container_ids
  fi
}

# ログを取得する (スナップショット)。引数でサービスを指定、未指定なら対象サービス全体。
compose_logs() {
  local -a log_args=(-f "$COMPOSE_FILE" logs --no-color)
  if [ -n "$CONTAINER_LOG_SINCE" ]; then
    log_args+=(--since "$CONTAINER_LOG_SINCE")
  fi
  if [ $# -gt 0 ]; then
    "${COMPOSE_CMD[@]}" "${log_args[@]}" "$@" 2>&1
  else
    "${COMPOSE_CMD[@]}" "${log_args[@]}" ${COMPOSE_SERVICES[@]+"${COMPOSE_SERVICES[@]}"} 2>&1
  fi
}

# JBoss のコンソールカラーは compose logs --no-color では除去されないため、
# EAP のメッセージ解析前に ANSI SGR シーケンスを取り除く。
strip_ansi_codes() {
  LC_ALL=C sed $'s/\033\[[0-9;]*m//g'
}

# 端末への直接表示時だけ色を付ける。NO_COLOR を優先し、リダイレクトされたログへ
# ANSI シーケンスを混入させない。CLICOLOR_FORCE はテストや明示的な強制表示に使える。
startup_log_color_enabled() {
  [ -z "${NO_COLOR+x}" ] || return 1
  case "${CLICOLOR_FORCE:-0}" in
    0) ;;
    *) return 0 ;;
  esac
  [ -t 2 ] && [ "${TERM:-}" != "dumb" ]
}

# JBoss EAP の重要行を意味別に色分けし、その他の行はそのまま表示する。
print_startup_logs_with_highlights() {
  local logs="$1" line color
  local use_color="false"
  local error_level_pattern='[[:space:]](ERROR|FATAL)[[:space:]]'
  local warning_level_pattern='[[:space:]]WARN(ING)?[[:space:]]'
  local color_red=$'\033[1;31m' color_yellow=$'\033[1;33m'
  local color_green=$'\033[1;32m' color_cyan=$'\033[1;36m' color_reset=$'\033[0m'

  startup_log_color_enabled && use_color="true"
  while IFS= read -r line || [ -n "$line" ]; do
    color=""
    if [ "$use_color" = "true" ]; then
      if [[ "$line" =~ $error_level_pattern ]] || [[ "$line" =~ $STARTUP_FAILURE_LOG_PATTERN ]]; then
        color="$color_red"
      elif [[ "$line" =~ $warning_level_pattern ]]; then
        color="$color_yellow"
      elif [[ "$line" =~ $STARTUP_SUCCESS_LOG_PATTERN ]] || [[ "$line" =~ $STARTUP_LOG_PATTERN ]]; then
        color="$color_green"
      elif [[ "$line" =~ $STARTUP_IMPORTANT_LOG_PATTERN ]]; then
        color="$color_cyan"
      fi
    fi
    if [ -n "$color" ]; then
      printf '%s%s%s\n' "$color" "$line" "$color_reset" >&2
    else
      printf '%s\n' "$line" >&2
    fi
  done <<< "$logs"
}

show_startup_logs() {
  local logs="$1" target_desc="$2" allow_suppression="${3:-true}"
  local selected normalized_logs total_count shown_count display_range

  if [ "$allow_suppression" = "true" ] && [ "$SUPPRESS_STARTUP_LOGS" = "true" ]; then
    log "コンテナ起動ログの表示を抑制しました (--suppress-startup-logs)。"
    return 0
  fi

  normalized_logs="$(printf '%s\n' "$logs" | strip_ansi_codes)"
  if [ -n "$normalized_logs" ]; then
    total_count="$(printf '%s\n' "$normalized_logs" | awk 'END { print NR }')"
  else
    total_count=0
  fi

  if [ "$STARTUP_LOG_LINES" = "all" ]; then
    selected="$normalized_logs"
    shown_count="$total_count"
    display_range="全 ${total_count} 行"
  else
    selected="$(printf '%s\n' "$normalized_logs" | tail -n "$STARTUP_LOG_LINES")"
    if [ -n "$selected" ]; then
      shown_count="$(printf '%s\n' "$selected" | awk 'END { print NR }')"
    else
      shown_count=0
    fi
    display_range="末尾 ${shown_count}/${total_count} 行 (指定上限: ${STARTUP_LOG_LINES})"
  fi

  diag ""
  diag "───────────────────────────────────────────────────────────────────"
  diag "コンテナ起動ログ (${target_desc}, ${display_range}):"
  diag "───────────────────────────────────────────────────────────────────"
  if [ -n "$selected" ]; then
    if startup_log_color_enabled; then
      printf '色分け: \033[1;32m成功\033[0m / \033[1;36m重要\033[0m / \033[1;33m警告\033[0m / \033[1;31mエラー\033[0m\n' >&2
    fi
    print_startup_logs_with_highlights "$selected"
  else
    diag "表示対象のコンテナ起動ログはありません。"
  fi
  diag "───────────────────────────────────────────────────────────────────"
}

# 現在起動している Compose サービス名を、Compose が返す順序を保って列挙する。
# ps --services を利用できない旧実装では、明示された起動対象またはコンテナラベルへ
# フォールバックする。
compose_started_services() {
  local services cid service_name
  services="$("${COMPOSE_CMD[@]}" -f "$COMPOSE_FILE" ps --services 2>/dev/null || true)"
  if [ -n "$services" ]; then
    printf '%s\n' "$services" | awk 'NF && !seen[$0]++'
    return 0
  fi
  if [ ${#COMPOSE_SERVICES[@]} -gt 0 ]; then
    printf '%s\n' "${COMPOSE_SERVICES[@]}" | awk 'NF && !seen[$0]++'
    return 0
  fi
  while IFS= read -r cid; do
    [ -n "$cid" ] || continue
    service_name="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.service" }}' "$cid" 2>/dev/null || true)"
    [ -n "$service_name" ] && printf '%s\n' "$service_name"
  done < <(compose_container_ids) | awk 'NF && !seen[$0]++'
}

# 起動確認対象以外で、同じ compose up により現在起動しているサービスのログを、
# 起動確認ログと同じ行数設定でサービス単位に順次表示する。
show_companion_service_logs() {
  local allow_suppression="${1:-true}"
  local svc logs normalized_logs selected total_count shown_count display_range
  local -a started_services=()
  local -A verification_services=()

  if [ "$allow_suppression" = "true" ] && [ "$SUPPRESS_STARTUP_LOGS" = "true" ]; then
    return 0
  fi

  mapfile -t started_services < <(compose_started_services)
  if [ ${#STARTUP_SERVICES[@]} -gt 0 ]; then
    for svc in "${STARTUP_SERVICES[@]}"; do
      verification_services["$svc"]=1
    done
  elif [ ${#COMPOSE_SERVICES[@]} -gt 0 ]; then
    for svc in "${COMPOSE_SERVICES[@]}"; do
      verification_services["$svc"]=1
    done
  else
    # 起動対象を限定していない場合、起動確認ログには全サービスが含まれている。
    for svc in "${started_services[@]}"; do
      verification_services["$svc"]=1
    done
  fi

  for svc in "${started_services[@]}"; do
    [ -n "$svc" ] || continue
    [ -z "${verification_services[$svc]+_}" ] || continue
    logs="$(compose_logs "$svc")"
    normalized_logs="$(printf '%s\n' "$logs" | strip_ansi_codes)"
    if [ -n "$normalized_logs" ]; then
      total_count="$(printf '%s\n' "$normalized_logs" | awk 'END { print NR }')"
    else
      total_count=0
    fi
    if [ "$STARTUP_LOG_LINES" = "all" ]; then
      selected="$normalized_logs"
      shown_count="$total_count"
      display_range="全 ${total_count} 行"
    else
      selected="$(printf '%s\n' "$normalized_logs" | tail -n "$STARTUP_LOG_LINES")"
      if [ -n "$selected" ]; then
        shown_count="$(printf '%s\n' "$selected" | awk 'END { print NR }')"
      else
        shown_count=0
      fi
      display_range="末尾 ${shown_count}/${total_count} 行 (指定上限: ${STARTUP_LOG_LINES})"
    fi

    diag ""
    diag "───────────────────────────────────────────────────────────────────"
    diag "同時起動 Compose サービスログ (サービス: ${svc}, ${display_range}):"
    diag "───────────────────────────────────────────────────────────────────"
    if [ -n "$selected" ]; then
      printf '%s\n' "$selected" >&2
    else
      diag "表示対象のサービスログはありません。"
    fi
    diag "───────────────────────────────────────────────────────────────────"
  done
}

normalize_container_name() {
  local name="$1"
  printf '%s\n' "${name#/}"
}

compose_file_dir() {
  local compose_dir
  compose_dir="$(cd "$(dirname "$COMPOSE_FILE")" 2>/dev/null && pwd -P)" || return 1
  printf '%s\n' "$compose_dir"
}

compose_dockerfiles() {
  local compose_dir dockerfile_path cleaned found="false"
  compose_dir="$(compose_file_dir)" || return 0
  while IFS= read -r dockerfile_path; do
    [ -n "$dockerfile_path" ] || continue
    cleaned="${dockerfile_path#\"}"
    cleaned="${cleaned%\"}"
    cleaned="${cleaned#\'}"
    cleaned="${cleaned%\'}"
    if [ "${cleaned#/}" = "$cleaned" ]; then
      cleaned="${compose_dir}/${cleaned}"
    fi
    printf '%s\n' "$cleaned"
    found="true"
  done < <(sed -n 's/^[[:space:]]*dockerfile:[[:space:]]*//p' "$COMPOSE_FILE")
  if [ "$found" != "true" ] && [ -f "${compose_dir}/Dockerfile" ]; then
    printf '%s\n' "${compose_dir}/Dockerfile"
  fi
}

collect_build_arg_env_names_from_dockerfile() {
  local dockerfile="$1"
  [ -f "$dockerfile" ] || return 0
  local physical_line logical_line="" trimmed env_body key value arg_name
  local -a env_tokens=()
  local -a arg_names=()
  local -A arg_name_set=()
  local -A env_name_set=()

  while IFS= read -r physical_line || [ -n "$physical_line" ]; do
    if [ -n "$logical_line" ]; then
      logical_line="${logical_line}${physical_line}"
    else
      logical_line="$physical_line"
    fi
    if [[ "$logical_line" == *\\ ]]; then
      logical_line="${logical_line%\\} "
      continue
    fi

    trimmed="${logical_line#"${logical_line%%[![:space:]]*}"}"
    logical_line=""
    [ -n "$trimmed" ] || continue
    case "$trimmed" in
      \#*) continue ;;
    esac

    if [[ "$trimmed" =~ ^ARG[[:space:]]+([A-Za-z_][A-Za-z0-9_]*) ]]; then
      arg_name="${BASH_REMATCH[1]}"
      arg_name_set["$arg_name"]=1
      continue
    fi

    if [[ "$trimmed" =~ ^ENV[[:space:]]+(.+)$ ]]; then
      env_body="${BASH_REMATCH[1]}"
      env_tokens=()
      read -r -a env_tokens <<< "$env_body"
      if [ ${#env_tokens[@]} -ge 2 ] && [[ "${env_tokens[0]}" != *=* ]]; then
        key="${env_tokens[0]}"
        value="${env_tokens[1]}"
        for arg_name in "${!arg_name_set[@]}"; do
          case "$value" in
            *"\${${arg_name}}"*|*"\$${arg_name}"*)
              env_name_set["$key"]=1
              break
            ;;
          esac
        done
      fi
      for value in "${env_tokens[@]}"; do
        case "$value" in
          *=*)
            key="${value%%=*}"
            value="${value#*=}"
            for arg_name in "${!arg_name_set[@]}"; do
              case "$value" in
                *"\${${arg_name}}"*|*"\$${arg_name}"*)
                  env_name_set["$key"]=1
                  break
                ;;
              esac
            done
          ;;
        esac
      done
    fi
  done < "$dockerfile"

  for key in "${!env_name_set[@]}"; do
    printf '%s\n' "$key"
  done | sort
}

load_build_arg_env_name_set() {
  [ "$BUILD_ARG_ENV_NAMES_LOADED" = "true" ] && return 0
  local dockerfile env_name
  while IFS= read -r dockerfile; do
    [ -f "$dockerfile" ] || continue
    while IFS= read -r env_name; do
      [ -n "$env_name" ] || continue
      BUILD_ARG_ENV_NAME_SET["$env_name"]=1
    done < <(collect_build_arg_env_names_from_dockerfile "$dockerfile")
  done < <(compose_dockerfiles)
  BUILD_ARG_ENV_NAMES_LOADED="true"
}

collect_container_pid1_env() {
  local cid="$1"
  if docker exec "$cid" /bin/sh -lc "tr '\\0' '\\n' </proc/1/environ" 2>/dev/null; then
    return 0
  fi
  docker exec "$cid" env 2>/dev/null || true
}

collect_container_config_env() {
  local cid="$1"
  docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$cid" 2>/dev/null || true
}

collect_container_image_env() {
  local cid="$1" image_id
  image_id="$(docker inspect -f '{{.Image}}' "$cid" 2>/dev/null)" || return 0
  [ -n "$image_id" ] || return 0
  docker image inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$image_id" 2>/dev/null || true
}

append_env_names_by_type() {
  local report_file="$1" type_label="$2"
  shift 2
  local -a names=("$@")
  printf '[%s] %s 件\n' "$type_label" "${#names[@]}" >> "$report_file"
  if [ ${#names[@]} -eq 0 ]; then
    printf '  (なし)\n' >> "$report_file"
    return 0
  fi
  printf '%s\n' "${names[@]}" | sed 's/^/  /' >> "$report_file"
}

append_container_env_report() {
  local cid="$1" service_name="$2" container_name="$3" report_file="$4"
  local env_limit="${5:-$ENV_LIST_LIMIT}"
  local line key value kv type_label shown_count total_count upper_key
  local -a sorted_names=()
  local -a compose_names=() build_arg_names=() internal_names=() other_names=()
  declare -A process_env_values=()
  declare -A container_env_values=()
  declare -A image_env_values=()
  declare -A compose_runtime_name_set=()

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    key="${line%%=*}"
    [ -n "$key" ] || continue
    value=""
    [ "$key" != "$line" ] && value="${line#*=}"
    process_env_values["$key"]="$value"
  done < <(collect_container_pid1_env "$cid")

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    key="${line%%=*}"
    [ -n "$key" ] || continue
    value=""
    [ "$key" != "$line" ] && value="${line#*=}"
    container_env_values["$key"]="$value"
  done < <(collect_container_config_env "$cid")

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    key="${line%%=*}"
    [ -n "$key" ] || continue
    value=""
    [ "$key" != "$line" ] && value="${line#*=}"
    image_env_values["$key"]="$value"
  done < <(collect_container_image_env "$cid")

  for key in "${!container_env_values[@]}"; do
    if [ -z "${image_env_values[$key]+_}" ] || [ "${container_env_values[$key]}" != "${image_env_values[$key]}" ]; then
      compose_runtime_name_set["$key"]=1
    fi
  done

  mapfile -t sorted_names < <(printf '%s\n' "${!process_env_values[@]}" | sort)
  total_count="${#sorted_names[@]}"
  shown_count="$total_count"
  if [ "$env_limit" != "all" ] && [ "$env_limit" -lt "$shown_count" ]; then
    shown_count="$env_limit"
  fi

  printf '\n' >> "$report_file"
  printf '───────────────────────────────────────────────────────────────────\n' >> "$report_file"
  printf '環境変数一覧 (サービス: %s, コンテナ: %s, 表示件数: %s/%s)\n' "$service_name" "$container_name" "$shown_count" "$total_count" >> "$report_file"
  printf '種別: compose.yml environment / build引数 / コンテナ内部処理 / イメージ既定・その他\n' >> "$report_file"
  printf '───────────────────────────────────────────────────────────────────\n' >> "$report_file"

  shown_count=0
  for key in "${sorted_names[@]}"; do
    if [ "$env_limit" != "all" ] && [ "$shown_count" -ge "$env_limit" ]; then
      break
    fi
    value="${process_env_values[$key]}"
    upper_key="${key^^}"
    # 一覧と全量レポートへ認証情報を平文で残さない。名前は分類確認のため維持する。
    case "$upper_key" in
      *PASSWORD*|*PASSWD*|*TOKEN*|*SECRET*|*PRIVATE_KEY*|*ACCESS_KEY*|*API_KEY*|*CREDENTIAL*)
        value="[REDACTED]"
        ;;
    esac
    if [ "$key" = "$JBOSS_PASSWORD_ENV" ]; then
      value="[REDACTED]"
    fi
    kv="${key}=${value}"
    if [ -z "${container_env_values[$key]+_}" ]; then
      internal_names+=("$kv")
    elif [ -n "${compose_runtime_name_set[$key]+_}" ]; then
      compose_names+=("$kv")
    elif [ -n "${BUILD_ARG_ENV_NAME_SET[$key]+_}" ]; then
      build_arg_names+=("$kv")
    else
      other_names+=("$kv")
    fi
    shown_count=$((shown_count + 1))
  done

  append_env_names_by_type "$report_file" "compose.yml environment" "${compose_names[@]}"
  append_env_names_by_type "$report_file" "build引数" "${build_arg_names[@]}"
  append_env_names_by_type "$report_file" "コンテナ内部処理" "${internal_names[@]}"
  append_env_names_by_type "$report_file" "イメージ既定・その他" "${other_names[@]}"
}

show_verified_container_envs() {
  [ "$DRY_RUN" = "true" ] && {
    log "[DRY-RUN] 動作確認成功後の環境変数一覧出力をプレビューします。"
    return 0
  }

  local report_file cid service_name container_name env_report_tmp
  local -a target_container_ids=()

  mapfile -t target_container_ids < <(verification_target_container_ids)

  if [ ${#target_container_ids[@]} -eq 0 ]; then
    warn "環境変数一覧を出力できませんでした。対象コンテナが見つかりません。"
    return 0
  fi

  load_build_arg_env_name_set
  env_report_tmp="$(mktemp 2>/dev/null || printf '%s' "${TMPDIR:-/tmp}/env_report.$$")"
  : > "$env_report_tmp"

  for cid in "${target_container_ids[@]}"; do
    [ -n "$cid" ] || continue
    service_name="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.service" }}' "$cid" 2>/dev/null || true)"
    [ -n "$service_name" ] || service_name="(unknown)"
    container_name="$(normalize_container_name "$(docker inspect -f '{{.Name}}' "$cid" 2>/dev/null || printf '%s' "$cid")")"
    append_container_env_report "$cid" "$service_name" "$container_name" "$env_report_tmp"
  done

  diag ""
  while IFS= read -r report_file; do
    diag "$report_file"
  done < "$env_report_tmp"

  if [ -n "$ENV_LIST_FILE" ]; then
    mkdir -p "$(dirname "$ENV_LIST_FILE")" 2>/dev/null || true
    if cp "$env_report_tmp" "$ENV_LIST_FILE" 2>/dev/null; then
      log "環境変数一覧をファイルへ出力しました: $ENV_LIST_FILE"
    else
      warn "環境変数一覧のファイル出力に失敗しました: $ENV_LIST_FILE"
    fi
  fi

  rm -f "$env_report_tmp"
}

# 1 コンテナ内の指定ルートを report_file へ追記する。コンテナ内に追加の
# スクリプトや tree コマンドを要求しないよう、find の NUL 区切り出力をホスト側の
# Bash で集計し、tree コマンドと同じ罫線記号で表示する。file_limit が none の
# 場合はディレクトリだけを取得する。
# それ以外は、直下のファイル数が file_limit 以下なら名前を、超える場合は
# 最終拡張子 (例: archive.tar.gz は .gz) ごとの件数を出力する。
append_container_directory_tree_report() {
  local cid="$1" service_name="$2" container_name="$3" report_file="$4"
  local root_path="${5:-/}" report_title="${6:-コンテナ内ディレクトリツリー}"
  local tree_depth="${7:-$DIRECTORY_TREE_DEPTH}" file_limit="${8:-$DIRECTORY_FILE_LIMIT}"
  local directory_list_tmp file_list_tmp directory_find_status=0 file_find_status=0
  local file_max_depth directory file_path parent filename suffix extension key count file_count
  local failure_message
  local display_name extension_list filename_list ancestor prefix connector is_last index
  local hidden_path hide_directory
  local -a directory_find_args=()
  local -a file_find_args=()
  local -a directory_paths=()
  local -a visible_directory_paths=()
  local -a ancestor_chain=()
  local -a leaf_entries=()
  local -A extension_counts=()
  local -A directory_extension_lists=()
  local -A directory_file_counts=()
  local -A directory_filename_lists=()
  local -A directory_child_counts=()
  local -A last_child_directory=()
  local -A directory_is_last=()

  # / 以外は末尾のスラッシュを除き、find の出力と親パスの比較を安定させる。
  if [ "$root_path" != "/" ]; then
    root_path="${root_path%/}"
  fi
  directory_find_args=(find "$root_path")
  if [ "$file_limit" != "none" ]; then
    file_find_args=(find "$root_path")
  fi

  if ! directory_list_tmp="$(mktemp 2>/dev/null)"; then
    warn "ディレクトリツリー集計用の一時ファイルを作成できませんでした (サービス: ${service_name})。"
    return 0
  fi
  if ! file_list_tmp="$(mktemp 2>/dev/null)"; then
    rm -f -- "$directory_list_tmp"
    warn "ディレクトリツリー集計用の一時ファイルを作成できませんでした (サービス: ${service_name})。"
    return 0
  fi

  if [ "$tree_depth" != "all" ]; then
    directory_find_args+=(-maxdepth "$tree_depth")
    if [ "$file_limit" != "none" ]; then
      file_max_depth="$((10#$tree_depth + 1))"
      file_find_args+=(-maxdepth "$file_max_depth")
    fi
  fi

  # コンテナ全体のツリーでは、巨大な仮想ファイルシステム等を find 自体で枝刈り
  # する。対象ディレクトリは 1 ノードとして出力し、その配下だけを探索しない。
  if [ "$root_path" = "/" ] && [ "$report_title" = "コンテナ内ディレクトリツリー" ]; then
    directory_find_args+=("(")
    if [ "$file_limit" != "none" ]; then
      file_find_args+=("(")
    fi
    for index in "${!DIRECTORY_TREE_PRUNE_PATHS[@]}"; do
      if [ "$index" -gt 0 ]; then
        directory_find_args+=(-o)
        if [ "$file_limit" != "none" ]; then
          file_find_args+=(-o)
        fi
      fi
      directory_find_args+=(-path "${DIRECTORY_TREE_PRUNE_PATHS[$index]}")
      if [ "$file_limit" != "none" ]; then
        file_find_args+=(-path "${DIRECTORY_TREE_PRUNE_PATHS[$index]}")
      fi
    done
    directory_find_args+=(")" -prune -print0 -o)
    if [ "$file_limit" != "none" ]; then
      file_find_args+=(")" -prune -o)
    fi
  fi
  directory_find_args+=(-type d -print0)
  if [ "$file_limit" != "none" ]; then
    file_find_args+=(-type f -print0)
  fi

  docker exec "$cid" "${directory_find_args[@]}" > "$directory_list_tmp" 2>/dev/null || directory_find_status=$?
  if [ "$file_limit" != "none" ]; then
    docker exec "$cid" "${file_find_args[@]}" > "$file_list_tmp" 2>/dev/null || file_find_status=$?
  fi

  if [ ! -s "$directory_list_tmp" ]; then
    failure_message="${report_title}を取得できませんでした (サービス: ${service_name}, コンテナ: ${container_name}, ルート: ${root_path})。コンテナ内のパスと find コマンドを確認してください。"
    printf '\n[WARN] %s\n' "$failure_message" >> "$report_file"
    rm -f -- "$directory_list_tmp" "$file_list_tmp"
    return 0
  fi

  while IFS= read -r -d '' file_path; do
    parent="${file_path%/*}"
    [ -n "$parent" ] || parent="/"
    filename="${file_path##*/}"
    extension="(拡張子なし)"
    if [ -z "${directory_file_counts[$parent]+_}" ]; then
      directory_file_counts["$parent"]=1
      directory_filename_lists["$parent"]="$filename"
    else
      file_count="${directory_file_counts[$parent]}"
      directory_file_counts["$parent"]=$((file_count + 1))
      directory_filename_lists["$parent"]+=$'\n'"$filename"
    fi

    # 先頭のドットだけを持つファイル (.env など) と末尾がドットのファイルは
    # 拡張子なしとして扱う。.env.local のように後続のドットがあれば .local とする。
    case "$filename" in
      .*)
        suffix="${filename#.}"
        case "$suffix" in
          *.*)
            suffix="${filename##*.}"
            [ -n "$suffix" ] && extension=".${suffix}"
          ;;
        esac
      ;;
      *.*)
        suffix="${filename##*.}"
        [ -n "$suffix" ] && extension=".${suffix}"
      ;;
    esac

    key="${parent}"$'\x1f'"${extension}"
    if [ -z "${extension_counts[$key]+_}" ]; then
      extension_counts["$key"]=1
      if [ -z "${directory_extension_lists[$parent]+_}" ]; then
        directory_extension_lists["$parent"]="$extension"
      else
        directory_extension_lists["$parent"]+=$'\n'"$extension"
      fi
    else
      count="${extension_counts[$key]}"
      extension_counts["$key"]=$((count + 1))
    fi
  done < "$file_list_tmp"

  # 親ごとの最後の子ディレクトリを先に確定し、├── / └── と祖先の │ を
  # 正しく選択できるようにする。ファイル行は各親の先頭、ディレクトリ行は
  # その後に出すため、最後の子ディレクトリが親全体の最後のノードになる。
  mapfile -d '' -t directory_paths < <(LC_ALL=C sort -z "$directory_list_tmp")
  if [ "$root_path" = "/" ] && [ "$report_title" = "コンテナ内ディレクトリツリー" ]; then
    for directory in "${directory_paths[@]}"; do
      hide_directory="false"
      for hidden_path in "${DIRECTORY_TREE_HIDDEN_PATHS[@]}"; do
        if [ "$directory" = "$hidden_path" ]; then
          hide_directory="true"
          break
        fi
      done
      [ "$hide_directory" = "true" ] || visible_directory_paths+=("$directory")
    done
    directory_paths=("${visible_directory_paths[@]}")
  fi
  for directory in "${directory_paths[@]}"; do
    [ "$directory" = "$root_path" ] && continue
    parent="${directory%/*}"
    [ -n "$parent" ] || parent="/"
    directory_child_counts["$parent"]=$((${directory_child_counts[$parent]:-0} + 1))
    last_child_directory["$parent"]="$directory"
  done
  for directory in "${directory_paths[@]}"; do
    if [ "$directory" = "$root_path" ]; then
      directory_is_last["$directory"]="true"
      continue
    fi
    parent="${directory%/*}"
    [ -n "$parent" ] || parent="/"
    if [ "${last_child_directory[$parent]:-}" = "$directory" ]; then
      directory_is_last["$directory"]="true"
    else
      directory_is_last["$directory"]="false"
    fi
  done

  printf '\n' >> "$report_file"
  printf '───────────────────────────────────────────────────────────────────\n' >> "$report_file"
  if [ "$root_path" = "/" ] && [ "$report_title" = "コンテナ内ディレクトリツリー" ]; then
    printf '%s (サービス: %s, コンテナ: %s, 最大深さ: %s)\n' \
        "$report_title" "$service_name" "$container_name" "$tree_depth" >> "$report_file"
  else
    printf '%s (サービス: %s, コンテナ: %s, ルート: %s, 最大深さ: %s)\n' \
        "$report_title" "$service_name" "$container_name" "$root_path" "$tree_depth" >> "$report_file"
  fi
  if [ "$file_limit" = "none" ]; then
    printf '通常ファイル: 表示しない\n' >> "$report_file"
  elif [ "$file_limit" = "all" ]; then
    printf '通常ファイル: 件数にかかわらず全ファイル名を表示\n' >> "$report_file"
  else
    printf '通常ファイル: 直下 %s 件以下は全ファイル名、超過時は拡張子別件数\n' \
        "$file_limit" >> "$report_file"
  fi
  printf '───────────────────────────────────────────────────────────────────\n' >> "$report_file"
  if [ "$directory_find_status" -ne 0 ] || [ "$file_find_status" -ne 0 ]; then
    printf '[WARN] 読み取り不能または実行中に消滅したパスを除く、取得可能な範囲を表示します。\n' >> "$report_file"
  fi

  for directory in "${directory_paths[@]}"; do
    if [ "$directory" = "$root_path" ]; then
      if [ "$root_path" = "/" ]; then
        display_name="/"
      else
        display_name="${root_path##*/}/"
      fi
      printf '%s\n' "$display_name" >> "$report_file"
    else
      display_name="${directory##*/}/"
      parent="${directory%/*}"
      [ -n "$parent" ] || parent="/"
      ancestor_chain=()
      ancestor="$parent"
      while [ "$ancestor" != "$root_path" ]; do
        ancestor_chain=("$ancestor" "${ancestor_chain[@]}")
        ancestor="${ancestor%/*}"
        [ -n "$ancestor" ] || ancestor="/"
      done
      prefix=""
      for ancestor in "${ancestor_chain[@]}"; do
        if [ "${directory_is_last[$ancestor]:-false}" = "true" ]; then
          prefix+="    "
        else
          prefix+="│   "
        fi
      done
      is_last="${directory_is_last[$directory]:-false}"
      if [ "$is_last" = "true" ]; then
        connector="└── "
      else
        connector="├── "
      fi
      printf '%s%s%s\n' "$prefix" "$connector" "$display_name" >> "$report_file"
    fi

    leaf_entries=()
    file_count="${directory_file_counts[$directory]:-0}"
    if [ "$file_count" -gt 0 ] \
        && { [ "$file_limit" = "all" ] || [ "$file_count" -le "$file_limit" ]; }; then
      filename_list="${directory_filename_lists[$directory]}"
      while IFS= read -r filename; do
        leaf_entries+=("[ファイル] ${filename}")
      done < <(printf '%s\n' "$filename_list" | LC_ALL=C sort)
    elif [ "$file_count" -gt 0 ] && [ -n "${directory_extension_lists[$directory]+_}" ]; then
      extension_list="${directory_extension_lists[$directory]}"
      while IFS= read -r extension; do
        [ -n "$extension" ] || continue
        key="${directory}"$'\x1f'"${extension}"
        leaf_entries+=("[ファイル] ${extension}: ${extension_counts[$key]} 件")
      done < <(printf '%s\n' "$extension_list" | LC_ALL=C sort)
    fi

    for index in "${!leaf_entries[@]}"; do
      ancestor_chain=()
      ancestor="$directory"
      while [ "$ancestor" != "$root_path" ]; do
        ancestor_chain=("$ancestor" "${ancestor_chain[@]}")
        ancestor="${ancestor%/*}"
        [ -n "$ancestor" ] || ancestor="/"
      done
      prefix=""
      for ancestor in "${ancestor_chain[@]}"; do
        if [ "${directory_is_last[$ancestor]:-false}" = "true" ]; then
          prefix+="    "
        else
          prefix+="│   "
        fi
      done
      if [ "$index" -eq "$((${#leaf_entries[@]} - 1))" ] \
          && [ "${directory_child_counts[$directory]:-0}" -eq 0 ]; then
        connector="└── "
      else
        connector="├── "
      fi
      printf '%s%s%s\n' "$prefix" "$connector" "${leaf_entries[$index]}" >> "$report_file"
    done
  done

  rm -f -- "$directory_list_tmp" "$file_list_tmp"
}

show_verified_container_directory_trees() {
  [ "$DRY_RUN" = "true" ] && {
    if [ "$DIRECTORY_FILE_LIMIT" = "none" ]; then
      log "[DRY-RUN] 環境変数一覧後のコンテナ内ディレクトリツリー出力をプレビューします (最大深さ: ${DIRECTORY_TREE_DEPTH}, 通常ファイル: 表示しない)。"
    else
      log "[DRY-RUN] 環境変数一覧後のコンテナ内ディレクトリツリー出力をプレビューします (最大深さ: ${DIRECTORY_TREE_DEPTH}, ファイル表示上限: ${DIRECTORY_FILE_LIMIT})。"
    fi
    return 0
  }

  local report_line cid service_name container_name tree_report_tmp
  local -a target_container_ids=()
  mapfile -t target_container_ids < <(verification_target_container_ids)

  if [ ${#target_container_ids[@]} -eq 0 ]; then
    warn "コンテナ内ディレクトリツリーを出力できませんでした。対象コンテナが見つかりません。"
    return 0
  fi

  if ! tree_report_tmp="$(mktemp 2>/dev/null)"; then
    warn "ディレクトリツリー出力用の一時ファイルを作成できませんでした。"
    return 0
  fi
  : > "$tree_report_tmp"

  for cid in "${target_container_ids[@]}"; do
    [ -n "$cid" ] || continue
    service_name="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.service" }}' "$cid" 2>/dev/null || true)"
    [ -n "$service_name" ] || service_name="(unknown)"
    container_name="$(normalize_container_name "$(docker inspect -f '{{.Name}}' "$cid" 2>/dev/null || printf '%s' "$cid")")"
    append_container_directory_tree_report "$cid" "$service_name" "$container_name" "$tree_report_tmp"
  done

  diag ""
  while IFS= read -r report_line; do
    diag "$report_line"
  done < "$tree_report_tmp"

  rm -f -- "$tree_report_tmp"
}

# JBoss EAP のデプロイ先、展開済み Web ルート、Java クラスパスルート
# (WEB-INF/classes)、および指定環境変数のディレクトリを検出して表示する。
append_container_deployment_structure_report() {
  local cid="$1" service_name="$2" container_name="$3" report_file="$4"
  local tree_depth="${5:-$DIRECTORY_TREE_DEPTH}" file_limit="${6:-$DIRECTORY_FILE_LIMIT}"
  local scan_tmp scan_status=0 directory label root_path key entry line env_name value
  local deployment_found="false" web_root_found="false" class_root_found="false"
  local -a root_entries=() notices=()
  local -A seen_roots=() process_env_values=()

  if ! scan_tmp="$(mktemp 2>/dev/null)"; then
    warn "JBoss EAP デプロイ構造の検出用一時ファイルを作成できませんでした (サービス: ${service_name})。"
    return 0
  fi
  docker exec "$cid" find / -type d -print0 > "$scan_tmp" 2>/dev/null || scan_status=$?

  while IFS= read -r -d '' directory; do
    label=""
    root_path="$directory"
    case "$directory" in
      */standalone/deployments)
        label="JBoss EAP デプロイ先"
        deployment_found="true"
        ;;
      */WEB-INF/classes)
        label="Java クラスパスルート"
        class_root_found="true"
        ;;
      */WEB-INF)
        label="Web アプリケーションルート"
        root_path="${directory%/WEB-INF}"
        [ -n "$root_path" ] || root_path="/"
        web_root_found="true"
        ;;
    esac
    [ -n "$label" ] || continue
    key="${label}"$'\x1f'"${root_path}"
    if [ -z "${seen_roots[$key]+_}" ]; then
      seen_roots["$key"]=1
      root_entries+=("$key")
    fi
  done < "$scan_tmp"

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    key="${line%%=*}"
    [ -n "$key" ] || continue
    value=""
    [ "$key" != "$line" ] && value="${line#*=}"
    process_env_values["$key"]="$value"
  done < <(collect_container_pid1_env "$cid")

  for env_name in "${DEPLOYMENT_DIR_ENVS[@]}"; do
    if [ -z "${process_env_values[$env_name]+_}" ] || [ -z "${process_env_values[$env_name]}" ]; then
      notices+=("環境変数 ${env_name} は未設定または空です。")
      continue
    fi
    root_path="${process_env_values[$env_name]}"
    case "$root_path" in
      /*) ;;
      *)
        notices+=("環境変数 ${env_name} の値は絶対パスではありません: ${root_path}")
        continue
        ;;
    esac
    [ "$root_path" = "/" ] || root_path="${root_path%/}"
    label="環境変数 ${env_name}"
    key="${label}"$'\x1f'"${root_path}"
    if [ -z "${seen_roots[$key]+_}" ]; then
      seen_roots["$key"]=1
      root_entries+=("$key")
    fi
  done

  printf '\n' >> "$report_file"
  printf '===================================================================\n' >> "$report_file"
  printf 'JBoss EAP デプロイ済み Web アプリケーションのディレクトリ構造\n' >> "$report_file"
  if [ "$file_limit" = "none" ]; then
    printf '(サービス: %s, コンテナ: %s, 最大深さ: %s, 通常ファイル: 表示しない)\n' \
        "$service_name" "$container_name" "$tree_depth" >> "$report_file"
  else
    printf '(サービス: %s, コンテナ: %s, 最大深さ: %s, ファイル表示上限: %s)\n' \
        "$service_name" "$container_name" "$tree_depth" "$file_limit" >> "$report_file"
  fi
  printf '===================================================================\n' >> "$report_file"
  if [ "$scan_status" -ne 0 ]; then
    printf '[WARN] 読み取り不能なパスを除く、検出可能な範囲を表示します。\n' >> "$report_file"
  fi
  [ "$deployment_found" = "true" ] || notices+=("JBoss EAP の standalone/deployments を検出できませんでした。")
  [ "$web_root_found" = "true" ] || notices+=("展開済み Web アプリケーションルート (WEB-INF の親) を検出できませんでした。")
  [ "$class_root_found" = "true" ] || notices+=("Java クラスパスルート (WEB-INF/classes) を検出できませんでした。")
  for line in "${notices[@]}"; do
    printf '[WARN] %s\n' "$line" >> "$report_file"
  done

  if [ ${#root_entries[@]} -eq 0 ]; then
    printf '表示対象のディレクトリはありません。\n' >> "$report_file"
  else
    for entry in "${root_entries[@]}"; do
      IFS=$'\x1f' read -r label root_path <<< "$entry"
      append_container_directory_tree_report "$cid" "$service_name" "$container_name" \
          "$report_file" "$root_path" "[${label}]" "$tree_depth" "$file_limit"
    done
  fi

  rm -f -- "$scan_tmp"
}

show_verified_container_deployment_structures() {
  [ "$DRY_RUN" = "true" ] && {
    if [ "$DIRECTORY_FILE_LIMIT" = "none" ]; then
      log "[DRY-RUN] コンテナ内ツリー後の JBoss EAP デプロイ構造出力をプレビューします (最大深さ: ${DIRECTORY_TREE_DEPTH}, 通常ファイル: 表示しない)。"
    else
      log "[DRY-RUN] コンテナ内ツリー後の JBoss EAP デプロイ構造出力をプレビューします (最大深さ: ${DIRECTORY_TREE_DEPTH}, ファイル表示上限: ${DIRECTORY_FILE_LIMIT})。"
    fi
    return 0
  }

  local report_line cid service_name container_name deployment_report_tmp
  local -a target_container_ids=()
  mapfile -t target_container_ids < <(verification_target_container_ids)

  if [ ${#target_container_ids[@]} -eq 0 ]; then
    warn "JBoss EAP デプロイ構造を出力できませんでした。対象コンテナが見つかりません。"
    return 0
  fi
  if ! deployment_report_tmp="$(mktemp 2>/dev/null)"; then
    warn "JBoss EAP デプロイ構造出力用の一時ファイルを作成できませんでした。"
    return 0
  fi
  : > "$deployment_report_tmp"

  for cid in "${target_container_ids[@]}"; do
    [ -n "$cid" ] || continue
    service_name="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.service" }}' "$cid" 2>/dev/null || true)"
    [ -n "$service_name" ] || service_name="(unknown)"
    container_name="$(normalize_container_name "$(docker inspect -f '{{.Name}}' "$cid" 2>/dev/null || printf '%s' "$cid")")"
    append_container_deployment_structure_report "$cid" "$service_name" "$container_name" \
        "$deployment_report_tmp"
  done

  diag ""
  while IFS= read -r report_line; do
    diag "$report_line"
  done < "$deployment_report_tmp"
  rm -f -- "$deployment_report_tmp"
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
  # 既存コンテナを再利用した場合に前回起動の WFLYSRV0025 を誤検出しないよう、
  # compose up の直前を今回のログ取得開始時刻として記録する。
  CONTAINER_LOG_SINCE="$(date -u '+%Y-%m-%dT%H:%M:%S.%NZ')"
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
  local down_ok=0
  if [ "$SUPPRESS_REMOVED_LOGS" = "true" ] && [ "$DRY_RUN" != "true" ]; then
    "${COMPOSE_CMD[@]}" -f "$COMPOSE_FILE" down > /dev/null 2>&1 || down_ok=$?
  else
    run "${COMPOSE_CMD[@]}" -f "$COMPOSE_FILE" down || down_ok=$?
  fi
  if [ "$down_ok" -ne 0 ]; then
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
  local deadline now logs normalized_logs svc failure_line
  local -a remaining=()
  now="$(date +%s)"
  deadline=$(( now + STARTUP_TIMEOUT ))
  while :; do
    if [ ${#pending[@]} -gt 0 ]; then
      # サービスごとにログを確認し、起動完了したものを pending から外す。
      remaining=()
      for svc in "${pending[@]}"; do
        logs="$(compose_logs "$svc")"
        normalized_logs="$(printf '%s\n' "$logs" | strip_ansi_codes)"
        if grep -qE "$STARTUP_FAILURE_LOG_PATTERN" <<< "$normalized_logs"; then
          failure_line="$(grep -E "$STARTUP_FAILURE_LOG_PATTERN" <<< "$normalized_logs" | tail -n 1)"
          err "JBoss EAP 8.1 が正常起動しませんでした: サービス '${svc}'"
          err "  ${failure_line}"
          dump_startup_logs_from_snapshot "$normalized_logs" "対象サービス: ${svc}"
          return 1
        elif grep -qE "$STARTUP_LOG_PATTERN" <<< "$normalized_logs"; then
          log "jbosseap サーバーの起動完了を確認しました: サービス '${svc}'"
          show_startup_logs "$normalized_logs" "対象サービス: ${svc}"
        else
          remaining+=("$svc")
        fi
      done
      pending=(${remaining[@]+"${remaining[@]}"})
      if [ ${#pending[@]} -eq 0 ]; then
        show_companion_service_logs
        log "指定した全サービスの起動完了を確認しました。"
        return 0
      fi
    else
      logs="$(compose_logs)"
      normalized_logs="$(printf '%s\n' "$logs" | strip_ansi_codes)"
      if grep -qE "$STARTUP_FAILURE_LOG_PATTERN" <<< "$normalized_logs"; then
        failure_line="$(grep -E "$STARTUP_FAILURE_LOG_PATTERN" <<< "$normalized_logs" | tail -n 1)"
        err "JBoss EAP 8.1 が正常起動しませんでした。"
        err "  ${failure_line}"
        dump_startup_logs_from_snapshot "$normalized_logs" "全対象サービス"
        return 1
      elif grep -qE "$STARTUP_LOG_PATTERN" <<< "$normalized_logs"; then
        log "jbosseap サーバーの起動完了を確認しました。"
        show_startup_logs "$normalized_logs" "全対象サービス"
        show_companion_service_logs
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

# 取得済みスナップショットを使い、失敗時の起動ログと同時起動サービスログを表示する。
# 失敗原因を隠さないよう、--suppress-startup-logs 指定時もログを表示する。
dump_startup_logs_from_snapshot() {
  local logs="$1" target_desc="$2"
  show_startup_logs "$logs" "$target_desc" "false"
  show_companion_service_logs "false"
}

# 失敗時に設定行数分のコンテナ起動ログを出力する (原因調査用)。
# 引数でサービスを指定した場合はそのサービスのログのみ出力する。
dump_startup_logs() {
  local logs target_desc
  logs="$(compose_logs "$@")"
  if [ $# -gt 0 ]; then
    target_desc="対象サービス: $*"
  else
    target_desc="全対象サービス"
  fi
  dump_startup_logs_from_snapshot "$logs" "$target_desc"
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
  printf '\n' >&2
  diag "───────────────────────────────────────────────────────────────────"
}

# 起動維持後の対話操作で使う検証対象コンテナを一つ選択する。
# 検証対象が複数ある場合だけ番号入力を求め、単一の場合は自動選択する。
select_interaction_target() {
  local cid service_name container_name duplicate choice index _existing_cid _target_index
  local -a container_ids=() service_names=() container_names=()

  while IFS= read -r cid; do
    [ -n "$cid" ] || continue
    duplicate="false"
    for _existing_cid in "${container_ids[@]}"; do
      if [ "$cid" = "$_existing_cid" ]; then
        duplicate="true"
        break
      fi
    done
    [ "$duplicate" = "true" ] || container_ids+=("$cid")
  done < <(verification_target_container_ids)

  if [ ${#container_ids[@]} -eq 0 ]; then
    err "対話操作の対象となる実行中コンテナが見つかりません。"
    return 1
  fi

  for cid in "${container_ids[@]}"; do
    service_name="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.service" }}' "$cid" 2>/dev/null || true)"
    [ -n "$service_name" ] || service_name="(unknown)"
    container_name="$(normalize_container_name "$(docker inspect -f '{{.Name}}' "$cid" 2>/dev/null || printf '%s' "$cid")")"
    service_names+=("$service_name")
    container_names+=("$container_name")
  done

  index=0
  if [ ${#container_ids[@]} -gt 1 ]; then
    diag ""
    diag "対話操作を行う検証対象コンテナを選択してください:"
    for _target_index in "${!container_ids[@]}"; do
      diag "  $(( _target_index + 1 ))) service=${service_names[$_target_index]}, container=${container_names[$_target_index]}"
    done
    while :; do
      printf '選択番号 [1-%s]: ' "${#container_ids[@]}" >&2
      if ! IFS= read -r choice; then
        err "コンテナ選択を読み取れませんでした。対話可能な端末から実行してください。"
        return 1
      fi
      case "$choice" in
        ''|*[!0-9]*|0*)
          warn "1 から ${#container_ids[@]} の番号を入力してください。"
          ;;
        *)
          if [ "$choice" -ge 1 ] && [ "$choice" -le ${#container_ids[@]} ]; then
            index=$(( choice - 1 ))
            break
          fi
          warn "1 から ${#container_ids[@]} の番号を入力してください。"
          ;;
      esac
    done
  fi

  INTERACTION_CONTAINER_ID="${container_ids[$index]}"
  INTERACTION_SERVICE_NAME="${service_names[$index]}"
  INTERACTION_CONTAINER_NAME="${container_names[$index]}"
  return 0
}

normalize_context_root() {
  local context_root="$1"
  while [ "${context_root#/}" != "$context_root" ]; do
    context_root="${context_root#/}"
  done
  if [ -n "$context_root" ]; then
    context_root="/${context_root}"
  else
    context_root="/"
  fi
  while [ "$context_root" != "/" ] && [ "${context_root%/}" != "$context_root" ]; do
    context_root="${context_root%/}"
  done
  printf '%s\n' "$context_root"
}

# JBoss EAP の登録済み Web コンテキストを WFLYUT0021 から取得する。
# 明示値を優先し、複数検出時はリクエスト対象を番号で選択する。
select_jboss_context_root() {
  local logs="$1" context_root choice index=0 _context_index
  local -a context_roots=()

  if [ -n "$JBOSS_CONTEXT_ROOT" ]; then
    INTERACTION_CONTEXT_ROOT="$(normalize_context_root "$JBOSS_CONTEXT_ROOT")"
    log "指定された JBoss EAP コンテキストルートを使用します: ${INTERACTION_CONTEXT_ROOT}"
    return 0
  fi

  while IFS= read -r context_root; do
    [ -n "$context_root" ] && context_roots+=("$(normalize_context_root "$context_root")")
  done < <(
    printf '%s\n' "$logs" \
      | strip_ansi_codes \
      | sed -nE "s/.*WFLYUT0021:[[:space:]]*Registered web context:[[:space:]]*'?([^'[:space:]]+)'?.*/\1/p" \
      | awk '!seen[$0]++'
  )

  if [ ${#context_roots[@]} -eq 0 ]; then
    INTERACTION_CONTEXT_ROOT="/"
    warn "WFLYUT0021 ログからコンテキストルートを検出できないため、'/' を使用します。"
  elif [ ${#context_roots[@]} -eq 1 ]; then
    INTERACTION_CONTEXT_ROOT="${context_roots[0]}"
    log "JBoss EAP ログからコンテキストルートを検出しました: ${INTERACTION_CONTEXT_ROOT}"
  else
    diag ""
    diag "HTTP 通信に使用する JBoss EAP コンテキストルートを選択してください:"
    for _context_index in "${!context_roots[@]}"; do
      diag "  $(( _context_index + 1 ))) ${context_roots[$_context_index]}"
    done
    while :; do
      printf '選択番号 [1-%s]: ' "${#context_roots[@]}" >&2
      if ! IFS= read -r choice; then
        err "コンテキストルートの選択を読み取れませんでした。"
        return 1
      fi
      case "$choice" in
        ''|*[!0-9]*|0*)
          warn "1 から ${#context_roots[@]} の番号を入力してください。"
          ;;
        *)
          if [ "$choice" -ge 1 ] && [ "$choice" -le ${#context_roots[@]} ]; then
            index=$(( choice - 1 ))
            INTERACTION_CONTEXT_ROOT="${context_roots[$index]}"
            break
          fi
          warn "1 から ${#context_roots[@]} の番号を入力してください。"
          ;;
      esac
    done
  fi
  return 0
}

# JBoss EAP のコンテナ側 HTTP リスナーポートを WFLYUT0006 から検出する。
discover_jboss_http_port() {
  local logs="$1" detected_port=""
  if [ -n "$JBOSS_HTTP_PORT" ]; then
    INTERACTION_CONTAINER_PORT="$JBOSS_HTTP_PORT"
    log "指定された JBoss EAP HTTP リスナーポートを使用します: ${INTERACTION_CONTAINER_PORT}"
    return 0
  fi

  detected_port="$(
    printf '%s\n' "$logs" \
      | strip_ansi_codes \
      | sed -nE 's/.*WFLYUT0006:.*Undertow HTTP listener .* listening on .*:([0-9]+).*/\1/p' \
      | tail -n 1
  )"
  if [ -n "$detected_port" ]; then
    INTERACTION_CONTAINER_PORT="$detected_port"
    log "JBoss EAP ログから HTTP リスナーポートを検出しました: ${INTERACTION_CONTAINER_PORT}"
  else
    INTERACTION_CONTAINER_PORT="8080"
    warn "WFLYUT0006 ログから HTTP リスナーポートを検出できないため、8080 を使用します。"
  fi
}

# コンテナ側リスナーポートを、ホストから curl できるアドレスへ解決する。
# 公開ポートを優先し、未公開ならコンテナ IP、取得不能なら localhost を使う。
resolve_interaction_http_endpoint() {
  local mapping="" mapped_host="" mapped_port="" container_ip=""
  mapping="$(docker port "$INTERACTION_CONTAINER_ID" "${INTERACTION_CONTAINER_PORT}/tcp" 2>/dev/null | sed -n '1p' || true)"
  if [ -n "$mapping" ]; then
    mapped_port="${mapping##*:}"
    mapped_host="${mapping%:*}"
    mapped_host="${mapped_host#[}"
    mapped_host="${mapped_host%]}"
    case "$mapped_host" in
      ""|0.0.0.0|::) mapped_host="127.0.0.1" ;;
    esac
    if printf '%s' "$mapped_port" | grep -qE '^[0-9]+$'; then
      INTERACTION_HTTP_HOST="$mapped_host"
      INTERACTION_HTTP_PORT="$mapped_port"
      log "Docker 公開ポートを検出しました: ${INTERACTION_CONTAINER_PORT}/tcp -> ${INTERACTION_HTTP_HOST}:${INTERACTION_HTTP_PORT}"
      return 0
    fi
  fi

  container_ip="$(
    docker inspect -f '{{range .NetworkSettings.Networks}}{{println .IPAddress}}{{end}}' \
      "$INTERACTION_CONTAINER_ID" 2>/dev/null | sed -n '/./{p;q;}' || true
  )"
  if [ -n "$container_ip" ]; then
    INTERACTION_HTTP_HOST="$container_ip"
    INTERACTION_HTTP_PORT="$INTERACTION_CONTAINER_PORT"
    warn "HTTP ポートが公開されていないため、コンテナ IP (${INTERACTION_HTTP_HOST}) へ直接接続します。"
  else
    INTERACTION_HTTP_HOST="127.0.0.1"
    INTERACTION_HTTP_PORT="$INTERACTION_CONTAINER_PORT"
    warn "公開ポートとコンテナ IP を取得できないため、localhost:${INTERACTION_HTTP_PORT} を使用します。"
  fi
  return 0
}

join_context_root_and_path() {
  local context_root="$1" request_path="$2"
  if [ -z "$request_path" ]; then
    printf '%s\n' "$context_root"
    return 0
  fi
  if [ "${request_path#\?}" != "$request_path" ]; then
    printf '%s%s\n' "$context_root" "$request_path"
    return 0
  fi
  while [ "${request_path#/}" != "$request_path" ]; do
    request_path="${request_path#/}"
  done
  if [ -z "$request_path" ]; then
    printf '%s\n' "$context_root"
  elif [ "$context_root" = "/" ]; then
    printf '/%s\n' "$request_path"
  else
    printf '%s/%s\n' "$context_root" "$request_path"
  fi
}

prompt_http_request_path() {
  local request_path
  while :; do
    printf 'コンテキストルート以降のパスを入力してください (空入力はルート): ' >&2
    if ! IFS= read -r request_path; then
      err "HTTP パスを読み取れませんでした。"
      return 1
    fi
    case "$request_path" in
      *://*)
        warn "完全な URL ではなく、コンテキストルート以降のパスだけを入力してください。"
        ;;
      *[[:space:]]*)
        warn "パス中の空白はパーセントエンコードして入力してください。"
        ;;
      *)
        HTTP_REQUEST_PATH="$request_path"
        return 0
        ;;
    esac
  done
}

prompt_http_method() {
  local choice
  diag ""
  diag "HTTP メソッドを選択してください:"
  diag "  1) GET"
  diag "  2) POST"
  while :; do
    printf '選択番号 [1-2]: ' >&2
    if ! IFS= read -r choice; then
      err "HTTP メソッドの選択を読み取れませんでした。"
      return 1
    fi
    case "$choice" in
      1|GET|get)
        HTTP_REQUEST_METHOD="GET"
        return 0
        ;;
      2|POST|post)
        HTTP_REQUEST_METHOD="POST"
        return 0
        ;;
      *) warn "1 (GET) または 2 (POST) を選択してください。" ;;
    esac
  done
}

prompt_http_post_body() {
  local choice
  HTTP_REQUEST_BODY=""
  HTTP_REQUEST_CONTENT_TYPE=""
  diag ""
  diag "POST ボディ形式を選択してください:"
  diag "  1) JSON (application/json)"
  diag "  2) form URL encoded (application/x-www-form-urlencoded)"
  while :; do
    printf '選択番号 [1-2]: ' >&2
    if ! IFS= read -r choice; then
      err "POST ボディ形式の選択を読み取れませんでした。"
      return 1
    fi
    case "$choice" in
      1|JSON|json)
        HTTP_REQUEST_CONTENT_TYPE="application/json"
        break
        ;;
      2|FORM|form)
        HTTP_REQUEST_CONTENT_TYPE="application/x-www-form-urlencoded"
        break
        ;;
      *) warn "1 (JSON) または 2 (form URL encoded) を選択してください。" ;;
    esac
  done

  if [ "$HTTP_REQUEST_CONTENT_TYPE" = "application/json" ]; then
    printf 'JSON ボディを 1 行で入力してください: ' >&2
  else
    printf 'form ボディを key=value&key2=value2 形式で入力してください: ' >&2
  fi
  if ! IFS= read -r HTTP_REQUEST_BODY; then
    err "POST ボディを読み取れませんでした。"
    return 1
  fi
  return 0
}

show_interactive_http_response() {
  local request_method="$1" request_url="$2" status_code="$3"
  diag ""
  diag "════════════════════════ HTTP 通信結果 ════════════════════════"
  diag "リクエスト             : [${request_method}] ${request_url}"
  diag "HTTP ステータスコード : ${status_code}"
  diag "────────────────────── レスポンスボディ ──────────────────────"
  if [ -s "$INTERACTIVE_HTTP_BODY_FILE" ]; then
    cat "$INTERACTIVE_HTTP_BODY_FILE" >&2
    printf '\n' >&2
  else
    diag "(空)"
  fi
  diag "═══════════════════════════════════════════════════════════════"
}

run_interactive_http_request() {
  local logs host_for_url request_path request_url status_code curl_status=0
  local -a curl_opts

  if [ "$INTERACTION_SERVICE_NAME" != "(unknown)" ]; then
    logs="$(compose_logs "$INTERACTION_SERVICE_NAME")"
  else
    logs="$(compose_logs)"
  fi
  select_jboss_context_root "$logs" || return 1
  discover_jboss_http_port "$logs" || return 1
  resolve_interaction_http_endpoint || return 1

  host_for_url="$INTERACTION_HTTP_HOST"
  case "$host_for_url" in
    *:*) host_for_url="[${host_for_url}]" ;;
  esac

  diag ""
  diag "対話式 HTTP 通信 (サービス: ${INTERACTION_SERVICE_NAME}, コンテナ: ${INTERACTION_CONTAINER_NAME})"
  diag "  接続先       : http://${host_for_url}:${INTERACTION_HTTP_PORT}"
  diag "  コンテキスト : ${INTERACTION_CONTEXT_ROOT}"
  prompt_http_request_path || return 1
  prompt_http_method || return 1
  if [ "$HTTP_REQUEST_METHOD" = "POST" ]; then
    prompt_http_post_body || return 1
  else
    HTTP_REQUEST_BODY=""
    HTTP_REQUEST_CONTENT_TYPE=""
  fi

  request_path="$(join_context_root_and_path "$INTERACTION_CONTEXT_ROOT" "$HTTP_REQUEST_PATH")"
  request_url="http://${host_for_url}:${INTERACTION_HTTP_PORT}${request_path}"
  if ! INTERACTIVE_HTTP_BODY_FILE="$(mktemp 2>/dev/null)"; then
    err "HTTP レスポンス保存用の一時ファイルを作成できませんでした。"
    return 1
  fi
  : > "$INTERACTIVE_HTTP_BODY_FILE"

  curl_opts=(-sS --noproxy '*' --max-time "$URL_TIMEOUT" --output "$INTERACTIVE_HTTP_BODY_FILE" \
    --write-out '%{http_code}' --request "$HTTP_REQUEST_METHOD")
  if [ "$HTTP_REQUEST_METHOD" = "POST" ]; then
    curl_opts+=(--header "Content-Type: ${HTTP_REQUEST_CONTENT_TYPE}")
    # 入力したボディをプロセス一覧へ露出させないよう、curl の標準入力から渡す。
    curl_opts+=(--data-binary @-)
  fi

  if [ "$HTTP_REQUEST_METHOD" = "POST" ]; then
    status_code="$(printf '%s' "$HTTP_REQUEST_BODY" | curl "${curl_opts[@]}" "$request_url")" || curl_status=$?
  else
    status_code="$(curl "${curl_opts[@]}" "$request_url")" || curl_status=$?
  fi
  [ -n "$status_code" ] || status_code="000"
  show_interactive_http_response "$HTTP_REQUEST_METHOD" "$request_url" "$status_code"
  rm -f -- "$INTERACTIVE_HTTP_BODY_FILE"
  INTERACTIVE_HTTP_BODY_FILE=""

  if [ "$curl_status" -ne 0 ]; then
    err "curl による HTTP 通信に失敗しました (exit=${curl_status}, HTTP=${status_code})。"
    return 1
  fi
  return 0
}

run_keep_container_interaction() {
  [ -n "$KEEP_CONTAINER_MODE" ] || return 0
  if [ "$DRY_RUN" = "true" ]; then
    case "$KEEP_CONTAINER_MODE" in
      bash)
        log "[DRY-RUN] 検証対象コンテナを選択し、docker exec -it <container> /bin/bash で直接接続します。"
        ;;
      http)
        log "[DRY-RUN] JBoss EAP のコンテキストルートと HTTP ポートを解決し、パス・GET/POST・POST ボディ形式の対話入力後に curl を実行します。"
        ;;
    esac
    return 0
  fi

  select_interaction_target || return 1
  case "$KEEP_CONTAINER_MODE" in
    bash)
      diag ""
      diag "検証対象コンテナの bash へ接続します (service=${INTERACTION_SERVICE_NAME}, container=${INTERACTION_CONTAINER_NAME})。"
      diag "bash を終了してもコンテナは起動状態のまま残ります。"
      if ! docker exec -it "$INTERACTION_CONTAINER_ID" /bin/bash; then
        err "検証対象コンテナの /bin/bash へ接続できませんでした: ${INTERACTION_CONTAINER_NAME}"
        return 1
      fi
      log "コンテナの bash セッションを終了しました。コンテナは起動状態を維持します。"
      ;;
    http)
      run_interactive_http_request || return 1
      ;;
  esac
  return 0
}

# Docker CLI の人間可読サイズ (例: 1.5GB / 20MiB) をバイトへ変換する。
human_size_to_bytes() {
  local value="$1" number unit multiplier
  value="${value//[[:space:]]/}"
  if [ "$value" = "0" ]; then
    printf '0\n'
    return 0
  fi
  if [[ "$value" =~ ^([0-9]+([.][0-9]+)?)(B|kB|KB|MB|GB|TB|PB|KiB|MiB|GiB|TiB|PiB)$ ]]; then
    number="${BASH_REMATCH[1]}"
    unit="${BASH_REMATCH[3]}"
  else
    return 1
  fi
  case "$unit" in
    B)   multiplier=1 ;;
    kB|KB) multiplier=1000 ;;
    MB)  multiplier=1000000 ;;
    GB)  multiplier=1000000000 ;;
    TB)  multiplier=1000000000000 ;;
    PB)  multiplier=1000000000000000 ;;
    KiB) multiplier=1024 ;;
    MiB) multiplier=1048576 ;;
    GiB) multiplier=1073741824 ;;
    TiB) multiplier=1099511627776 ;;
    PiB) multiplier=1125899906842624 ;;
    *) return 1 ;;
  esac
  LC_ALL=C awk -v number="$number" -v multiplier="$multiplier" \
    'BEGIN { printf "%.0f\n", number * multiplier }'
}

# docker system df の全カテゴリを合計し、Docker 管理対象の使用量を返す。
docker_storage_bytes() {
  local summary type size bytes total=0 found="false"
  if ! summary="$(LC_ALL=C docker system df --format '{{.Type}}|{{.Size}}' 2>/dev/null)"; then
    return 1
  fi
  while IFS='|' read -r type size; do
    [ -n "$type" ] || continue
    if ! bytes="$(human_size_to_bytes "$size")"; then
      return 1
    fi
    total=$(( total + bytes ))
    found="true"
  done <<< "$summary"
  [ "$found" = "true" ] || return 1
  printf '%s\n' "$total"
}

format_bytes() {
  local bytes="$1"
  LC_ALL=C awk -v bytes="$bytes" '
    BEGIN {
      split("B KiB MiB GiB TiB PiB", units, " ")
      value = bytes + 0
      unit = 1
      while (value >= 1024 && unit < 6) {
        value /= 1024
        unit++
      }
      if (unit == 1) {
        printf "%.0f %s", value, units[unit]
      } else {
        printf "%.2f %s", value, units[unit]
      }
    }'
}

docker_object_count() {
  local output
  if ! output="$("$@" 2>/dev/null)"; then
    printf '取得不可'
    return 1
  fi
  if [ -z "$output" ]; then
    printf '0'
  else
    printf '%s\n' "$output" | awk 'NF { count++ } END { print count + 0 }'
  fi
}

current_docker_endpoint() {
  if [ -n "${DOCKER_CONTEXT:-}" ]; then
    docker context inspect "$DOCKER_CONTEXT" \
      --format '{{.Endpoints.docker.Host}}' 2>/dev/null
  elif [ -n "${DOCKER_HOST:-}" ]; then
    printf '%s\n' "$DOCKER_HOST"
  else
    docker context inspect --format '{{.Endpoints.docker.Host}}' 2>/dev/null
  fi
}

# 確認表示後に別プロセスが既定 context を切り替えても削除先が変わらないよう、
# DOCKER_HOST 未指定時は現在の context 名をこのプロセスへ固定する。
freeze_current_docker_target() {
  [ -n "${DOCKER_CONTEXT:-}" ] && return 0
  [ -n "${DOCKER_HOST:-}" ] && return 0
  local context
  if ! context="$(docker context show 2>/dev/null)" || [ -z "$context" ]; then
    return 1
  fi
  export DOCKER_CONTEXT="$context"
}

docker_endpoint_description() {
  case "$1" in
    unix://*) printf 'ローカル Unix ソケット' ;;
    npipe://*) printf 'ローカル Windows named pipe' ;;
    ssh://*) printf 'リモート SSH 接続' ;;
    tcp://*|http://*|https://*) printf 'TCP 接続 (リモートの可能性あり)' ;;
    '') printf '取得不可' ;;
    *) printf 'その他の接続方式' ;;
  esac
}

show_docker_cleanup_notice() {
  local usage_before="$1" context endpoint
  local running_count container_count image_count volume_count network_count
  context="$(docker context show 2>/dev/null || true)"
  [ -n "$context" ] || context="取得不可"
  endpoint="$(current_docker_endpoint || true)"
  running_count="$(docker_object_count docker container ls -q || true)"
  container_count="$(docker_object_count docker container ls -aq || true)"
  image_count="$(docker_object_count docker image ls -aq || true)"
  volume_count="$(docker_object_count docker volume ls -q || true)"
  network_count="$(docker_object_count docker network ls --filter type=custom -q || true)"

  diag ""
  diag "╔══════════════════════════════════════════════════════════════════╗"
  diag "║ 警告: 現在の Docker context の全ローカルデータを削除します      ║"
  diag "╚══════════════════════════════════════════════════════════════════╝"
  diag "  Docker context: $context"
  diag "  Docker 接続方式: $(docker_endpoint_description "$endpoint")"
  diag "  Docker 管理対象の使用量: $usage_before"
  diag ""
  diag "削除・停止する対象:"
  diag "  1. 実行中の全 Docker コンテナ: $running_count 件"
  diag "     Compose を含め、一時停止中は解除後、通常の docker stop で停止します。"
  diag "  2. 全コンテナ (停止済みを含む): $container_count 件"
  diag "  3. 全ローカルイメージ / タグ: $image_count 件"
  diag "  4. 全ローカルボリュームと、その中の永続データ: $volume_count 件"
  diag "  5. 未使用のユーザー定義ネットワーク: $network_count 件"
  diag "  6. 現在の Docker daemon で削除可能な全ビルドキャッシュ"
  diag ""
  diag "この操作は同じ Docker daemon を使う他プロジェクトにも影響し、元に戻せません。"
  diag "Docker daemon / Docker Desktop、標準ネットワーク、Docker context、"
  diag "レジストリ認証情報、daemon 設定は削除・停止しません。"
}

filesystem_free_bytes() {
  local path="$1" free_kib
  free_kib="$(df -Pk -- "$path" 2>/dev/null | awk 'NR == 2 { print $4; exit }')"
  case "$free_kib" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%s\n' "$(( free_kib * 1024 ))"
}

run_docker_cleanup_step() {
  local description="$1"
  shift
  log "$description ..."
  if "$@"; then
    return 0
  fi
  warn "失敗しました: $description"
  return 1
}

verify_docker_list_empty() {
  local description="$1" remaining count
  shift
  if ! remaining="$("$@" 2>/dev/null)"; then
    warn "クリーンアップ後の確認に失敗しました: $description"
    return 1
  fi
  [ -z "$remaining" ] && return 0
  count="$(printf '%s\n' "$remaining" | awk 'NF { count++ } END { print count + 0 }')"
  warn "クリーンアップ後も $description が $count 件残っています。"
  return 1
}

# 明示指定された場合だけ、現在の Docker context のローカルデータを全削除する。
cleanup_all_docker_data() {
  [ "$CLEANUP_ALL_DOCKER_DATA" = "true" ] || return 0

  local before_bytes="" after_bytes="" before_display="取得不可"
  local docker_endpoint="" docker_root="" host_before="" host_after=""
  local released host_released response paused_output running_output _container_id
  local cleanup_failed=0 measurement_reported="false"
  local -a paused_ids=() running_ids=()

  if ! freeze_current_docker_target; then
    if [ "$DRY_RUN" = "true" ]; then
      warn "Docker context を固定できませんでしたが、DRY-RUN のため削除せずに表示を続けます。"
    else
      err "Docker context を固定できないため、安全のため全体クリーンアップを中止します。"
      return 1
    fi
  fi

  if before_bytes="$(docker_storage_bytes)"; then
    before_display="$(format_bytes "$before_bytes") (docker system df による概算)"
  fi
  show_docker_cleanup_notice "$before_display"

  if [ "$DRY_RUN" = "true" ]; then
    log "[DRY-RUN] 確認入力と Docker データ削除は行いません。実行予定の処理:"
    log "[DRY-RUN] docker container unpause <一時停止中の全コンテナ ID>"
    log "[DRY-RUN] docker container stop <実行中の全コンテナ ID>"
    log "[DRY-RUN] docker container prune --force"
    log "[DRY-RUN] docker builder prune --all --force"
    log "[DRY-RUN] docker image prune --all --force"
    log "[DRY-RUN] docker volume prune --all --force"
    log "[DRY-RUN] docker network prune --force"
    log "[DRY-RUN] docker system prune --all --volumes --force"
    return 0
  fi

  printf "続行するには '%s' と正確に入力してください: " \
    "$DOCKER_CLEANUP_CONFIRM_PHRASE" >&2
  if ! IFS= read -r response; then
    warn "確認入力を読み取れなかったため、追加の Docker 全体クリーンアップは実行しません。"
    return 1
  fi
  if [ "$response" != "$DOCKER_CLEANUP_CONFIRM_PHRASE" ]; then
    warn "確認フレーズが一致しないため、追加の Docker 全体クリーンアップは実行しません。"
    return 1
  fi

  log "確認フレーズを受け付けました。Docker 完全クリーンアップを開始します。"
  docker_endpoint="$(current_docker_endpoint || true)"
  if [[ "$docker_endpoint" = unix://* ]]; then
    docker_root="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || true)"
  fi
  if [ -n "$docker_root" ]; then
    host_before="$(filesystem_free_bytes "$docker_root" || true)"
  fi

  if paused_output="$(docker container ls -q --filter status=paused)"; then
    while IFS= read -r _container_id; do
      [ -n "$_container_id" ] && paused_ids+=("$_container_id")
    done <<< "$paused_output"
    if [ ${#paused_ids[@]} -gt 0 ]; then
      run_docker_cleanup_step \
        "一時停止中のコンテナを安全に停止できる状態へ戻します (${#paused_ids[@]} 件)" \
        docker container unpause "${paused_ids[@]}" || cleanup_failed=1
    fi
  else
    warn "一時停止中コンテナの一覧を取得できませんでした。"
    cleanup_failed=1
  fi

  if running_output="$(docker container ls -q)"; then
    while IFS= read -r _container_id; do
      [ -n "$_container_id" ] && running_ids+=("$_container_id")
    done <<< "$running_output"
    if [ ${#running_ids[@]} -gt 0 ]; then
      run_docker_cleanup_step \
        "Compose を含む全実行中コンテナを通常停止します (${#running_ids[@]} 件)" \
        docker container stop "${running_ids[@]}" || cleanup_failed=1
    else
      log "実行中の Docker コンテナはありません。"
    fi
  else
    warn "実行中コンテナの一覧を取得できませんでした。"
    cleanup_failed=1
  fi

  run_docker_cleanup_step "停止済みを含む全コンテナを削除します" \
    docker container prune --force || cleanup_failed=1
  run_docker_cleanup_step "削除可能な全 Docker ビルドキャッシュを削除します" \
    docker builder prune --all --force || cleanup_failed=1
  run_docker_cleanup_step "全ローカルイメージを削除します" \
    docker image prune --all --force || cleanup_failed=1
  run_docker_cleanup_step "全ローカルボリュームと永続データを削除します" \
    docker volume prune --all --force || cleanup_failed=1
  run_docker_cleanup_step "未使用のユーザー定義ネットワークを削除します" \
    docker network prune --force || cleanup_failed=1
  run_docker_cleanup_step "Docker の未使用データを最終確認・削除します" \
    docker system prune --all --volumes --force || cleanup_failed=1

  verify_docker_list_empty "コンテナ" docker container ls -aq || cleanup_failed=1
  verify_docker_list_empty "ローカルイメージ" docker image ls -aq || cleanup_failed=1
  verify_docker_list_empty "ローカルボリューム" docker volume ls -q || cleanup_failed=1
  verify_docker_list_empty "ユーザー定義ネットワーク" \
    docker network ls --filter type=custom -q || cleanup_failed=1

  if after_bytes="$(docker_storage_bytes)"; then
    if [ -n "$before_bytes" ]; then
      released=$(( before_bytes - after_bytes ))
      if [ "$released" -lt 0 ]; then
        warn "Docker 使用量が処理中に増加したため、削減量を 0 bytes として表示します。"
        released=0
      fi
      log "容量削減結果 (Docker 管理対象・概算): $(format_bytes "$released")"
      log "  削除前: $(format_bytes "$before_bytes")"
      log "  削除後: $(format_bytes "$after_bytes")"
      measurement_reported="true"
    fi
    if [ "$after_bytes" -ne 0 ]; then
      warn "クリーンアップ後も Docker 管理対象データが約 $(format_bytes "$after_bytes") 残っています。"
      cleanup_failed=1
    fi
  fi

  if [ -n "$docker_root" ]; then
    host_after="$(filesystem_free_bytes "$docker_root" || true)"
  fi
  if [ -n "$host_before" ] && [ -n "$host_after" ]; then
    host_released=$(( host_after - host_before ))
    if [ "$host_released" -ge 0 ]; then
      log "ホストファイルシステムの空き容量増加: $(format_bytes "$host_released")"
      measurement_reported="true"
    else
      warn "同時実行中の別処理の影響により、ホストの空き容量は $(format_bytes "$(( -host_released ))") 減少しました。"
    fi
  fi

  if [ "$measurement_reported" != "true" ]; then
    warn "容量削減結果を測定できませんでした。各 prune コマンドの出力を確認してください。"
    cleanup_failed=1
  fi

  if [ "$cleanup_failed" -ne 0 ]; then
    err "Docker 完全クリーンアップは一部未完了です。上記の警告を確認してください。"
    return 1
  fi
  log "Docker 完全クリーンアップが完了しました。"
  return 0
}

# ---- 全量ビルドレポート ------------------------------------------------------
# EXIT トラップからコンテナ停止前に呼び、画面表示の制限にかかわらず環境変数は
# 全件、各ディレクトリは全深度・全ファイル名で保存する。
write_build_report() {
  local exit_status="$1" overall_status build_status report_dir report_base candidate
  local counter=1 report_tmp report_finished_at cid service_name container_name
  local -a target_container_ids=()

  [ -n "$BUILD_REPORT_DIR" ] || return 0
  if [ "$DRY_RUN" = "true" ]; then
    log "[DRY-RUN] 全量ビルドレポートのファイル出力をスキップします: ${BUILD_REPORT_DIR}/build_and_verify_${RUN_TIMESTAMP}.txt"
    return 0
  fi
  if ! mkdir -p -- "$BUILD_REPORT_DIR"; then
    warn "全量ビルドレポートの出力先を作成できませんでした: $BUILD_REPORT_DIR"
    return 1
  fi

  report_dir="${BUILD_REPORT_DIR%/}"
  [ -n "$report_dir" ] || report_dir="/"
  report_base="build_and_verify_${RUN_TIMESTAMP}"
  candidate="${report_dir%/}/${report_base}.txt"
  while [ -e "$candidate" ]; do
    candidate="${report_dir%/}/${report_base}_${counter}.txt"
    counter=$((counter + 1))
  done
  if ! report_tmp="$(mktemp "${report_dir%/}/.${report_base}.tmp.XXXXXX" 2>/dev/null)"; then
    warn "全量ビルドレポート用の一時ファイルを作成できませんでした: $report_dir"
    return 1
  fi

  if [ "$exit_status" -eq 0 ]; then
    overall_status="成功"
  else
    overall_status="失敗 (exit=${exit_status})"
  fi
  build_status="$BUILD_RESULT_STATUS"
  if [ "$exit_status" -ne 0 ] && [ "$build_status" = "実行中" ]; then
    build_status="失敗 (ビルド処理中に中断)"
  fi
  report_finished_at="$(date '+%Y-%m-%d %H:%M:%S')"

  if ! {
    printf '===================================================================\n'
    printf 'build_and_verify.sh 全量ビルドレポート\n'
    printf '===================================================================\n'
    printf '処理開始日時 : %s\n' "$RUN_STARTED_AT"
    printf 'レポート日時 : %s\n' "$report_finished_at"
    printf '全体結果     : %s\n' "$overall_status"
    printf 'Compose 定義 : %s\n' "$COMPOSE_FILE"
    if [ ${#COMPOSE_SERVICES[@]} -gt 0 ]; then
      printf '対象サービス : %s\n' "${COMPOSE_SERVICES[*]}"
    else
      printf '対象サービス : 全サービス\n'
    fi
    printf '\n[1] ビルド結果\n'
    printf '結果          : %s\n' "$build_status"
    printf '詳細          : %s\n' "${BUILD_RESULT_DETAIL:-(なし)}"
    printf 'イメージ      : %s\n' "${BUILD_IMAGE_INFO:-(未確認)}"
    printf '保存ポリシー  : 環境変数は全件、ツリーは全深度・全ファイル名\n'
  } > "$report_tmp"; then
    rm -f -- "$report_tmp"
    warn "全量ビルドレポートのヘッダーを書き込めませんでした: $candidate"
    return 1
  fi

  if [ "$STARTED_CONTAINER" = "true" ]; then
    mapfile -t target_container_ids < <(verification_target_container_ids)
  fi
  if [ ${#target_container_ids[@]} -eq 0 ]; then
    {
      printf '\n[2] 環境変数一覧 (全件)\n'
      printf '対象コンテナが起動していないため取得していません。\n'
      printf '\n[3] コンテナ内ディレクトリツリー (全深度・全ファイル名)\n'
      printf '対象コンテナが起動していないため取得していません。\n'
      printf '\n[4] JBoss EAP デプロイ構造 (全深度・全ファイル名)\n'
      printf '対象コンテナが起動していないため取得していません。\n'
    } >> "$report_tmp"
  else
    load_build_arg_env_name_set
    printf '\n[2] 環境変数一覧 (全件)\n' >> "$report_tmp"
    for cid in "${target_container_ids[@]}"; do
      [ -n "$cid" ] || continue
      service_name="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.service" }}' "$cid" 2>/dev/null || true)"
      [ -n "$service_name" ] || service_name="(unknown)"
      container_name="$(normalize_container_name "$(docker inspect -f '{{.Name}}' "$cid" 2>/dev/null || printf '%s' "$cid")")"
      append_container_env_report "$cid" "$service_name" "$container_name" "$report_tmp" "all"
    done

    printf '\n[3] コンテナ内ディレクトリツリー (全深度・全ファイル名)\n' >> "$report_tmp"
    for cid in "${target_container_ids[@]}"; do
      [ -n "$cid" ] || continue
      service_name="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.service" }}' "$cid" 2>/dev/null || true)"
      [ -n "$service_name" ] || service_name="(unknown)"
      container_name="$(normalize_container_name "$(docker inspect -f '{{.Name}}' "$cid" 2>/dev/null || printf '%s' "$cid")")"
      append_container_directory_tree_report "$cid" "$service_name" "$container_name" \
          "$report_tmp" "/" "コンテナ内ディレクトリツリー" "all" "all"
    done

    printf '\n[4] JBoss EAP デプロイ構造 (全深度・全ファイル名)\n' >> "$report_tmp"
    for cid in "${target_container_ids[@]}"; do
      [ -n "$cid" ] || continue
      service_name="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.service" }}' "$cid" 2>/dev/null || true)"
      [ -n "$service_name" ] || service_name="(unknown)"
      container_name="$(normalize_container_name "$(docker inspect -f '{{.Name}}' "$cid" 2>/dev/null || printf '%s' "$cid")")"
      append_container_deployment_structure_report "$cid" "$service_name" "$container_name" \
          "$report_tmp" "all" "all"
    done
  fi

  if ! mv -- "$report_tmp" "$candidate"; then
    rm -f -- "$report_tmp"
    warn "全量ビルドレポートを確定できませんでした: $candidate"
    return 1
  fi
  BUILD_REPORT_FILE="$candidate"
  log "全量ビルドレポートを出力しました: $BUILD_REPORT_FILE"
  return 0
}

# ---- 後始末 (任意の Docker 完全クリーンアップ → 通常後始末) ----------------
URL_BODY_FILE=""
cleanup_all() {
  local original_status=$? cleanup_status=0
  # この関数内の exit で EXIT トラップが再帰しないよう、先に解除する。
  trap - EXIT

  # コンテナの停止・Docker 全体削除より前に、取得可能な全量情報を保存する。
  if ! write_build_report "$original_status"; then
    cleanup_status=1
  fi

  # 全体クリーンアップを先に実行し、削除前容量へ今回の Compose コンテナも含める。
  # 未承認・失敗時は、その後に従来どおり今回起動したコンテナだけを後始末する。
  if [ "$CLEANUP_ALL_DOCKER_DATA" = "true" ]; then
    if cleanup_all_docker_data; then
      [ "$DRY_RUN" = "true" ] || STARTED_CONTAINER="false"
    else
      cleanup_status=1
    fi
  fi
  teardown_container
  cleanup_copied_files
  [ -n "$URL_BODY_FILE" ] && rm -f "$URL_BODY_FILE"
  [ -n "$INTERACTIVE_HTTP_BODY_FILE" ] && rm -f "$INTERACTIVE_HTTP_BODY_FILE"

  # 本処理が既に失敗している場合は元の終了コードを優先する。
  if [ "$original_status" -ne 0 ]; then
    exit "$original_status"
  fi
  exit "$cleanup_status"
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
# tty の上書き表示でビルドステップの出力が欠落しないよう、BuildKit の進捗形式を
# 明示する。BUILDKIT_PROGRESS が事前定義されている場合は利用者の指定を維持する。
export BUILDKIT_PROGRESS="$BUILD_PROGRESS"
log "BuildKit のビルドログ表示形式: ${BUILD_PROGRESS}"
BUILD_OPTS=()
if [ "$NO_CACHE" = "true" ]; then
  BUILD_OPTS+=(--no-cache)
  log "キャッシュを破棄して (--no-cache) ビルドします。"
fi

# ローカルベースイメージが生成されたか確認する。
# 複数サービス指定時は base の先行ビルド直後に確認し、問題があれば他サービスを
# ビルドする前に中止する。dry-run では実際にビルドしていないため確認をスキップする。
verify_local_image() {
  local image_info image_id image_created image_size
  if [ "$DRY_RUN" = "true" ]; then
    BUILD_IMAGE_INFO="ローカルイメージ確認は DRY-RUN のため未実行: ${LOCAL_IMAGE}"
    log "[DRY-RUN] ローカルベースイメージの存在確認をスキップします: $LOCAL_IMAGE"
  elif ! image_info="$(docker image inspect --format '{{.Id}}|{{.Created}}|{{.Size}}' "$LOCAL_IMAGE" 2>/dev/null)"; then
    BUILD_RESULT_STATUS="失敗"
    BUILD_RESULT_DETAIL="compose build 後にローカルベースイメージを確認できませんでした。"
    err "ローカルベースイメージが見つかりません: $LOCAL_IMAGE (compose.yml の image 指定を確認してください)"
    return 1
  else
    IFS='|' read -r image_id image_created image_size <<< "$image_info"
    BUILD_IMAGE_INFO="image=${LOCAL_IMAGE}, id=${image_id}, created=${image_created}, size=${image_size} bytes"
    log "ビルド結果: image=${LOCAL_IMAGE}, id=${image_id}, created=${image_created}, size=${image_size} bytes"
  fi
  return 0
}

BUILD_RESULT_STATUS="実行中"
BUILD_RESULT_DETAIL="docker compose build を開始しました。"
if [ ${#COMPOSE_SERVICES[@]} -gt 1 ]; then
  # ベースイメージを参照するサービス群と base を同時にビルドすると、base の
  # 完成前に他サービスのビルドが始まる可能性がある。そこで base を第 1 フェーズで
  # 必ず単独ビルドし、成功確認後に残りを 1 回の compose build で並列ビルドする。
  log "複数の compose サービスが指定されました。ベースサービス '${BASE_SERVICE}' を先行ビルドします ..."
  if ! run "${COMPOSE_CMD[@]}" ${COMPOSE_PARALLEL_OPTS[@]+"${COMPOSE_PARALLEL_OPTS[@]}"} -f "$COMPOSE_FILE" build ${COMPOSE_BUILD_PARALLEL_OPTS[@]+"${COMPOSE_BUILD_PARALLEL_OPTS[@]}"} ${BUILD_OPTS[@]+"${BUILD_OPTS[@]}"} "$BASE_SERVICE"; then
    BUILD_RESULT_STATUS="失敗"
    BUILD_RESULT_DETAIL="ベースサービス '${BASE_SERVICE}' の先行ビルドに失敗しました。"
    err "ベースサービス '${BASE_SERVICE}' の先行ビルドに失敗しました"
    exit 1
  fi
  [ "$DRY_RUN" = "true" ] || log "compose build に成功しました (対象サービス: ${BASE_SERVICE})。"
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
      BUILD_RESULT_STATUS="失敗"
      BUILD_RESULT_DETAIL="ベースサービス以外の compose build に失敗しました: ${REMAINING_SERVICES[*]}"
      err "ベースサービス以外の compose build に失敗しました (対象サービス: ${REMAINING_SERVICES[*]})"
      exit 1
    fi
    [ "$DRY_RUN" = "true" ] || log "compose build に成功しました (対象サービス: ${REMAINING_SERVICES[*]})。"
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
    BUILD_RESULT_STATUS="失敗"
    BUILD_RESULT_DETAIL="compose build に失敗しました。"
    err "compose build に失敗しました"
    exit 1
  fi
  if [ "$DRY_RUN" != "true" ]; then
    if [ ${#COMPOSE_SERVICES[@]} -gt 0 ]; then
      log "compose build に成功しました (対象サービス: ${COMPOSE_SERVICES[*]})。"
    else
      log "compose build に成功しました (全サービス)。"
    fi
  fi
  if ! verify_local_image; then
    exit 1
  fi
fi

if [ "$DRY_RUN" = "true" ]; then
  BUILD_RESULT_STATUS="DRY-RUN (未実行)"
  BUILD_RESULT_DETAIL="ビルドコマンドのプレビューが完了しました。"
else
  BUILD_RESULT_STATUS="成功"
  BUILD_RESULT_DETAIL="docker compose build とローカルイメージ確認が完了しました。"
fi

# ---- 起動確認が不要ならここで終了 -------------------------------------------
if [ "$NEED_CONTAINER" != "true" ]; then
  if [ "$ENV_LIST_LIMIT" != "all" ] || [ -n "$ENV_LIST_FILE" ]; then
    warn "環境変数一覧はコンテナ起動を伴う動作確認時のみ出力されます。--verify-startup または --verify-url を併用してください。"
  fi
  if [ "$DIRECTORY_TREE_DEPTH_SET" = "true" ]; then
    warn "コンテナ内ディレクトリツリーはコンテナ起動を伴う動作確認時のみ出力されます。--verify-startup または --verify-url を併用してください。"
  fi
  if [ "$DIRECTORY_FILE_LIMIT_SET" = "true" ] || [ ${#DEPLOYMENT_DIR_ENVS[@]} -gt 0 ]; then
    warn "ファイル表示切替と JBoss EAP デプロイ構造はコンテナ起動を伴う動作確認時のみ画面表示されます。--verify-startup または --verify-url を併用してください。"
  fi
  if [ "$BUILD_REPORT_DIR_SET" = "true" ]; then
    warn "全量レポートの環境変数・ツリー・JBoss EAP デプロイ構造は、コンテナ未起動のため未取得として記録します。"
  fi
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

# ---- 起動維持後の対話操作 ---------------------------------------------------
if ! run_keep_container_interaction; then
  err "起動維持後の対話操作に失敗しました。コンテナは起動状態のまま残します。"
  exit 1
fi

show_verified_container_envs
show_verified_container_directory_trees
show_verified_container_deployment_structures

if [ "$DRY_RUN" = "true" ]; then
  log "DRY-RUN が完了しました (実際の変更は行われていません)。"
else
  log "ビルドおよび確認が完了しました。"
fi
exit 0
