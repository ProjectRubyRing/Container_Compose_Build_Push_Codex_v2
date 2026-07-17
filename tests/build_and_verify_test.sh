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
chmod 755 "$TEST_TMP/bin/docker"

export PATH="$TEST_TMP/bin:$PATH"
export FAKE_DOCKER_CALLS="$TEST_TMP/docker.calls"

success_output="$TEST_TMP/success.out"
: > "$FAKE_DOCKER_CALLS"
export FAKE_COMPOSE_LOG_FILE="$TEST_DIR/fixtures/jboss-eap-8.1-success.log"
if ! (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --verify-startup \
    --compose-service app \
    --startup-service app \
    --env-list-limit 1 \
    --suppress-removed-logs
) >"$success_output" 2>&1; then
  cat "$success_output" >&2
  fail "success fixture returned a non-zero status"
fi

assert_contains "$success_output" "BuildKit のビルドログ表示形式: plain"
assert_contains "$success_output" "[fake-build] BUILDKIT_PROGRESS=plain"
assert_contains "$success_output" "ビルド結果: image=j1/base.local, id=sha256:test-image"
assert_contains "$success_output" "jbosseap サーバーの起動完了を確認しました: サービス 'app'"
assert_contains "$success_output" "java:jboss/datasources/Orders#Primary"
assert_contains "$success_output" "java:app/jdbc/ReportingDS"
assert_contains "$success_output" "デプロイ済みアプリケーション:"
assert_contains "$success_output" "orders.war"
assert_contains "$success_output" "登録済み Web コンテキスト:"
assert_contains "$success_output" "/orders"
assert_not_contains "$success_output" "java:/JmsXA"
assert_not_contains "$success_output" "old.war"
assert_not_contains "$success_output" "/opt/eap/standalone/data/content/ab/cd/content"
assert_contains "$success_output" "コンテナ内ディレクトリツリー (サービス: app, コンテナ: test-app-1, 最大深さ: all)"
assert_contains "$success_output" "  app/"
assert_contains "$success_output" "    [ファイル] .gz: 1 件"
assert_contains "$success_output" "    [ファイル] .jar: 2 件"
assert_contains "$success_output" "    config/"
assert_contains "$success_output" "      [ファイル] .yaml: 2 件"
assert_contains "$success_output" "[ファイル] (拡張子なし): 1 件"
assert_contains "$success_output" "  empty/"
assert_not_contains "$success_output" "application.jar"
assert_not_contains "$success_output" "application.yaml"
assert_not_contains "$success_output" "archive.tar.gz"
assert_before "$success_output" "環境変数一覧 (サービス: app" "コンテナ内ディレクトリツリー (サービス: app"
assert_matches "$FAKE_DOCKER_CALLS" 'compose -f compose\.yml logs --no-color --since [^ ]+ app'
assert_contains "$FAKE_DOCKER_CALLS" "exec cid-app find / -type d -print0"
assert_contains "$FAKE_DOCKER_CALLS" "exec cid-app find / -type f -print0"

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
assert_contains "$tree_depth_output" "  app/"
assert_contains "$tree_depth_output" "    [ファイル] .jar: 2 件"
assert_contains "$tree_depth_output" "  empty/"
assert_not_contains "$tree_depth_output" "    config/"
assert_not_contains "$tree_depth_output" "[ファイル] .yaml:"
assert_contains "$FAKE_DOCKER_CALLS" "exec cid-app find / -maxdepth 1 -type d -print0"
assert_contains "$FAKE_DOCKER_CALLS" "exec cid-app find / -maxdepth 2 -type f -print0"

invalid_tree_depth_output="$TEST_TMP/tree-depth-invalid.out"
if (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh --dry-run --directory-tree-depth 0
) >"$invalid_tree_depth_output" 2>&1; then
  cat "$invalid_tree_depth_output" >&2
  fail "invalid directory tree depth unexpectedly returned zero"
fi
assert_contains "$invalid_tree_depth_output" "--directory-tree-depth には 1 以上の整数を指定してください: 0"

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

assert_contains "$tree_find_failure_output" "コンテナ内ディレクトリツリーを取得できませんでした (サービス: app, コンテナ: test-app-1)"
assert_contains "$tree_find_failure_output" "ビルドおよび確認が完了しました。"

failure_output="$TEST_TMP/failure.out"
: > "$FAKE_DOCKER_CALLS"
export FAKE_COMPOSE_LOG_FILE="$TEST_DIR/fixtures/jboss-eap-8.1-failure.log"
if (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --verify-startup \
    --compose-service app \
    --startup-service app \
    --env-list-limit 1 \
    --suppress-removed-logs
) >"$failure_output" 2>&1; then
  cat "$failure_output" >&2
  fail "failure fixture unexpectedly returned zero"
fi

assert_contains "$failure_output" "JBoss EAP 8.1 が正常起動しませんでした"
assert_contains "$failure_output" "WFLYSRV0026"
assert_contains "$failure_output" "[デプロイエラー関連]"
assert_contains "$failure_output" "WFLYSRV0021"
assert_contains "$failure_output" "JNDI データソースエラー:"
assert_contains "$failure_output" "WFLYJCA0031"
assert_not_contains "$failure_output" "起動完了を確認しました"

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

printf 'PASS: build_and_verify.sh EAP 8.1 log, directory tree, and Docker cleanup scenarios\n'
