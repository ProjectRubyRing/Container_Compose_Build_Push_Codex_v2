# Container Compose Build & Push

ローカルベースイメージをビルドし、ECR へタグ付けしてプッシュ、
`imagedefinition.json` を出力するためのスクリプトです。ビルド方法の異なる
2 つのスクリプトを提供します (ビルド以降の処理・オプションは共通)。

| スクリプト | ビルド方法 |
| --- | --- |
| `build_and_push.sh` | `compose.yml` を使った `docker compose build` |
| `buildx_build_and_push.sh` | `docker buildx build` (compose 不使用)。ECR ログイン (`aws ecr get-login-password \| docker login`)、`docker image tag`、`docker image push` を個別コマンドで実行 |

さらに、**ビルドのみを行う** (ECR へはプッシュしない) 専用スクリプトとして
`build_and_verify.sh` を提供します。ビルドに加えて、コンテナを起動して
**jbosseap (WildFly/JBoss EAP) サーバーの起動確認**や、**指定 URL への HTTP 応答確認**、
**同時に起動した Compose サービスのログ表示**、**コンテナ内ディレクトリツリーの表示**、
**デプロイ済み Web アプリケーションの各ルート表示**、**全量テキストレポートの保存**、
起動状態を維持した検証対象コンテナへの **bash 直接接続 / 対話式 HTTP 通信**と、
**起動中 Compose サービスを選択したログ閲覧・bash 操作**、および
**cwagent / OTel のローカル送達診断**を任意で行えます。
`build_and_push.sh --build-only` はこのスクリプトへ委譲されます
(後述の「ビルドのみの実行 / 起動・URL 確認」を参照)。

想定実行環境: RHEL 9.6 の EC2 インスタンス (bash / GNU coreutils / Docker CE)。

## 使い方

```bash
# compose 版
./build_and_push.sh --account-id 123456789012 --region ap-northeast-1 \
    --auto-switchback --switchback-shell /opt/team/switchback.sh

# buildx 版
./buildx_build_and_push.sh --account-id 123456789012 --region ap-northeast-1 \
    --auto-switchback --switchback-shell /opt/team/switchback.sh
```

## イメージタグについて

イメージタグは `<TAG_PREFIX>-<YYYYMMDDHHMMSS>` の形式で生成されます。
接頭辞 (`--tag-prefix`) は **ECR リポジトリ名 (`--repository`) とは独立** して指定でき、
既定値は `BaseImage` です。

- 例 (既定): `BaseImage-20260702153000`
- リポジトリ名を変更してもタグ接頭辞は影響を受けません。

```bash
# リポジトリ名は my-repo、タグ接頭辞は BaseImage
./build_and_push.sh --repository my-repo --tag-prefix BaseImage
#  => my-repo:BaseImage-20260702153000
```

## オプション

2 スクリプトで共通のオプション (ビルド関連のみ異なります。後述の「buildx 版のみのオプション」参照)。

| オプション | 説明 | 既定値 / 環境変数 |
| --- | --- | --- |
| `--account-id ID` | ECR レジストリの AWS アカウント ID | env: `AWS_ACCOUNT_ID` |
| `--region REGION` | AWS リージョン | `ap-northeast-1` / env: `AWS_REGION` |
| `--registry URL` | ECR レジストリ名(URL) を明示指定 | env: `ECR_REGISTRY`<br>未指定時は `<account-id>.dkr.ecr.<region>.amazonaws.com` を組み立て |
| `--repository NAME` | ECR リポジトリ名 = プッシュするイメージ名 | `BaseImage` |
| `--tag-prefix PREFIX` | イメージタグの接頭辞。リポジトリ名とは独立に指定でき、タグは `<PREFIX>-<YYYYMMDDHHMMSS>` となる | `BaseImage` |
| `--local-image NAME` | ビルドで生成されるローカルイメージ名 | `j1/base.local` |
| `--container-name NAME` | `imagedefinition.json` の name | `--repository` の値 |
| `--compose-file FILE` | compose ファイル (**compose 版のみ**) | `compose.yml` |
| `--compose-service NAME` | ビルド対象サービス名 (未指定なら全サービス) (**compose 版のみ**)。`build_and_verify.sh` / `--build-only` では繰り返し指定またはカンマ区切りで複数指定できる。複数指定時は `base` を先行ビルドする | (全サービス) |
| `--no-cache` | キャッシュを破棄してビルドする | `false` |
| `--output FILE` | imagedefinition の出力先 | `imagedefinition.json` |
| `--dry-run` | 実際のビルド/ログイン/タグ付け/プッシュ/ファイル出力は行わず、実行内容のプレビューのみ表示する | `false` |
| `--cleanup-all-docker-data` | **`build_and_verify.sh` / `--build-only` 委譲時のみ**。処理終了時に確認ダイアログを表示し、承認後、現在の Docker context の全コンテナ・全イメージ・全ローカルボリューム・未使用ネットワーク・現在の daemon で削除可能な全ビルドキャッシュを削除する | `false` |
| `--startup-log-lines N\|all` | **`build_and_verify.sh` / `--build-only` 委譲時のみ**。検証対象のコンテナ起動ログ、同時に起動した他 Compose サービスのログ、`--keep-container-mode logs` で選択したログについて、サービスごとの画面表示行数を指定する。`N` は末尾 `N` 行、`all` は全行を表示する | `50` |
| `--keep-container-mode bash\|http\|logs` | **`build_and_verify.sh` / `--build-only` 委譲時のみ**。JBoss EAP の起動確認後もコンテナを残し、検証対象へ `/bin/bash` で直接接続するか、対話式 HTTP 通信、起動中 Compose サービスを選択したログ閲覧・bash 操作を行う。`logs` では cwagent / CloudWatch Logs モックおよび OTel / Jaeger の送達診断も選択できる。`--verify-startup` と `--keep-container` を暗黙に有効化する | (なし) |
| `--jboss-context-root ROOT` | 対話式 HTTP モードの JBoss EAP コンテキストルートを明示する。未指定時は起動ログから検出する | (自動検出、検出不能時は `/`) |
| `--jboss-http-port PORT` | 対話式 HTTP モードのコンテナ側 HTTP リスナーポートを明示する。Docker の公開ポートがあれば接続先へ自動変換する | (自動検出、検出不能時は `8080`) |
| `--log-dir DIR` | コンソールに出力されるログを `DIR` 配下のログファイルにも保存する。画面表示は従来どおり継続し、ログ末尾には処理実行時間 (経過秒数) も記録される。`DIR` が無ければ自動作成する。ファイル名は compose 版が `build_and_push_<YYYYMMDDHHMMSS>.log`、buildx 版が `buildx_build_and_push_<YYYYMMDDHHMMSS>.log`。compose 版で `--build-only` 委譲時も、委譲先 (`build_and_verify.sh`) の出力を含めて記録する | (なし。指定時のみログファイル出力) |
| `--build-only` | ビルドのみを実行する (**compose 版のみ**。処理は `build_and_verify.sh` に委譲)。ECR 権限チェック/ログイン/タグ付け/プッシュ/`imagedefinition.json` の出力は行わない。`--copy-file` 指定時は事前コピー → ビルド → 自動削除を行う。`--verify-startup` / `--verify-url` 等の追加オプションも委譲される (後述) | `false` |
| `--copy-file SRC:DEST_DIR` | ビルド前に `SRC` を `DEST_DIR` へコピーし、ビルド終了後に自動削除する。繰り返し指定で複数ファイルに対応 | (なし) |
| `--env-list-limit N\|all` | **`build_and_verify.sh` / `--build-only` 委譲時**。動作確認成功後に表示する環境変数一覧の件数。各対象コンテナごとに先頭 `N` 件を表示し、既定は `all` | `all` |
| `--env-list-file FILE` | **`build_and_verify.sh` / `--build-only` 委譲時**。動作確認成功後の環境変数一覧を `FILE` にも出力する。画面表示も継続 | (なし) |
| `--directory-tree-depth N\|all` | **`build_and_verify.sh` / `--build-only` 委譲時**。環境変数一覧後のコンテナ内ツリーと JBoss EAP デプロイ構造の最大深さ。各表示ルート直下を深さ `1` とする | `all` (最下層まで) |
| `--directory-file-limit N\|all` | **`build_and_verify.sh` / `--build-only` 委譲時**。通常ファイルの画面表示を有効にする。各ディレクトリ直下が `N` ファイル以下なら全ファイル名、超過時は拡張子別件数へ切り替える。`all` は常に全ファイル名を表示する | 未指定時はファイル非表示 |
| `--deployment-dir-env NAME` | **`build_and_verify.sh` / `--build-only` 委譲時**。ディレクトリの絶対パスを値に持つコンテナ環境変数名。繰り返しまたはカンマ区切りで複数指定でき、その配下を JBoss EAP デプロイ構造と併せて表示する | (なし) |
| `--report-dir DIR` | **`build_and_verify.sh` / `--build-only` 委譲時**。ビルド結果、環境変数全件、コンテナ内ツリー、JBoss EAP デプロイ構造を、画面の制限にかかわらず全深度・全ファイル名で日時付きテキストへ保存する | (なし) |
| `--jboss-password-param NAME` | JBoss のマスターパスワードを AWS パラメータストア (SSM Parameter Store) の指定キー `NAME` から取得し、環境変数経由の BuildKit シークレットとしてビルドに注入する (後述) | (なし) |
| `--jboss-password VALUE` | JBoss のマスターパスワードを直接指定する (パラメータストアから取得しない場合)。`--jboss-password-param` とは同時指定不可 | (なし) |
| `--jboss-password-env NAME` | シークレットの受け渡しに使う環境変数名。このオプションのみを指定した場合は、事前に export 済みの環境変数の値をそのまま使う | `JBOSS_MASTER_PASSWORD` |
| `--jboss-secret-id ID` | BuildKit シークレットの id (**buildx 版のみ**。compose 版は `compose.yml` の secrets 名で決まる) | `jboss_master_password` |
| `--switchback-shell PATH` | 別チーム提供のスイッチバック用シェルのパス (source で呼び出し) | env: `SWITCHBACK_SHELL` |
| `--auto-switchback` | ECR 権限が無い場合に自動でスイッチバックして継続する | `false` |
| `--warn-only` | ECR 権限が無い場合に警告して終了する (既定) | (既定) |
| `-h`, `--help` | ヘルプを表示 | |

### buildx 版のみのオプション

`buildx_build_and_push.sh` は compose を使わず `docker buildx build` でビルドします。
`docker image tag` / `docker image push` を個別コマンドとして使うため、ビルド結果は
`--load` でローカルの docker イメージストアへ取り込みます (このため単一プラットフォームのみ対応)。

| オプション | 説明 | 既定値 |
| --- | --- | --- |
| `--dockerfile FILE` | Dockerfile のパス | `Dockerfile` |
| `--context DIR` | ビルドコンテキスト | `.` |
| `--platform PLATFORM` | ターゲットプラットフォーム (例: `linux/amd64`)。複数指定は不可 | (現在のプラットフォーム) |
| `--builder NAME` | 使用する buildx ビルダー名 | (現在のビルダー) |
| `--build-arg KEY=VALUE` | ビルド引数 (繰り返し指定可) | (なし) |

buildx 版が実行するコマンドの流れ:

```bash
docker buildx build --load -t j1/base.local -f Dockerfile .
aws ecr get-login-password --region <region> \
  | docker login --username AWS --password-stdin <registry>
docker image tag j1/base.local <registry>/<repository>:<tag>
docker image push <registry>/<repository>:<tag>
```

## ビルド前後の一時ファイルコピー (`--copy-file`)

ビルドコンテキストに一時的に必要なファイル (例: `.npmrc`、証明書、資格情報ファイルなど) を
ビルド直前にコピーし、**ビルド終了後 (成功・失敗・途中終了のいずれでも) に自動削除**します。
`--copy-file` を繰り返し指定することで複数ファイルに対応できます。

```bash
./build_and_push.sh --account-id 123456789012 \
    --copy-file .npmrc:./app \
    --copy-file certs/ca.pem:./app/certs
```

- 書式は `SRC:DEST_DIR`。`SRC` はコピー元ファイル、`DEST_DIR` は**既存の**コピー先ディレクトリ。
- コピー先ファイル名は `SRC` のベース名になります (例: `.npmrc` → `./app/.npmrc`)。
- **安全策**: コピー先に同名ファイルが既に存在する場合は、自動削除で既存ファイルを
  消してしまう事故を防ぐため処理を中止します。
- `--dry-run` 併用時は、実際のコピー/削除は行わず実行内容のみ表示します。

## ログファイル出力 (`--log-dir`)

`--log-dir DIR` を指定すると、コンソールに出力されるログ (標準出力・標準エラー出力) を
`DIR` 配下のログファイルにも保存します。画面表示は従来どおり継続するため、対話実行でも
CI でもそのまま利用できます。compose 版 (`build_and_push.sh`) / buildx 版
(`buildx_build_and_push.sh`) の両方で使えます。

```bash
# compose 版
./build_and_push.sh --account-id 123456789012 \
    --log-dir ./build-logs
#  => ./build-logs/build_and_push_20260702153000.log にログを保存

# buildx 版
./buildx_build_and_push.sh --account-id 123456789012 \
    --log-dir ./build-logs
#  => ./build-logs/buildx_build_and_push_20260702153000.log にログを保存
```

- ファイル名は `<スクリプト名>_<YYYYMMDDHHMMSS>.log` (実行開始時刻) です。
- `DIR` が存在しない場合は `mkdir -p` で自動作成します。
- 標準出力と標準エラー出力を同一の `tee` にまとめるため、ログの時系列順が保たれます。
- ログの末尾には、ビルド成功・失敗・途中終了のいずれの場合でも **処理実行時間**
  (経過秒数と `HH:MM:SS` 形式) が記録されます。
- `--dry-run` 併用時も、プレビュー出力がそのままログファイルへ保存されます。
- compose 版で `--build-only` を併用した場合も、委譲先 (`build_and_verify.sh`) の
  出力を含めてログファイルへ記録します。

## ビルドのみの実行 / 起動・URL 確認 (`build_and_verify.sh`)

イメージのビルドだけを行い ECR へのプッシュは行わない処理は、専用スクリプト
`build_and_verify.sh` に切り出しています。ローカルでの動作確認や CI でのビルド
検証などに利用できます。`build_and_push.sh --build-only` を指定した場合も、
このスクリプトへ委譲されます (`--build-only` を除いた引数がそのまま渡されます)。

- ECR 権限チェック / ログイン / タグ付け / プッシュ / `imagedefinition.json` の
  出力はいずれも行いません。
- ECR を操作しないため、`--account-id` / `--registry` や AWS 認証情報は不要です
  (`aws` コマンドが無くても実行できます)。
- **`--copy-file` が指定されている場合は、ビルド前に事前ファイルコピーを行った
  うえでビルドし、処理後に自動削除します** (`build_and_push.sh` と同じ挙動)。
- BuildKit の進捗形式は既定で `plain` とし、各ビルドステップを保存可能なログとして
  出力します。必要な場合は `BUILDKIT_PROGRESS` 環境変数で変更できます。
- ビルド完了後は対象イメージを検査し、イメージ ID・作成日時・サイズを
  `ビルド結果` として出力します。対象イメージが存在しない場合は失敗終了します。

```bash
# ビルドのみ (事前ファイルコピーあり)
./build_and_verify.sh \
    --copy-file .npmrc:./app \
    --copy-file certs/ca.pem:./app/certs

# build_and_push.sh 経由でも同じ (委譲される)
./build_and_push.sh --build-only --copy-file .npmrc:./app

# 何が実行されるかだけ確認 (ビルドも行わない)
./build_and_verify.sh --dry-run
```

### 終了時の Docker 完全クリーンアップ

`--cleanup-all-docker-data` を指定すると、ビルド・動作確認の終了時に、現在の
Docker context を対象とした確認ダイアログを表示します。これはディスク容量を
確実に空けたい一時的なビルド環境向けの、明示的な破壊オプションです。

```bash
./build_and_verify.sh --cleanup-all-docker-data

# build_and_push.sh の build-only 委譲でも利用可能
./build_and_push.sh --build-only --cleanup-all-docker-data
```

確認画面には Docker context、Docker 管理対象の使用量、コンテナ・イメージ・
ボリュームの件数と、次の処理対象を表示します。

1. Compose プロジェクトを含む、実行中の全 Docker コンテナ (一時停止中の
   コンテナは解除) を通常の `docker stop` で停止
2. 停止済みを含む全コンテナ
3. 全ローカルイメージとタグ
4. 全ローカルボリュームと、その中の永続データ
5. 未使用のユーザー定義ネットワーク
6. 現在の Docker daemon で削除可能な全ビルドキャッシュ

削除を開始するには、表示されたプロンプトへ
`DELETE ALL DOCKER DATA` と正確に入力する必要があります。入力できない場合や
一致しない場合は、通常の `build_and_verify.sh` の後始末以外の Docker 全体
クリーンアップを行わず、終了コード `1` で終了します。処理後は
`docker system df` の削除前後を比較した **Docker 管理対象の概算削減容量**を表示し、
Docker data root のファイルシステムを参照できる場合は、ホスト側の空き容量増加も
併記します。

- 同じ Docker daemon を使う他プロジェクトのデータも対象になり、元に戻せません。
- Docker daemon / Docker Desktop 自体、標準ネットワーク、Docker context、
  レジストリ認証情報、daemon 設定は停止・削除しません。
- `--keep-container` とは同時に指定できません。
- `--dry-run` との併用時は、対象と予定コマンドだけを表示し、確認入力も削除も
  行いません。
- ビルドまたは動作確認が失敗した場合も、実処理開始後であれば終了時に同じ確認を
  行います。元の処理が失敗していた場合、その終了コードを優先します。

### 複数 Compose サービスのビルド・起動

`--compose-service` は繰り返し指定とカンマ区切りの両方に対応しています。複数の
サービスを指定すると、ベースイメージを提供する **`base` サービスを必ず最初に
単独でビルド**し、`--local-image` のイメージが生成されたことを確認してから、
残りのサービスを 1 回の `docker compose build` にまとめて並列ビルドします。
Compose v2 では `--parallel <指定サービス数>`、Compose v1 では
`docker-compose build --parallel` を使用して並列実行を明示します。

```bash
# 繰り返し指定
./build_and_verify.sh \
    --compose-service app \
    --compose-service batch \
    --compose-service db

# カンマ区切り (上と同じ)
./build_and_verify.sh --compose-service app,batch,db
```

上の例で実行されるビルド順は次のとおりです。

```text
1. docker compose --parallel 3 -f compose.yml build base
2. docker compose --parallel 3 -f compose.yml build app batch db
```

- `base` が `--compose-service` に含まれている場合も、第2フェーズでは除外されるため
  二重にはビルドしません。
- `base` が指定に含まれていない場合はビルドの前提として暗黙に先行ビルドしますが、
  **起動対象には追加しません**。
- 起動確認またはURL確認を有効にした場合、指定サービスは1回の
  `docker compose up -d --no-build` にまとめて同時に起動します。
- 1サービスだけを指定した場合と、`--compose-service` を省略した場合は、従来どおり
  1回の `docker compose build` を実行します。

### 起動確認 (`--verify-startup`)

ビルドしたイメージをコンテナとして起動し、**jbosseap (WildFly/JBoss EAP)
サーバーの起動完了**をログから確認します。確認後はコンテナを自動的に停止・削除
します (`--keep-container` を付けると残せます)。

- JBoss EAP 8.1 の正常起動は既定で `WFLYSRV0025` のみを成功とします。
  `WFLYSRV0026` (エラー付き起動) または `WFLYSRV0056` (boot failure) を検出した場合は、
  正常起動ログの有無にかかわらず直ちに失敗終了します。別の正常起動メッセージを
  使う場合は `--startup-log-pattern` (拡張正規表現) で上書きできます。
- `compose up` の直前時刻をログ取得開始時刻として `compose logs --since` に渡し、
  再利用したコンテナに残る過去の起動ログを今回の結果として扱わないようにします。
- `--startup-service NAME` で **JBoss EAP の起動確認を行う Compose サービス**を
  指定できます。繰り返し指定またはカンマ区切りで複数指定でき、指定した全サービスの
  ログを個別に確認します。このオプションだけでも `--verify-startup` が暗黙に有効に
  なります。`--compose-service` と併用する場合は、その起動対象に含まれるサービスを
  指定してください。
- `--startup-timeout` (既定 120 秒) 以内に起動完了ログを検出できない場合、または
  コンテナが起動途中で停止した場合は、コンテナ起動ログを表示して失敗終了します。
- 起動確認の成功時・失敗時とも、検証対象のコンテナ起動ログは既定で末尾 50 行を
  画面表示します。`--startup-log-lines N` で末尾 `N` 行へ変更でき、
  `--startup-log-lines all` で全行表示を明示できます。
- `--startup-service` で検証対象を限定した場合は、同じ `compose up` で現在起動している
  他の Compose サービスも列挙し、検証対象の起動ログ領域の直後へサービス単位で
  順次ログを表示します。各サービスにも `--startup-log-lines` の同じ上限を適用します。
- 対話端末では JBoss EAP ログを、成功系は緑、重要なライフサイクルはシアン、
  warning は黄、error / 起動失敗は赤で表示します。リダイレクト時は ANSI 色コードを
  出力しません。`NO_COLOR` が設定されている場合は色を無効化し、必要な場合は
  `CLICOLOR_FORCE=1` で明示的に有効化できます。
- 動作確認が成功した場合は、**対象コンテナで参照可能な環境変数一覧**も表示します。
  種別は `compose.yml environment` / `build引数` / `コンテナ内部処理` /
  `イメージ既定・その他` を出し分けます。
- 環境変数一覧の表示件数は `--env-list-limit` で制御できます。既定は `all`
  (全件表示) です。
- `--env-list-file FILE` を指定すると、同じ一覧をファイルにも保存できます。
- 環境変数名に `PASSWORD`、`TOKEN`、`SECRET`、`ACCESS_KEY` などを含む値は、
  画面とファイルの双方で `[REDACTED]` とし、秘密情報を平文で残しません。
- 環境変数一覧の後に、同じ対象コンテナの `/` を起点とした**ディレクトリツリー**を
  `├──`、`└──`、`│` の罫線記号を使ったツリー表記で表示します。画面の既定表示は
  ディレクトリのみで、通常ファイルは表示しません。
  ファイル表示を有効にする場合は `--directory-file-limit N` を指定すると、各ディレクトリ
  直下が `N` 件以下なら全ファイル名、超過時は最終拡張子ごとの件数へ切り替えます
  (`archive.tar.gz` は `.gz`、`.env` と末尾がドットの名前は `(拡張子なし)`)。
  件数にかかわらず全ファイル名を出す場合は `--directory-file-limit all` を指定します。
- コンテナ全体ツリーでは、`/afs`、`/aws`、`/etc`、`/local/aws-cli`、
  `/opt/jboss-eap/.galleon`、`/opt/jboss-eap/modules/system/layers/base`、`/proc`、`/share`、
  `/sys`、`/usr/lib`、`/usr/lib64`、`/usr/local` 自体は表示しますが、その配下は
  探索・表示しません。
  この除外は画面表示と全量レポートの両方へ適用します。
- コンテナ全体のツリーに続けて、`*/standalone/deployments`、
  展開済み Web アプリケーションの `WEB-INF` の親、Java クラスパスルートの
  `WEB-INF/classes` を検出し、**JBoss EAP デプロイ構造**として表示します。
  `--deployment-dir-env NAME` で、絶対ディレクトリパスを値に持つ環境変数も
  同じ表示へ追加できます。複数の Web アプリケーションや環境変数指定にも対応します。
- `--directory-tree-depth N` では各表示ルート直下を深さ `1` として最大深度を
  制限できます。既定の `all` は末端まで探索します。空ディレクトリも表示しますが、
  ファイル表示を有効にした場合も通常ファイル以外の特殊ファイルは集計せず、
  シンボリックリンクは循環を避けるため追跡しません。コンテナ内で `find` を
  実行できない場合は警告し、
  ビルド・動作確認の成功状態は維持します。
- `--report-dir DIR` を指定すると、
  `DIR/build_and_verify_<YYYYMMDDHHMMSS>.txt` へ全量レポートを保存します。
  ビルドまたは動作確認が失敗した場合も、コンテナ停止前に取得できた情報を保存します。
  レポートだけは画面用の件数・深度制限を適用せず、環境変数全件、除外対象を除く
  全ディレクトリ深度、全ファイル名を出力します。起動確認を伴わないビルドのみの場合、コンテナ由来の 3 セクションは
  「未取得」と記録します。`--dry-run` ではファイルを作成せず、出力予定だけを表示します。

```bash
# ビルド + jbosseap 起動確認
./build_and_verify.sh --verify-startup

# 起動ログのパターン・待機時間を指定
./build_and_verify.sh --verify-startup \
    --startup-log-pattern 'WFLYSRV0025' --startup-timeout 180

# 検証対象と同時起動 Compose サービスのログを、それぞれ末尾 30 行に制限
./build_and_verify.sh --verify-startup \
    --startup-log-lines 30

# 環境変数一覧を 10 件に制限し、ファイルにも保存
./build_and_verify.sh --verify-startup \
    --env-list-limit 10 \
    --env-list-file ./logs/container_envs.txt

# コンテナ内ディレクトリツリーをディレクトリだけ / 直下から 3 階層まで表示
./build_and_verify.sh --verify-startup \
    --directory-tree-depth 3

# デプロイ構造へ APP_CONFIG_DIR 配下を追加し、5 件超のディレクトリは拡張子集計
./build_and_verify.sh --verify-startup \
    --deployment-dir-env APP_CONFIG_DIR \
    --directory-tree-depth 4 --directory-file-limit 5

# 画面は深さ 2・5 件で制限し、レポートは ./build-reports へ全量保存
./build_and_verify.sh --verify-startup \
    --directory-tree-depth 2 --directory-file-limit 5 \
    --report-dir ./build-reports

# app / batch / db をまとめてビルド・起動し、JBoss EAP の app だけを確認
./build_and_verify.sh --compose-service app,batch,db \
    --startup-service app

# app と batch の両方で JBoss EAP の起動完了を個別に確認
./build_and_verify.sh --compose-service app,batch,db \
    --startup-service app --startup-service batch
```

EAP 8.1の起動ログ解析、同時起動サービスログ、対話操作、ディレクトリツリー集計、
CloudWatch Logs偽装送達レポート、Jaegerトレースレポートは、Docker / curlのモックと
WireMock / JaegerのJSONフィクスチャを使う回帰テストで確認できます。

```bash
bash tests/build_and_verify_test.sh
```

### 起動状態を維持した対話操作 (`--keep-container-mode`)

`--keep-container-mode bash|http|logs` を指定すると、JBoss EAP の起動確認に成功した後も
対象コンテナを停止せず、次の操作をその場で実行できます。このオプションは
`--verify-startup` と `--keep-container` を暗黙に有効化します。bash/http モードで
検証対象コンテナが複数ある場合は、サービス名とコンテナ名を表示する番号選択
ダイアログが開きます。

- `bash`: 選択したコンテナへ `docker exec -it <container> /bin/bash` で直接接続します。
  bash を終了した後もコンテナは起動状態を維持します。対象イメージには
  `/bin/bash` が必要です。
- `http`: JBoss EAP の接続情報を解決した後、パス、HTTP メソッド、必要な POST
  ボディをダイアログで入力し、ホスト側の `curl` から 1 回リクエストします。
  HTTP ステータスコードとレスポンスボディ全体を区切り付きで表示します。
- `logs`: 現在起動している Compose サービスを番号付きで表示します。サービス選択後、
  `1` で今回の起動以降のログ表示、`2` で対象コンテナの対話式 `/bin/bash` 接続を
  選べます。bash セッション内では `cd` で移動しながら任意のコマンドを実行でき、
  bash 終了後は同じサービスの操作選択へ戻ります。同一サービスに複数コンテナがある場合は
  警告を表示して先頭の実行中コンテナへ接続します。ログ表示後も Enter キーで操作選択へ
  戻ります。操作選択の `0` で最新のサービス一覧へ戻り、サービス選択の `0` で終了します。
  ログ表示行数は `--startup-log-lines` (既定: 末尾 50 行) に従い、明示的に選択した
  ログは `--suppress-startup-logs` の指定中でも表示します。bash 操作を行う対象イメージには
  `/bin/bash` が必要です。

`logs` モードでは、対象のComposeサービス名に応じて次の専用操作が`3`として追加されます。
専用操作を使わない通常サービスでは、従来どおり`0`から`2`だけが表示されます。
この診断は
[ProjectRubyRing/Container_Compose_file](https://github.com/ProjectRubyRing/Container_Compose_file)
のローカル可観測性構成（cwagent + WireMock、ADOT Collector + Jaeger）に合わせています。

- `cwagent` / `cloudwatch-logs-mock`: `cwagent`コンテナ内の
  `/etc/cwagentconfig/cwagent-config.json`から収集対象、ロググループ、ログストリームを
  取得します。続いて`cloudwatch-logs-mock`の公開ポートを解決し、WireMock request
  journalの`CreateLogGroup`、`CreateLogStream`、`PutLogEvents`受信数と、直近100リクエスト
  内のイベントを照合します。設定したグループ／ストリームごとの送信件数と、最新20件の
  イベント本文をコンソールへ表示します。
- `otel` / `adot-collector` / `jaeger`: Collectorの`/healthcheck`とdebug exporterログから
  アプリケーションからのスパン受信を確認し、Jaeger Query APIからトレースサービスを
  番号選択します。選択サービスについて直近1時間・最大5トレースを取得し、trace ID、
  開始時刻、所要時間、サービス、スパン親子関係、リソース属性、スパン属性、イベントを
  コンソールへ表示します。参照先ComposeではOTel Collectorのサービス名は
  `adot-collector`です。`otel`も別Composeでの互換サービス名として認識します。

CloudWatch Logsモックは実ログストレージではなく、受信要求を成功応答するWireMockです。
したがってヘルパーの`OK`は、`cwagent`設定とrequest journal内の`PutLogEvents`送信先・
イベント本文が一致したことを表します。また、Jaeger確認はCompose内でX-Rayを代替する
Jaegerへの到達確認であり、実AWS CloudWatch LogsまたはX-Rayへの送信確認ではありません。

専用送達診断を選択した時だけ、ホスト側の`curl`とPython 3
（`python3`、Python 3の`python`、またはRHELの`/usr/libexec/platform-python`）が必要です。
認証ヘッダーは出力せず、パスワードやトークンを示す属性値は伏せ字にします。ただしログ本文や
トレースには業務データが含まれる可能性があるため、画面出力と`--log-dir`の取り扱いには
引き続き注意してください。

HTTP モードでは、`WFLYUT0021` からコンテキストルート、`WFLYUT0006` から
コンテナ側 HTTP リスナーポートを取得します。コンテキストルートが複数ある場合は
番号で選択できます。ポートは `docker port` の公開先を優先し、未公開の場合は
コンテナ IP へ直接接続します。検出できない場合の既定はコンテキストルート `/`、
ポート `8080` です。環境に応じて `--jboss-context-root` と `--jboss-http-port` で
明示的に上書きできます。入力する URL 情報はコンテキストルート以降のパスだけです。

HTTP メソッドは `GET` / `POST` の番号選択です。POST では続けて次のいずれかを選び、
ボディを 1 行で入力します。

- JSON: `Content-Type: application/json`
- form URL encoded: `Content-Type: application/x-www-form-urlencoded`

```bash
# 起動確認後、app コンテナの bash へ直接接続
./build_and_verify.sh \
    --compose-service app \
    --startup-service app \
    --keep-container-mode bash

# 起動確認後、app と db を番号選択し、ログ閲覧または bash 操作を繰り返す
./build_and_verify.sh \
    --compose-service app,db \
    --startup-service app \
    --keep-container-mode logs

# 起動確認後、JBoss EAP へ対話式に HTTP 通信
# 例: /orders が検出された場合、入力した health は /orders/health になる
./build_and_verify.sh \
    --compose-service app \
    --startup-service app \
    --keep-container-mode http

# ログから検出できない環境ではコンテキストルートとコンテナ側ポートを明示
./build_and_verify.sh \
    --compose-service app \
    --startup-service app \
    --keep-container-mode http \
    --jboss-context-root /orders \
    --jboss-http-port 8080
```

HTTP `4xx` / `5xx` も調査対象の応答としてステータスと本文を表示します。接続失敗や
タイムアウトなど `curl` 自体が失敗した場合は終了コード `1` になります。1 リクエストの
最大時間は `--url-timeout` (既定 60 秒) で変更できます。操作終了後の
コンテナは自動削除されないため、不要になったら表示される `docker compose ... down`
コマンドで停止・削除してください。`--cleanup-all-docker-data` とは併用できません。
`build_and_push.sh --build-only --log-dir` 経由で使う場合は、bash セッションの表示内容、
HTTP レスポンス、選択した Compose サービスのログもログファイルへ保存されるため、
秘密情報を画面へ出力しないでください。

### URL 応答確認 (`--verify-url`)

jbosseap サーバーの起動後、**指定した URL へ HTTP リクエストを送り、その応答
(ステータスコード / 本文) を確認**します。単独指定でもコンテナを起動して確認します
(起動ログの確認も行う場合は `--verify-startup` を併用してください)。

- 期待するステータスコードは `--expect-status` (既定 `200`) で指定します。
- `--url-content-type` で `Content-Type` ヘッダを明示指定できます。
- `--url-body-json` / `--url-body-form` で POST 等のリクエストボディを指定できます。
  `--url-body-json` は未指定時に `Content-Type: application/json`、
  `--url-body-form` は未指定時に
  `Content-Type: application/x-www-form-urlencoded` を自動設定します。
  両方の同時指定はできません。
- `--url-timeout` (既定 60 秒) 以内は `--url-interval` (既定 3 秒) ごとにリトライし、
  期待するステータスコードが得られた時点で成功とします。サーバーが応答可能になる
  までの待機 (readiness) も兼ねます。
- 応答本文の先頭を表示するので、内容を目視で確認できます。

```bash
# ビルド + 起動確認 + ヘルスチェック URL の応答確認 (200 を期待)
./build_and_verify.sh --verify-startup \
    --verify-url http://localhost:8080/health --expect-status 200

# POST で確認 / 自己署名証明書の HTTPS を許可
./build_and_verify.sh --verify-startup \
    --verify-url https://localhost:8443/api/ping \
    --url-method POST --url-insecure --expect-status 204

# JSON ボディ付き POST
./build_and_verify.sh --verify-startup \
    --verify-url http://localhost:8080/api/health/check \
    --url-method POST \
    --url-body-json '{"target":"app"}' \
    --expect-status 200

# form 形式ボディ付き POST (Content-Type を明示)
./build_and_verify.sh --verify-startup \
    --verify-url http://localhost:8080/oauth/token \
    --url-method POST \
    --url-content-type 'application/x-www-form-urlencoded; charset=UTF-8' \
    --url-body-form 'grant_type=client_credentials&scope=read' \
    --expect-status 200
```

> **補足**: 起動確認・URL 確認では `compose.yml` の定義に従ってコンテナを起動します
> (`docker compose up -d`)。`--verify-url` で指定する URL のホスト/ポートは、
> `compose.yml` のポートマッピングに合わせてください。

## AWS 認証チェック (`aws login --remote`)

`build_and_push.sh` / `buildx_build_and_push.sh` は、**スクリプト実行開始時に、
事前に `aws login --remote` による認証操作が実行されているか**を
`aws sts get-caller-identity` で確認します。

- **未認証の場合**: 認証を促す警告メッセージを表示して終了します (exit 1)。
  `aws login --remote` を実行して認証してから再実行してください。
- `--dry-run` 併用時は、未認証でも警告のみ表示してプレビューを継続します。
- `build_and_verify.sh` は通常 AWS を操作しないためチェックしませんが、
  `--jboss-password-param` (パラメータストア参照) を指定した場合のみ同じ
  チェックを行います。

## JBoss マスターパスワードの取得と BuildKit シークレット注入

compose ビルド / buildx build の前に、**JBoss のマスターパスワードを取得し、
環境変数経由の BuildKit シークレット (environment 型) として安全にビルドへ注入**
できます。シークレットはビルド中のみ `/run/secrets/<id>` にマウントされ、
**イメージのレイヤ・履歴・環境変数には残りません**。パスワードの値はスクリプトの
ログにも出力されません。

パスワードの取得元は 3 通りから選べます (いずれか 1 つを指定):

| 指定方法 | 説明 |
| --- | --- |
| `--jboss-password-param NAME` | **パラメータストアの指定キーから取得** (`aws ssm get-parameter --with-decryption`)。SecureString パラメータを推奨 |
| `--jboss-password VALUE` | **直接指定** (パラメータストアから取得しない場合)。コマンドライン (ps / シェル履歴) に平文が残るため、可能なら他の 2 方式を推奨 |
| `--jboss-password-env NAME` (単独指定) | **事前に export 済みの環境変数** `NAME` の値をそのまま使う |

取得した値は `--jboss-password-env` の環境変数 (既定: `JBOSS_MASTER_PASSWORD`) へ
export され、以下の経路でビルドに渡されます。

- **buildx 版**: `docker buildx build --secret id=<id>,env=<環境変数名>` を自動付与
  します。id は `--jboss-secret-id` (既定: `jboss_master_password`) で変更できます。
  `--secret` の引数に含まれるのは id と環境変数名のみで、値そのものは含まれません。
- **compose 版** (`build_and_push.sh` / `build_and_verify.sh`): `compose.yml` の
  environment 型シークレット定義を通じて渡します (`docker compose build` には
  シークレットを渡す CLI オプションが無いため)。本リポジトリの `compose.yml` には
  定義済みです。環境変数名を変える場合は `secrets.jboss_master_password.environment`
  と `--jboss-password-env` を一致させてください。

```yaml
# compose.yml (抜粋)
services:
  base:
    build:
      secrets:
        - jboss_master_password
secrets:
  jboss_master_password:
    environment: JBOSS_MASTER_PASSWORD
```

Dockerfile からは `RUN --mount=type=secret` で参照します:

```dockerfile
RUN --mount=type=secret,id=jboss_master_password \
    JBOSS_MASTER_PASSWORD="$(cat /run/secrets/jboss_master_password)" \
    && /opt/jboss/bin/setup-credential-store.sh "$JBOSS_MASTER_PASSWORD"
```

使用例:

```bash
# パラメータストアから取得して注入 (compose 版)
./build_and_push.sh --account-id 123456789012 \
    --jboss-password-param /j1/jboss/master-password

# パラメータストアから取得して注入 (buildx 版, シークレット id を変更)
./buildx_build_and_push.sh --account-id 123456789012 \
    --jboss-password-param /j1/jboss/master-password \
    --jboss-secret-id jboss_vault_password

# パラメータストアを使わず直接渡す
./build_and_push.sh --account-id 123456789012 \
    --jboss-password 'MyMasterPassword'

# 事前に export した環境変数から渡す (コマンドラインに平文を残さない)
export JBOSS_MASTER_PASSWORD='MyMasterPassword'
./buildx_build_and_push.sh --account-id 123456789012 \
    --jboss-password-env JBOSS_MASTER_PASSWORD

# ビルドのみ (build_and_verify.sh / --build-only 委譲) でも利用可能
./build_and_verify.sh --jboss-password-param /j1/jboss/master-password
./build_and_push.sh --build-only --jboss-password-param /j1/jboss/master-password
```

- `--jboss-password-param` と `--jboss-password` は同時に指定できません (exit 2)。
- パラメータストアの取得は、AWS 権限が必要なためスイッチバック確定後に行います。
  取得に失敗した場合 (権限不足 / パラメータ名誤り / リージョン違い) はエラー内容を
  表示して終了します。
- `--dry-run` 併用時は、パラメータストアへの実際のアクセスは行いません。

## push 失敗時の原因診断 / 調査ガイド

`docker push` が失敗した場合、スクリプトは自動的に以下を行います。

1. **AWS API の応答を確認**
   - `aws sts get-caller-identity` … どの IAM プリンシパルとして実行しているか
   - `aws ecr describe-repositories` … プッシュ先リポジトリが実在するか
2. **`docker push` の出力を解析**し、該当する原因カテゴリを推定
3. 各原因について、**詳細な説明 + 具体的な AWS CLI 調査コマンド + AWS コンソールの確認箇所**を表示

判定・ガイドする原因カテゴリ:

| カテゴリ | 主な兆候 | ガイド内容 |
| --- | --- | --- |
| **A. IAM 権限エラー** | `denied` / `not authorized to perform` / `ecr:*` | 必要な ECR アクション一覧、`iam simulate-principal-policy`、CloudTrail での AccessDenied 追跡 |
| **B. ECR エンドポイント権限設定エラー** | `denied` (IAM は正常でも発生) | リポジトリポリシー / VPC エンドポイントポリシーの確認 (`get-repository-policy`, `describe-vpc-endpoints`) |
| **C. ECR エンドポイント不存在疑い** | `no such host` / `timeout` / `dial tcp` | ecr.api / ecr.dkr / s3 の VPC エンドポイント有無・PrivateDNS・ルート・SG(443) の確認 |
| **D. ECR リポジトリが存在しない** | `name unknown` / `does not exist` | `describe-repositories` での一覧確認、リージョン取り違え、`create-repository` |
| **E. 認証トークン期限切れ** | `token has expired` / `401 Unauthorized` | `get-login-password | docker login` での再ログイン |

パターンに一致しない場合は、上記すべての観点を切り分け用チェックリストとして表示します。

## スイッチバックについて

このステージでは CodeCommit の操作は不要で、ECR の操作権限のみが必要です。
現在の操作権限で ECR を操作できない場合の挙動を 2 通りから選べます。

- **(A) 既定 (`--warn-only`)**: スイッチバックを促す警告を出して終了 (exit 1)
- **(B) (`--auto-switchback`)**: 別チーム提供のスイッチバック用シェルを `source` で呼び出し、
  自動的にスイッチバックしてから処理を継続する

スイッチバック用シェルの配置場所は `--switchback-shell` で指定します。
