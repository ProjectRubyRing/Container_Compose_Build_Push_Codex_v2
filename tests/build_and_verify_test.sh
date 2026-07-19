#!/usr/bin/env bash

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$TEST_DIR/.." && pwd -P)"
TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/build-and-verify-test.XXXXXX")"

cleanup() {
  case "$TEST_TMP" in
    "${TMPDIR:-/tmp}"/build-and-verify-test.*)
      rm -rf -- "$TEST_TMP"
      ;;
    *)
      printf 'Refusing to remove unexpected test directory: %s\n' "$TEST_TMP" >&2
      ;;
  esac
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  local file="$1" expected="$2"
  grep -Fq -- "$expected" "$file" || fail "expected '$expected' in $file"
}

assert_not_contains() {
  local file="$1" unexpected="$2"
  if grep -Fq -- "$unexpected" "$file"; then
    fail "did not expect '$unexpected' in $file"
  fi
}

assert_occurrences() {
  local file="$1" expected="$2" expected_count="$3" actual_count
  actual_count="$({ grep -Fo -- "$expected" "$file" || true; } | wc -l | tr -d '[:space:]')"
  [ "$actual_count" = "$expected_count" ] \
    || fail "expected '$expected' $expected_count times in $file, found $actual_count"
}

assert_matches() {
  local file="$1" pattern="$2"
  grep -Eq -- "$pattern" "$file" || fail "expected /$pattern/ in $file"
}

assert_before() {
  local file="$1" first="$2" second="$3" first_line second_line
  first_line="$(grep -nF -- "$first" "$file" | head -n 1 | cut -d: -f1 || true)"
  second_line="$(grep -nF -- "$second" "$file" | head -n 1 | cut -d: -f1 || true)"
  [ -n "$first_line" ] || fail "expected '$first' in $file"
  [ -n "$second_line" ] || fail "expected '$second' in $file"
  [ "$first_line" -lt "$second_line" ] || fail "expected '$first' before '$second' in $file"
}

mkdir -p "$TEST_TMP/bin"
cp "$TEST_DIR/helpers/docker" "$TEST_TMP/bin/docker"
cp "$TEST_DIR/helpers/curl" "$TEST_TMP/bin/curl"
chmod 755 "$TEST_TMP/bin/docker" "$TEST_TMP/bin/curl"

export PATH="$TEST_TMP/bin:$PATH"
export FAKE_DOCKER_CALLS="$TEST_TMP/docker.calls"
export FAKE_CURL_CALLS="$TEST_TMP/curl.calls"

success_output="$TEST_TMP/success.out"
: > "$FAKE_DOCKER_CALLS"
export FAKE_COMPOSE_LOG_FILE="$TEST_DIR/fixtures/jboss-eap-8.1-success.log"
if ! (
  cd "$REPO_ROOT"
  unset NO_COLOR
  CLICOLOR_FORCE=1 bash ./build_and_verify.sh \
    --verify-startup \
    --compose-service app \
    --startup-service app \
    --env-list-limit 1 \
    --directory-tree-depth 2 \
    --directory-file-limit 10 \
    --deployment-dir-env APP_CONFIG_DIR \
    --report-dir "$TEST_TMP/reports" \
    --suppress-removed-logs
) >"$success_output" 2>&1; then
  cat "$success_output" >&2
  fail "success fixture returned a non-zero status"
fi

assert_contains "$success_output" "BuildKit のビルドログ表示形式: plain"
assert_contains "$success_output" "[fake-build] BUILDKIT_PROGRESS=plain"
assert_contains "$success_output" "ビルド結果: image=j1/base.local, id=sha256:test-image"
assert_contains "$success_output" "jbosseap サーバーの起動完了を確認しました: サービス 'app'"
assert_contains "$success_output" "コンテナ起動ログ (対象サービス: app, 全 15 行):"
assert_contains "$success_output" "APP000001: Orders application initialized"
assert_contains "$success_output" $'\033[1;36mapp-1  | 09:17:43,001 INFO'
assert_contains "$success_output" $'\033[1;32mapp-1  | 09:17:47,305 INFO'
assert_contains "$success_output" "java:jboss/datasources/Orders#Primary"
assert_contains "$success_output" "java:app/jdbc/ReportingDS"
assert_contains "$success_output" "デプロイ済みアプリケーション:"
assert_contains "$success_output" "orders.war"
assert_contains "$success_output" "登録済み Web コンテキスト:"
assert_contains "$success_output" "/orders"
assert_occurrences "$success_output" "java:/JmsXA" 1
assert_occurrences "$success_output" "old.war" 2
assert_occurrences "$success_output" "/opt/eap/standalone/data/content/ab/cd/content" 1
assert_contains "$success_output" "コンテナ内ディレクトリツリー (サービス: app, コンテナ: test-app-1, 最大深さ: 2)"
assert_contains "$success_output" "通常ファイル: 直下 10 件以下は全ファイル名、超過時は拡張子別件数"
assert_contains "$success_output" "  app/"
assert_contains "$success_output" "    [ファイル] application.jar"
assert_contains "$success_output" "    [ファイル] archive.tar.gz"
assert_contains "$success_output" "    [ファイル] legacy.jar"
assert_contains "$success_output" "    config/"
assert_contains "$success_output" "      [ファイル] application.yaml"
assert_contains "$success_output" "      [ファイル] .env"
assert_contains "$success_output" "  [ファイル] LICENSE"
assert_contains "$success_output" "  empty/"
assert_contains "$success_output" "JBoss EAP デプロイ済み Web アプリケーションのディレクトリ構造"
assert_contains "$success_output" "[JBoss EAP デプロイ先]"
assert_contains "$success_output" "[Web アプリケーションルート]"
assert_contains "$success_output" "[Java クラスパスルート]"
assert_contains "$success_output" "[環境変数 APP_CONFIG_DIR]"
assert_contains "$success_output" "[ファイル] .class: 11 件"
assert_contains "$success_output" "[ファイル] .properties: 1 件"
assert_contains "$success_output" "[ファイル] runtime.properties"
assert_contains "$success_output" "API_TOKEN=[REDACTED]"
assert_not_contains "$success_output" "do-not-log-this-value"
assert_not_contains "$success_output" "Order01.class"
assert_not_contains "$success_output" "deep.json"
assert_before "$success_output" "環境変数一覧 (サービス: app" "コンテナ内ディレクトリツリー (サービス: app"
assert_before "$success_output" "コンテナ内ディレクトリツリー (サービス: app" "JBoss EAP デプロイ済み Web アプリケーションのディレクトリ構造"
assert_matches "$FAKE_DOCKER_CALLS" 'compose -f compose\.yml logs --no-color --since [^ ]+ app'
assert_contains "$FAKE_DOCKER_CALLS" "exec cid-app find / -type d -print0"
assert_contains "$FAKE_DOCKER_CALLS" "exec cid-app find / -type f -print0"
assert_contains "$FAKE_DOCKER_CALLS" "exec cid-app find / -maxdepth 3 -type f -print0"

report_files=("$TEST_TMP/reports"/build_and_verify_*.txt)
[ ${#report_files[@]} -eq 1 ] && [ -f "${report_files[0]}" ] \
  || fail "expected one timestamped full build report"
full_report="${report_files[0]}"
[[ "$(basename "$full_report")" =~ ^build_and_verify_[0-9]{14}(_[0-9]+)?\.txt$ ]] \
  || fail "unexpected full build report filename: $full_report"
assert_matches "$full_report" 'build_and_verify\.sh 全量ビルドレポート'
assert_contains "$full_report" "全体結果     : 成功"
assert_contains "$full_report" "[1] ビルド結果"
assert_contains "$full_report" "[2] 環境変数一覧 (全件)"
assert_contains "$full_report" "[3] コンテナ内ディレクトリツリー (全深度・全ファイル名)"
assert_contains "$full_report" "[4] JBoss EAP デプロイ構造 (全深度・全ファイル名)"
assert_contains "$full_report" "API_TOKEN=[REDACTED]"
assert_not_contains "$full_report" "do-not-log-this-value"
assert_contains "$full_report" "application.yaml"
assert_contains "$full_report" "deep.json"
assert_contains "$full_report" "Order01.class"
assert_contains "$full_report" "Order11.class"

startup_log_limit_output="$TEST_TMP/startup-log-limit.out"
: > "$FAKE_DOCKER_CALLS"
if ! (
  cd "$REPO_ROOT"
  CLICOLOR_FORCE=0 bash ./build_and_verify.sh \
    --verify-startup \
    --compose-service app \
    --startup-service app \
    --startup-log-lines 2 \
    --env-list-limit 1 \
    --suppress-removed-logs
) >"$startup_log_limit_output" 2>&1; then
  cat "$startup_log_limit_output" >&2
  fail "startup log line limit scenario returned a non-zero status"
fi

assert_contains "$startup_log_limit_output" "コンテナ起動ログ (対象サービス: app, 末尾 2/15 行 (指定上限: 2)):"
assert_contains "$startup_log_limit_output" "WFLYSRV0010"
assert_contains "$startup_log_limit_output" "WFLYSRV0025"
assert_not_contains "$startup_log_limit_output" "WFLYSRV0049"
assert_not_contains "$startup_log_limit_output" "APP000001"
assert_not_contains "$startup_log_limit_output" $'\033['

tree_depth_output="$TEST_TMP/tree-depth.out"
: > "$FAKE_DOCKER_CALLS"
if ! (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --verify-startup \
    --compose-service app \
    --startup-service app \
    --env-list-limit 1 \
    --directory-tree-depth 1 \
    --suppress-removed-logs
) >"$tree_depth_output" 2>&1; then
  cat "$tree_depth_output" >&2
  fail "directory tree depth scenario returned a non-zero status"
fi

assert_contains "$tree_depth_output" "コンテナ内ディレクトリツリー (サービス: app, コンテナ: test-app-1, 最大深さ: 1)"
assert_contains "$tree_depth_output" "通常ファイル: 表示しない"
assert_contains "$tree_depth_output" "  app/"
assert_contains "$tree_depth_output" "  empty/"
assert_not_contains "$tree_depth_output" "    config/"
assert_not_contains "$tree_depth_output" "[ファイル]"
assert_contains "$FAKE_DOCKER_CALLS" "exec cid-app find / -maxdepth 1 -type d -print0"
assert_not_contains "$FAKE_DOCKER_CALLS" "-type f -print0"

invalid_startup_log_lines_output="$TEST_TMP/startup-log-lines-invalid.out"
if (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh --dry-run --startup-log-lines 0
) >"$invalid_startup_log_lines_output" 2>&1; then
  cat "$invalid_startup_log_lines_output" >&2
  fail "invalid startup log line limit unexpectedly returned zero"
fi
assert_contains "$invalid_startup_log_lines_output" "--startup-log-lines には 1 以上の整数を指定してください: 0"

invalid_tree_depth_output="$TEST_TMP/tree-depth-invalid.out"
if (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh --dry-run --directory-tree-depth 0
) >"$invalid_tree_depth_output" 2>&1; then
  cat "$invalid_tree_depth_output" >&2
  fail "invalid directory tree depth unexpectedly returned zero"
fi
assert_contains "$invalid_tree_depth_output" "--directory-tree-depth には 1 以上の整数を指定してください: 0"

invalid_file_limit_output="$TEST_TMP/file-limit-invalid.out"
if (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh --dry-run --directory-file-limit 0
) >"$invalid_file_limit_output" 2>&1; then
  cat "$invalid_file_limit_output" >&2
  fail "invalid directory file limit unexpectedly returned zero"
fi
assert_contains "$invalid_file_limit_output" "--directory-file-limit には 1 以上の整数を指定してください: 0"

invalid_deployment_env_output="$TEST_TMP/deployment-env-invalid.out"
if (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh --dry-run --deployment-dir-env 'INVALID-NAME'
) >"$invalid_deployment_env_output" 2>&1; then
  cat "$invalid_deployment_env_output" >&2
  fail "invalid deployment directory environment name unexpectedly returned zero"
fi
assert_contains "$invalid_deployment_env_output" "--deployment-dir-env に不正な環境変数名が指定されました: INVALID-NAME"

tree_find_failure_output="$TEST_TMP/tree-find-failure.out"
: > "$FAKE_DOCKER_CALLS"
export FAKE_DOCKER_FIND_FAIL="true"
if ! (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --verify-startup \
    --compose-service app \
    --startup-service app \
    --env-list-limit 1 \
    --suppress-removed-logs
) >"$tree_find_failure_output" 2>&1; then
  cat "$tree_find_failure_output" >&2
  fail "missing container find command unexpectedly failed verification"
fi
unset FAKE_DOCKER_FIND_FAIL

assert_contains "$tree_find_failure_output" "コンテナ内ディレクトリツリーを取得できませんでした (サービス: app, コンテナ: test-app-1, ルート: /)"
assert_contains "$tree_find_failure_output" "ビルドおよび確認が完了しました。"

failure_output="$TEST_TMP/failure.out"
: > "$FAKE_DOCKER_CALLS"
export FAKE_COMPOSE_LOG_FILE="$TEST_DIR/fixtures/jboss-eap-8.1-failure.log"
if (
  cd "$REPO_ROOT"
  unset NO_COLOR
  CLICOLOR_FORCE=1 bash ./build_and_verify.sh \
    --verify-startup \
    --compose-service app \
    --startup-service app \
    --env-list-limit 1 \
    --report-dir "$TEST_TMP/failure-reports" \
    --suppress-removed-logs
) >"$failure_output" 2>&1; then
  cat "$failure_output" >&2
  fail "failure fixture unexpectedly returned zero"
fi

assert_contains "$failure_output" "JBoss EAP 8.1 が正常起動しませんでした"
assert_contains "$failure_output" "コンテナ起動ログ (対象サービス: app, 全 5 行):"
assert_contains "$failure_output" $'\033[1;31mapp-1  | 09:18:00,100 ERROR'
assert_contains "$failure_output" "WFLYSRV0026"
assert_contains "$failure_output" "[デプロイエラー関連]"
assert_contains "$failure_output" "WFLYSRV0021"
assert_contains "$failure_output" "JNDI データソースエラー:"
assert_contains "$failure_output" "WFLYJCA0031"
assert_not_contains "$failure_output" "起動完了を確認しました"
failure_report_files=("$TEST_TMP/failure-reports"/build_and_verify_*.txt)
[ ${#failure_report_files[@]} -eq 1 ] && [ -f "${failure_report_files[0]}" ] \
  || fail "expected one report for failed verification"
assert_contains "${failure_report_files[0]}" "全体結果     : 失敗 (exit=1)"
assert_contains "${failure_report_files[0]}" "結果          : 成功"

build_failure_output="$TEST_TMP/build-failure.out"
export FAKE_DOCKER_BUILD_FAIL="true"
if (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh --report-dir "$TEST_TMP/build-failure-reports"
) >"$build_failure_output" 2>&1; then
  cat "$build_failure_output" >&2
  fail "failed compose build unexpectedly returned zero"
fi
unset FAKE_DOCKER_BUILD_FAIL
assert_contains "$build_failure_output" "compose build に失敗しました"
build_failure_reports=("$TEST_TMP/build-failure-reports"/build_and_verify_*.txt)
[ ${#build_failure_reports[@]} -eq 1 ] && [ -f "${build_failure_reports[0]}" ] \
  || fail "expected one report for failed compose build"
assert_contains "${build_failure_reports[0]}" "全体結果     : 失敗 (exit=1)"
assert_contains "${build_failure_reports[0]}" "結果          : 失敗"
assert_contains "${build_failure_reports[0]}" "対象コンテナが起動していないため取得していません。"

invalid_keep_mode_output="$TEST_TMP/keep-mode-invalid.out"
if (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh --dry-run --keep-container-mode invalid
) >"$invalid_keep_mode_output" 2>&1; then
  cat "$invalid_keep_mode_output" >&2
  fail "invalid keep-container mode unexpectedly returned zero"
fi
assert_contains "$invalid_keep_mode_output" "--keep-container-mode には bash または http を指定してください: invalid"

invalid_http_port_output="$TEST_TMP/keep-mode-http-invalid-port.out"
if (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --dry-run \
    --keep-container-mode http \
    --jboss-http-port 65536
) >"$invalid_http_port_output" 2>&1; then
  cat "$invalid_http_port_output" >&2
  fail "invalid JBoss HTTP port unexpectedly returned zero"
fi
assert_contains "$invalid_http_port_output" "--jboss-http-port には 1 から 65535 の範囲を指定してください: 65536"

bash_mode_output="$TEST_TMP/keep-mode-bash.out"
: > "$FAKE_DOCKER_CALLS"
export FAKE_COMPOSE_LOG_FILE="$TEST_DIR/fixtures/jboss-eap-8.1-success.log"
if ! (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --compose-service app \
    --keep-container-mode bash \
    --env-list-limit 1 \
    --suppress-removed-logs
) >"$bash_mode_output" 2>&1; then
  cat "$bash_mode_output" >&2
  fail "bash keep-container mode returned a non-zero status"
fi

assert_contains "$bash_mode_output" "検証対象コンテナの bash へ接続します"
assert_contains "$bash_mode_output" "bash セッションを終了しました。コンテナは起動状態を維持します"
assert_contains "$bash_mode_output" "コンテナを残します (--keep-container)"
assert_contains "$FAKE_DOCKER_CALLS" "exec -it cid-app /bin/bash"
assert_not_contains "$FAKE_DOCKER_CALLS" "compose -f compose.yml down"

http_get_output="$TEST_TMP/keep-mode-http-get.out"
: > "$FAKE_DOCKER_CALLS"
: > "$FAKE_CURL_CALLS"
export FAKE_CURL_STATUS="201"
export FAKE_CURL_BODY='{"message":"ready"}'
if ! printf '/status\n1\n' | (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --compose-service app \
    --startup-service app \
    --keep-container-mode http \
    --env-list-limit 1 \
    --suppress-removed-logs
) >"$http_get_output" 2>&1; then
  cat "$http_get_output" >&2
  fail "interactive HTTP GET mode returned a non-zero status"
fi

assert_contains "$http_get_output" "JBoss EAP ログからコンテキストルートを検出しました: /orders"
assert_contains "$http_get_output" "JBoss EAP ログから HTTP リスナーポートを検出しました: 8080"
assert_contains "$http_get_output" "Docker 公開ポートを検出しました: 8080/tcp -> 127.0.0.1:18080"
assert_contains "$http_get_output" "HTTP ステータスコード : 201"
assert_contains "$http_get_output" '{"message":"ready"}'
assert_contains "$FAKE_DOCKER_CALLS" "port cid-app 8080/tcp"
assert_contains "$FAKE_CURL_CALLS" "--request GET http://127.0.0.1:18080/orders/status"
assert_not_contains "$FAKE_CURL_CALLS" "--data-binary"
assert_not_contains "$FAKE_DOCKER_CALLS" "compose -f compose.yml down"

http_json_output="$TEST_TMP/keep-mode-http-json.out"
: > "$FAKE_DOCKER_CALLS"
: > "$FAKE_CURL_CALLS"
export FAKE_CURL_STATUS="202"
export FAKE_CURL_BODY='{"accepted":true}'
if ! printf 'submit\n2\n1\n{"target":"orders"}\n' | (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --compose-service app \
    --startup-service app \
    --keep-container-mode http \
    --env-list-limit 1 \
    --suppress-removed-logs
) >"$http_json_output" 2>&1; then
  cat "$http_json_output" >&2
  fail "interactive HTTP JSON POST mode returned a non-zero status"
fi

assert_contains "$http_json_output" "HTTP ステータスコード : 202"
assert_contains "$http_json_output" '{"accepted":true}'
assert_contains "$FAKE_CURL_CALLS" "--request POST"
assert_contains "$FAKE_CURL_CALLS" "--header Content-Type: application/json"
assert_contains "$FAKE_CURL_CALLS" "--data-binary @-"
assert_contains "$FAKE_CURL_CALLS" 'request-body={"target":"orders"}'
assert_contains "$FAKE_CURL_CALLS" "http://127.0.0.1:18080/orders/submit"

http_form_output="$TEST_TMP/keep-mode-http-form.out"
: > "$FAKE_DOCKER_CALLS"
: > "$FAKE_CURL_CALLS"
export FAKE_CURL_STATUS="200"
export FAKE_CURL_BODY='token-issued'
if ! printf '/token\n2\n2\ngrant_type=client_credentials&scope=read\n' | (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --compose-service app \
    --startup-service app \
    --keep-container-mode http \
    --jboss-context-root /custom/ \
    --jboss-http-port 8080 \
    --env-list-limit 1 \
    --suppress-removed-logs
) >"$http_form_output" 2>&1; then
  cat "$http_form_output" >&2
  fail "interactive HTTP form POST mode returned a non-zero status"
fi

assert_contains "$http_form_output" "指定された JBoss EAP コンテキストルートを使用します: /custom"
assert_contains "$http_form_output" "指定された JBoss EAP HTTP リスナーポートを使用します: 8080"
assert_contains "$http_form_output" "HTTP ステータスコード : 200"
assert_contains "$http_form_output" "token-issued"
assert_contains "$FAKE_CURL_CALLS" "--header Content-Type: application/x-www-form-urlencoded"
assert_contains "$FAKE_CURL_CALLS" "--data-binary @-"
assert_contains "$FAKE_CURL_CALLS" "request-body=grant_type=client_credentials&scope=read"
assert_contains "$FAKE_CURL_CALLS" "http://127.0.0.1:18080/custom/token"

http_failure_output="$TEST_TMP/keep-mode-http-curl-failure.out"
: > "$FAKE_DOCKER_CALLS"
: > "$FAKE_CURL_CALLS"
export FAKE_CURL_STATUS="000"
export FAKE_CURL_BODY='connection failed'
export FAKE_CURL_EXIT_STATUS="7"
if printf '/status\n1\n' | (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --compose-service app \
    --startup-service app \
    --keep-container-mode http \
    --env-list-limit 1 \
    --suppress-removed-logs
) >"$http_failure_output" 2>&1; then
  cat "$http_failure_output" >&2
  fail "curl transport failure unexpectedly returned zero"
fi

assert_contains "$http_failure_output" "HTTP ステータスコード : 000"
assert_contains "$http_failure_output" "connection failed"
assert_contains "$http_failure_output" "curl による HTTP 通信に失敗しました (exit=7, HTTP=000)"
assert_contains "$http_failure_output" "コンテナを残します (--keep-container)"
assert_not_contains "$FAKE_DOCKER_CALLS" "compose -f compose.yml down"

unset FAKE_CURL_STATUS FAKE_CURL_BODY FAKE_CURL_EXIT_STATUS

export FAKE_DOCKER_CLEANED="$TEST_TMP/docker.cleaned"

dry_run_cleanup_output="$TEST_TMP/cleanup-dry-run.out"
rm -f -- "$FAKE_DOCKER_CLEANED"
: > "$FAKE_DOCKER_CALLS"
if ! (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh --dry-run --cleanup-all-docker-data
) >"$dry_run_cleanup_output" 2>&1; then
  cat "$dry_run_cleanup_output" >&2
  fail "cleanup dry-run returned a non-zero status"
fi

assert_contains "$dry_run_cleanup_output" "現在の Docker context の全ローカルデータを削除します"
assert_contains "$dry_run_cleanup_output" "[DRY-RUN] 確認入力と Docker データ削除は行いません"
assert_contains "$dry_run_cleanup_output" "docker volume prune --all --force"
assert_not_contains "$FAKE_DOCKER_CALLS" "container prune --force"

conflicting_cleanup_output="$TEST_TMP/cleanup-conflicting-options.out"
if (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --dry-run \
    --cleanup-all-docker-data \
    --keep-container
) >"$conflicting_cleanup_output" 2>&1; then
  cat "$conflicting_cleanup_output" >&2
  fail "conflicting cleanup options unexpectedly returned zero"
fi
assert_contains "$conflicting_cleanup_output" "--cleanup-all-docker-data と --keep-container は同時に指定できません"

declined_cleanup_output="$TEST_TMP/cleanup-declined.out"
rm -f -- "$FAKE_DOCKER_CLEANED"
: > "$FAKE_DOCKER_CALLS"
export FAKE_COMPOSE_LOG_FILE="$TEST_DIR/fixtures/jboss-eap-8.1-success.log"
if printf 'cancel\n' | (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --verify-startup \
    --compose-service app \
    --startup-service app \
    --env-list-limit 1 \
    --suppress-removed-logs \
    --cleanup-all-docker-data
) >"$declined_cleanup_output" 2>&1; then
  cat "$declined_cleanup_output" >&2
  fail "declined cleanup unexpectedly returned zero"
fi

assert_contains "$declined_cleanup_output" "続行するには 'DELETE ALL DOCKER DATA' と正確に入力してください"
assert_contains "$declined_cleanup_output" "確認フレーズが一致しないため、追加の Docker 全体クリーンアップは実行しません"
assert_not_contains "$FAKE_DOCKER_CALLS" "container prune --force"
assert_contains "$FAKE_DOCKER_CALLS" "compose -f compose.yml down"

failed_build_cleanup_output="$TEST_TMP/cleanup-after-failed-build.out"
rm -f -- "$FAKE_DOCKER_CLEANED"
: > "$FAKE_DOCKER_CALLS"
export FAKE_COMPOSE_LOG_FILE="$TEST_DIR/fixtures/jboss-eap-8.1-failure.log"
if printf 'DELETE ALL DOCKER DATA\n' | (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --verify-startup \
    --compose-service app \
    --startup-service app \
    --env-list-limit 1 \
    --suppress-removed-logs \
    --cleanup-all-docker-data
) >"$failed_build_cleanup_output" 2>&1; then
  cat "$failed_build_cleanup_output" >&2
  fail "failed build with confirmed cleanup unexpectedly returned zero"
fi

assert_contains "$failed_build_cleanup_output" "JBoss EAP 8.1 が正常起動しませんでした"
assert_contains "$failed_build_cleanup_output" "確認フレーズを受け付けました"
assert_contains "$failed_build_cleanup_output" "Docker 完全クリーンアップが完了しました"
assert_contains "$FAKE_DOCKER_CALLS" "system prune --all --volumes --force"

confirmed_cleanup_output="$TEST_TMP/cleanup-confirmed.out"
rm -f -- "$FAKE_DOCKER_CLEANED"
: > "$FAKE_DOCKER_CALLS"
export FAKE_COMPOSE_LOG_FILE="$TEST_DIR/fixtures/jboss-eap-8.1-success.log"
if ! printf 'DELETE ALL DOCKER DATA\n' | (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --verify-startup \
    --compose-service app \
    --startup-service app \
    --env-list-limit 1 \
    --suppress-removed-logs \
    --cleanup-all-docker-data
) >"$confirmed_cleanup_output" 2>&1; then
  cat "$confirmed_cleanup_output" >&2
  fail "confirmed cleanup returned a non-zero status"
fi

assert_contains "$confirmed_cleanup_output" "確認フレーズを受け付けました"
assert_contains "$confirmed_cleanup_output" "容量削減結果 (Docker 管理対象・概算): 2.79 GiB"
assert_contains "$confirmed_cleanup_output" "Docker 完全クリーンアップが完了しました"
assert_contains "$FAKE_DOCKER_CALLS" "container unpause cid-paused"
assert_contains "$FAKE_DOCKER_CALLS" "container stop cid-running cid-paused"
assert_contains "$FAKE_DOCKER_CALLS" "container prune --force"
assert_contains "$FAKE_DOCKER_CALLS" "builder prune --all --force"
assert_contains "$FAKE_DOCKER_CALLS" "image prune --all --force"
assert_contains "$FAKE_DOCKER_CALLS" "volume prune --all --force"
assert_contains "$FAKE_DOCKER_CALLS" "network prune --force"
assert_contains "$FAKE_DOCKER_CALLS" "system prune --all --volumes --force"
assert_not_contains "$FAKE_DOCKER_CALLS" "compose -f compose.yml down"

printf 'PASS: build_and_verify.sh EAP 8.1 startup log display/color, interaction, deployment tree, full report, and Docker cleanup scenarios\n'
