# ハンズオンガイド：Amazon ECS ネットワークモード比較検証

> 登壇タイトル：**Amazon ECS ネットワークモード選びに悩まない ～検証を通じて見えたネットワークモードの選び方～**
>
> 料金とサービス仕様は変わります。検証当日に、末尾の [参考資料](#参考資料) の公式ドキュメントで最新の値を確認してください。
> 本文中の「仮説」は検証前の予想であり、結果ではありません。

## 目次

- [0. 全体像](#0-全体像)
- [1. 事前準備](#1-事前準備)
- [2. 環境構築](#2-環境構築)
- [3. 検証① スピード](#3-検証-スピード)
- [4. 検証② コスト](#4-検証-コスト)
- [5. 検証③ DevOps Agent によるモニタリング能力](#5-検証-devops-agent-によるモニタリング能力)
- [6. 検証④ 追加観点](#6-検証-追加観点)
- [7. 結果のまとめ方](#7-結果のまとめ方)
- [8. 後片付け](#8-後片付け)
- [付録A. セキュリティチェックリスト](#付録a-セキュリティチェックリスト)
- [付録B. トラブルシューティング](#付録b-トラブルシューティング)
- [参考資料](#参考資料)

---

## 0. 全体像

### 0.1 比較するパターン

| ID | キャパシティ | ネットワークモード | ALB ターゲット | リスナー | サービス名 |
|----|--------------|--------------------|----------------|----------|------------|
| A | Fargate | awsvpc | ip | 8001 | svc-a |
| B1 | EC2 | awsvpc（ENI トランキング **なし**） | ip | 8002 | svc-b1 |
| B2 | EC2 | awsvpc（ENI トランキング **あり**） | ip | 8003 | svc-b2 |
| C | EC2 | bridge（動的ポート） | instance | 8004 | svc-c |
| D | EC2 | host | instance | 8005 | svc-d |
| E（任意） | ECS Managed Instances | awsvpc / host | ip / instance | ― | ― |

- `none` は外部と通信できないため対象外です
- ECS Managed Instances は awsvpc と host のみ対応で、bridge は使えません。余裕があれば E として追加します

### 0.2 構成

```
┌──────────────────────────── VPC 10.0.0.0/16（IGW / NAT なし）─────────────────────────────┐
│                                                                                          │
│  Private subnet AZ-a (10.0.0.0/20)                 Private subnet AZ-b (10.0.16.0/20)     │
│  ┌──────────────────────────────────────┐          ┌──────────────────────────────┐      │
│  │ A  Fargate タスク (awsvpc)            │          │ 負荷生成 EC2（SSM で接続）     │      │
│  │ B1 EC2 x2 ── タスク ENI               │ ◀─────── │  docker: k6 / iperf3          │      │
│  │ B2 EC2 x2 ── トランク ENI ── タスク    │          └──────────────────────────────┘      │
│  │ C  EC2 x2 ── docker0 ── タスク         │                     │                        │
│  │ D  EC2 x2 ── ホストのネットワーク       │ ◀──── 内部 ALB（8001-8005、パターンごと）       │
│  └──────────────────────────────────────┘                                                │
│                                                                                          │
│  VPC エンドポイント: ECR / S3 / Logs / SSM / ECS     VPC Flow Logs（ECS フィールド付き）      │
└──────────────────────────────────────────────────────────────────────────────────────────┘
          │ Container Insights（強化版）/ ECS イベント / アラーム
          ▼
   AWS DevOps Agent（Agent Space）
```

- 計測対象の EC2（B1 / B2 / C / D）はすべて AZ-a、負荷生成 EC2 は AZ-b に置きます。**AZ をまたぐ通信が基本** になるため、同一 AZ での値も取りたい場合は 3.3 の手順で負荷生成を AZ-a に移します
- パターンごとに Auto Scaling グループとキャパシティプロバイダーを分け、ALB のリスナーとターゲットグループも分けています。メトリクスが混ざりません

### 0.3 公平に比べるためのルール

- EC2 のパターンは **同じインスタンスタイプ・同じ AMI・同じ AZ・同じ台数**（既定は `c6i.large` × 2）
- タスクのサイズ（既定 0.25 vCPU / 512 MiB）、イメージ、nginx 設定は全パターン共通
- 計測は **5 回以上繰り返し、中央値と p95 を使う**。1 回だけの値は使わない
- 各計測の前にウォームアップを入れる（k6 スクリプトは 30 秒のウォームアップを含む）
- 計測日時、リージョン、インスタンスタイプ、ECS エージェントと AMI のバージョンを記録する

---

## 1. 事前準備

### 1.1 必要なもの

| 項目 | 内容 |
|------|------|
| AWS アカウント | **検証専用アカウント**（ENI トランキングのアカウント設定を変えるため） |
| 実行環境 | **AWS CloudShell を推奨**（長期のアクセスキーを手元に置かずに済む。bash 4.4 以上・AWS CLI v2・jq・Docker・Python 3 がそろっている） |
| リージョン | 例：`ap-northeast-1`。DevOps Agent の Agent Space の対応リージョンは別途確認 |
| 権限 | CloudFormation で IAM ロールを作れる権限。検証後に外す |

### 1.2 環境変数

```bash
export AWS_REGION=ap-northeast-1
export PREFIX=netmode-lab
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
git clone https://github.com/MASAKIOKUDA-eng/aws-ecs-nw-mode-handsom.git
cd aws-ecs-nw-mode-handsom
```

### 1.3 予算アラート

消し忘れに備えて最初に作ります。

```bash
aws budgets create-budget --account-id "$ACCOUNT_ID" \
  --budget '{"BudgetName":"'"$PREFIX"'","BudgetLimit":{"Amount":"50","Unit":"USD"},"TimeUnit":"MONTHLY","BudgetType":"COST"}' \
  --notifications-with-subscribers '[{"Notification":{"NotificationType":"ACTUAL","ComparisonOperator":"GREATER_THAN","Threshold":80},"Subscribers":[{"SubscriptionType":"EMAIL","Address":"<your-mail>"}]}]'
```

テンプレートは `Project` と `NetMode` のタグを付けます。Billing コンソールで **コスト配分タグとして有効化** しておくと、Cost Explorer でパターン別に集計できます（有効化した後のデータから集計されます）。

---

## 2. 環境構築

### 2.1 ネットワーク

```bash
aws cloudformation deploy --stack-name "$PREFIX-network" \
  --template-file cfn/01-network.yaml \
  --parameter-overrides Prefix="$PREFIX" \
  --capabilities CAPABILITY_IAM
```

作られるもの：

| リソース | ポイント |
|----------|----------|
| VPC（private subnet × 2 のみ） | IGW / NAT がないので、外向き通信はそもそも出られない |
| VPC エンドポイント | ECR API / ECR DKR / S3（Gateway）/ Logs / SSM / SSM Messages / EC2 Messages / ECS / ECS Agent / ECS Telemetry |
| SG | タスク用（A / B）、EC2 用（awsvpc ホスト・bridge・host）、ALB、負荷生成、エンドポイント |
| VPC Flow Logs | **ECS フィールド**（`ecs-cluster-name`、`ecs-service-name`、`ecs-task-id` など）を含むカスタム形式 |

> **SG の違い（登壇ネタ）**
> - awsvpc：タスクの ENI に SG を付ける。ALB から 8080 だけ許可
> - bridge：インスタンスの SG で **動的ポートの範囲 32768–65535 をまとめて許可** する必要がある
> - host：インスタンスの SG で 8080 を許可。同じインスタンスの他のプロセスとも SG を共有する

### 2.2 基盤

ENI トランキングは「有効化した後に起動したインスタンスだけ」に効きます。そのため **B2 の台数は 0 で作り、2.5 で増やします**。

```bash
aws cloudformation deploy --stack-name "$PREFIX-platform" \
  --template-file cfn/02-platform.yaml \
  --parameter-overrides Prefix="$PREFIX" InstanceType=c6i.large CapacityB2=0 \
  --capabilities CAPABILITY_IAM
```

作られるもの：ECS クラスター（Container Insights 強化版）、ECS イベントを CloudWatch Logs に保存するルール、IAM ロール、ECR リポジトリ × 2、内部 ALB とターゲットグループ × 5、EC2 キャパシティ × 4、負荷生成 EC2。

> **IMDS への到達性（セキュリティの要点）**
> - EC2 はすべて IMDSv2 必須・ホップ数上限 1
> - awsvpc：`ECS_AWSVPC_BLOCK_IMDS=true` でタスクから遮断
> - bridge：ホップ数上限 1 で、コンテナからの IMDSv2 を遮断
> - host：コンテナがホストのネットワークをそのまま使うため **遮断できない**。6.1 で実際に確かめます

### 2.3 コンテナイメージ

CloudShell などの Docker が使える環境でビルドします。

```bash
REPO_NB=$(aws cloudformation describe-stacks --stack-name "$PREFIX-platform" --query "Stacks[0].Outputs[?OutputKey=='NetbenchRepoUri'].OutputValue" --output text)
REPO_LG=$(aws cloudformation describe-stacks --stack-name "$PREFIX-platform" --query "Stacks[0].Outputs[?OutputKey=='LoadgenRepoUri'].OutputValue" --output text)
aws ecr get-login-password | docker login --username AWS --password-stdin "$ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com"

# ベースイメージはダイジェストで固定することを推奨（--build-arg BASE=...@sha256:...）
docker build --platform linux/amd64 -t "$REPO_NB:v1" docker/netbench
docker build --platform linux/amd64 -t "$REPO_LG:v1" -f docker/loadgen/Dockerfile .
docker push "$REPO_NB:v1"
docker push "$REPO_LG:v1"

NB_DIGEST=$(aws ecr describe-images --repository-name "$PREFIX/netbench" --image-ids imageTag=v1 --query 'imageDetails[0].imageDigest' --output text)
LG_DIGEST=$(aws ecr describe-images --repository-name "$PREFIX/loadgen"  --image-ids imageTag=v1 --query 'imageDetails[0].imageDigest' --output text)
export NETBENCH_IMAGE="$REPO_NB@$NB_DIGEST"
export LOADGEN_IMAGE="$REPO_LG@$LG_DIGEST"
```

push 後に ECR のスキャン結果を確認し、Critical / High の脆弱性があれば先に解消します。

```bash
aws ecr describe-image-scan-findings --repository-name "$PREFIX/netbench" --image-id imageTag=v1 \
  --query 'imageScanFindings.findingSeverityCounts'
```

### 2.4 サービス

`03-services.yaml` はループ（`Fn::ForEach`）を使うため `CAPABILITY_AUTO_EXPAND` が必要です。

```bash
aws cloudformation deploy --stack-name "$PREFIX-services" \
  --template-file cfn/03-services.yaml \
  --parameter-overrides Prefix="$PREFIX" NetbenchImage="$NETBENCH_IMAGE" DesiredB2=0 \
  --capabilities CAPABILITY_AUTO_EXPAND
```

| パターン | タスク定義のポイント |
|----------|----------------------|
| A / B | `networkMode: awsvpc`。サービスにサブネットと SG を指定 |
| C | `networkMode: bridge`、`hostPort: 0`（動的ポート） |
| D | `networkMode: host`、`hostPort: 8080`。**1 台に 1 タスクまで**。そのためローリング更新は `minimumHealthyPercent: 50` にしている |

### 2.5 ENI トランキングを有効にして B2 を起動

```bash
# アカウントの既定値を変更（検証専用アカウントで実施すること）
aws ecs put-account-setting-default --name awsvpcTrunking --value enabled

# B2 の EC2 を起動
aws cloudformation deploy --stack-name "$PREFIX-platform" --template-file cfn/02-platform.yaml \
  --parameter-overrides Prefix="$PREFIX" InstanceType=c6i.large CapacityB2=2 --capabilities CAPABILITY_IAM

# トランク ENI が付いたか確認（B2 のインスタンスだけに ecs.awsvpc-trunk-id が出るはず）
for ci in $(aws ecs list-container-instances --cluster "$PREFIX" --query 'containerInstanceArns[]' --output text); do
  aws ecs describe-container-instances --cluster "$PREFIX" --container-instances "$ci" \
    --query 'containerInstances[0].[ec2InstanceId, attributes[?name==`netmode-pool`].value|[0], attributes[?name==`ecs.awsvpc-trunk-id`].value|[0]]' --output text
done

# B2 のサービスを起動
aws cloudformation deploy --stack-name "$PREFIX-services" --template-file cfn/03-services.yaml \
  --parameter-overrides Prefix="$PREFIX" NetbenchImage="$NETBENCH_IMAGE" DesiredB2=2 --capabilities CAPABILITY_AUTO_EXPAND
```

> **注意**：既定値を有効にした後に B1 のインスタンスが入れ替わると、B1 にもトランク ENI が付きます。B1 の計測前に、上のコマンドで B1 に `ecs.awsvpc-trunk-id` が **ない** ことを毎回確認してください。

### 2.6 負荷生成 EC2 に入る

```bash
LOADGEN_ID=$(aws cloudformation describe-stacks --stack-name "$PREFIX-platform" --query "Stacks[0].Outputs[?OutputKey=='LoadgenInstanceId'].OutputValue" --output text)
aws ssm start-session --target "$LOADGEN_ID"
```

負荷生成 EC2 の中で：

```bash
sudo usermod -aG docker ssm-user && exec sudo -iu ssm-user   # docker を使えるようにする（初回のみ）
export AWS_REGION=ap-northeast-1
export LOADGEN_IMAGE=<2.3 で作った LOADGEN_IMAGE の値>
export ALB_DNS=<platform スタックの AlbDnsName>
aws ecr get-login-password | docker login --username AWS --password-stdin "${LOADGEN_IMAGE%%/*}"
docker pull "$LOADGEN_IMAGE"
mkdir -p ~/results
# 以降、計測はこの関数経由で実行する
lg() { docker run --rm --network host --read-only --tmpfs /tmp --cap-drop ALL \
         --user "$(id -u):$(id -g)" -v "$HOME/results:/work/results" "$LOADGEN_IMAGE" "$@"; }
lg k6 version
```

### 2.7 動作確認

```bash
for port in 8001 8002 8003 8004 8005; do
  curl -s -o /dev/null -w "$port %{http_code} %{time_total}s\n" "http://$ALB_DNS:$port/1k"
done
```

手元のブラウザで確認したい場合は、CloudShell などから SSM のポートフォワーディングを使います（ALB を外部に公開しないため）。

```bash
aws ssm start-session --target "$LOADGEN_ID" --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters "host=$ALB_DNS,portNumber=8001,localPortNumber=8001"
```

---

## 3. 検証① スピード

### 3.1 計測項目

| # | 項目 | 道具 | わかること |
|---|------|------|------------|
| S-1 | タスク起動時間（少数） | `measure-startup.sh --count 1` | 1 タスクの起動にかかる時間の内訳 |
| S-2 | 同時起動（多数） | `measure-startup.sh --count 10` | ENI の準備が詰まるか |
| S-3 | TCP スループット | `run-iperf.sh` | ネットワークスタックの違いによる帯域差 |
| S-4 | HTTP レイテンシ（ALB 経由） | `run-k6.sh --path alb` | 実際のアプリに近い条件での差 |
| S-5 | HTTP レイテンシ（直接） | `run-k6.sh --path direct` | ALB を挟まない場合の差 |

### 3.2 S-1 / S-2：タスク起動時間

ECS の `describe-tasks` の時刻を使います。

| 指標（CSV の metric） | 計算 | 意味 |
|-----------------------|------|------|
| `network_ready` | `connectivityAt - createdAt` | ネットワークの準備（awsvpc では ENI） |
| `pull_duration` | `pullStoppedAt - pullStartedAt` | イメージの取得 |
| `startup_total` | `startedAt - createdAt` | 起動までの合計 |

CloudShell で実行します（1 回目は EC2 にイメージをキャッシュさせるための空打ちとし、結果から外します）。

```bash
S=scripts/measure-startup.sh
$S --label A  --task-def "$PREFIX-a-fargate-awsvpc" --capacity-provider FARGATE          --awsvpc --count 10 --repeat 5
$S --label B1 --task-def "$PREFIX-b-ec2-awsvpc"     --capacity-provider "$PREFIX-cp-b1"  --awsvpc --count 10 --repeat 5
$S --label B2 --task-def "$PREFIX-b-ec2-awsvpc"     --capacity-provider "$PREFIX-cp-b2"  --awsvpc --count 10 --repeat 5
$S --label C  --task-def "$PREFIX-c-ec2-bridge"     --capacity-provider "$PREFIX-cp-c"            --count 10 --repeat 5
python3 scripts/summarize.py results/startup.csv
```

- **D（host）は 1 台に 1 タスクしか置けず、すでにサービスのタスクが動いているため、そのままでは起動できません**。D を測るときは `svc-d` の `desired-count` を 0 にしてから `--count 2`（台数分）で測ります
- B1 で `--count 10` にすると、ENI の上限を超えた分は起動できません。スクリプトが表示する `failures` の理由（例：`RESOURCE:ENI`）を記録します。これは 4 章のコスト比較の根拠になります
- Fargate は毎回イメージを取得するため、`startup_total` と合わせて `pull_duration` を差し引いた値も比べます
- ALB にターゲットとして登録され、通信できるようになるまでの時間はヘルスチェック設定（全パターン共通：間隔 10 秒、2 回成功で healthy）の影響が大きいため、別の指標として扱います

### 3.3 S-3：スループット（iperf3）

CloudShell で接続先を調べます。

```bash
for s in svc-a svc-b1 svc-b2 svc-c svc-d; do echo "== $s"; scripts/get-targets.sh "$s"; done
```

| パターン | 接続先 |
|----------|--------|
| A / B1 / B2 | タスクの IP : 5201 |
| C | インスタンスの IP : 動的ポート（`iperf_port` 列） |
| D | インスタンスの IP : 5201 |

負荷生成 EC2 で実行します。

```bash
lg run-iperf.sh --label B1 --target <ip> --port <iperf_port> --parallel 1 --repeat 5 --az cross
lg run-iperf.sh --label B1 --target <ip> --port <iperf_port> --parallel 8 --repeat 5 --az cross
```

- `--parallel 1`（1 本の TCP 接続）と `--parallel 8` の両方を取ります
- 同一 AZ の値も取りたい場合は、負荷生成 EC2 を AZ-a に作り直すか、計測対象の ASG を AZ-b に寄せます
- **インスタンスタイプのネットワーク帯域の上限に当たっていないか** を必ず確認します。上限に当たっている場合は「モードの差ではなくインスタンスの上限」と明記します
- iperf3 は 1 タスクにつき同時に 1 接続しか受けません。同時に複数のクライアントから測らないでください

### 3.4 S-4 / S-5：HTTP レイテンシ（k6）

負荷生成 EC2 で、レートを段階的に上げます。

```bash
# ALB 経由（リスナーのポートでパターンを切り替える）
lg run-k6.sh --label A  --url "http://$ALB_DNS:8001/1k" --rates "100 500 1000 2000" --path alb
lg run-k6.sh --label B1 --url "http://$ALB_DNS:8002/1k" --rates "100 500 1000 2000" --path alb
lg run-k6.sh --label B2 --url "http://$ALB_DNS:8003/1k" --rates "100 500 1000 2000" --path alb
lg run-k6.sh --label C  --url "http://$ALB_DNS:8004/1k" --rates "100 500 1000 2000" --path alb
lg run-k6.sh --label D  --url "http://$ALB_DNS:8005/1k" --rates "100 500 1000 2000" --path alb

# タスクへ直接（get-targets.sh の ip と web_port を使う）
lg run-k6.sh --label C --url "http://<ip>:<web_port>/1k" --rates "500 1000" --path direct
```

- 固定レート（`constant-arrival-rate`）で負荷をかけるので、パターン間で同じ負荷になります
- 見るもの：**p50 / p95 / p99、エラー率、dropped_iterations**（負荷側が追いつかなかった数。0 でなければ負荷生成側の限界）
- **p99 が急に悪化するレート** をパターンごとに比べます
- 同時に Container Insights でタスクの CPU 使用率を見ます。CPU が先に限界になっていれば、それはネットワークモードの差ではありません
- ペイロードを `/100k`、`/1m` に変えると、帯域寄りの差が見えます

### 3.5 結果を集計する

```bash
# 負荷生成 EC2 の ~/results/*.csv は小さいので、Session Manager 上で cat して CloudShell の results/ に貼り付ける。
# S3 で受け渡す場合は、各自で作ったバケット（パブリックアクセスをブロック）への s3:PutObject だけを負荷生成ロールに追加する。
python3 scripts/summarize.py results/iperf.csv --group parallel,az_relation
python3 scripts/summarize.py results/k6.csv --group path,rate
```

---

## 4. 検証② コスト

### 4.1 コストを決める要素

| 要素 | A Fargate | B1 / B2 EC2 awsvpc | C EC2 bridge | D EC2 host |
|------|-----------|--------------------|--------------|------------|
| 計算リソース | vCPU 時間 + GB 時間 | インスタンス時間 | インスタンス時間 | インスタンス時間 |
| **1 台あたりのタスク数を決めるもの** | ― | CPU / メモリ と **ENI 数**（B2 はトランキングで緩和） | CPU / メモリ | CPU / メモリ と **ポート**（同じポートは 1 台に 1 つ） |
| VPC の IP 消費 | タスクごと | タスクごと（+ インスタンス、B2 はトランク ENI も） | インスタンスごと | インスタンスごと |
| パブリック IPv4 | タスクに付けるとタスク数だけ課金 | 同左 | インスタンスごと | インスタンスごと |
| 監視 | Container Insights はタスク数・コンテナ数に応じて増える | 同左 | 同左 | 同左 |

今回の構成はパブリック IP を使いません。タスクに `assignPublicIp=ENABLED` を付けると、料金と攻撃対象の両方が増えます。

### 4.2 実測：1 台に何タスク置けるか

```bash
# 例：B1（2 台）にタスクを 30 個要求する
aws ecs update-service --cluster "$PREFIX" --service svc-b1 --desired-count 30
sleep 120
aws ecs describe-services --cluster "$PREFIX" --services svc-b1 \
  --query 'services[0].{running:runningCount,pending:pendingCount,events:events[:5].message}'
# 元に戻す
aws ecs update-service --cluster "$PREFIX" --service svc-b1 --desired-count 2
```

| パターン | 予想される上限の理由 |
|----------|----------------------|
| B1 | ENI 数（プライマリ ENI を除いた数） |
| B2 | トランキング時の上限、または CPU / メモリ |
| C | CPU / メモリ |
| D | ポート（同じポートなら 1 台に 1 タスク） |

インスタンスに登録された CPU / メモリは `describe-container-instances` の `registeredResources` で確認できます。試算スクリプトの `--usable-mem-ratio` はこの値に合わせます。

### 4.3 試算

**単価は検証当日の料金ページの値を入力してください**（スクリプトには料金を埋め込んでいません）。ENI 数とトランキング時の上限は、インスタンスタイプごとに公式の表で確認します。

```bash
python3 scripts/cost-calc.py \
  --task-vcpu 0.25 --task-mem-gib 0.5 \
  --instance-vcpu 2 --instance-mem-gib 4 \
  --max-eni <ENI 数> --trunk-eni-limit <トランキング時の上限> \
  --instance-hourly <EC2 の時間単価> \
  --fargate-vcpu-hourly <Fargate vCPU 時間単価> --fargate-gb-hourly <Fargate GB 時間単価> \
  --sweep 10,20,40,80,160 --csv results/cost-sweep.csv
```

出力の `limited_by` 列で、何が台数を決めているか（ENI / ポート / CPU・メモリ）がわかります。`--sweep` の CSV は「タスク数 × 月額」のグラフにそのまま使えます。

> 仮説：小さいタスクを大量に動かすほど、B1（ENI）と D（ポート）は台数が増えて割高になる。B2 と C は CPU / メモリで決まる。

### 4.4 実績との突き合わせ

- 各パターンを **同じ時間（例：3 時間）同じ台数とタスク数** で動かし、翌日以降に Cost Explorer で `NetMode` タグ別に比べます
- 試算と実績のずれ（データ転送、ログ量、Container Insights のメトリクス数など）は、そのまま登壇で話せる発見になります
- **データ転送**：負荷生成 EC2 と計測対象を別の AZ に置いているため、AZ 間のデータ転送料金がかかります。長時間の負荷試験は避けてください

---

## 5. 検証③ DevOps Agent によるモニタリング能力

### 5.1 狙い

同じ障害を各パターンで起こし、AWS DevOps Agent が **「どのタスク / どのホストで」「何が原因か」** を正しく特定できるかを比べます。ネットワークモードによって、使える観測データの粒度が変わるためです。

| 観測データ | awsvpc（A / B） | bridge（C） | host（D） |
|------------|-----------------|-------------|-----------|
| VPC Flow Logs | **タスクの ENI 単位** | ホストの ENI にまとまる | ホストの ENI にまとまる |
| Container Insights のネットワークメトリクス | ○ | ○ | **×（取得できない）** |
| SG | タスク単位 | インスタンス単位 | インスタンス単位 |
| FIS の ECS タスク向けネットワーク障害 | ○ | **×（bridge 非対応）** | ○ |

> 「×」の部分も、運用面での重要な比較結果です。

### 5.2 DevOps Agent のセットアップ

画面構成は変わることがあるため、公式ユーザーガイドに沿って進めます。大まかな流れは次のとおりです。

1. **Agent Space を作成**（対応リージョンを確認）
2. **調査対象の AWS アカウントを関連付け**、ウィザードが作る IAM ロールの権限を確認（読み取り中心であること。**書き込み権限を足さない**）
3. **トポロジー（リソースの関係）の検出を待ち**、ECS クラスター・サービス・ALB・ターゲットグループが見えているか確認
4. Web アプリ（オペレーター画面）へのアクセスを、検証メンバーだけに絞る
5. （任意）アラームから自動で調査を始める
   - CloudWatch アラーム → EventBridge → DevOps Agent の Webhook
   - Webhook の認証情報は **Secrets Manager に保存** し、コードに直書きしない（EventBridge の API Destination を使う場合、接続情報は EventBridge が Secrets Manager に保存する）
   - HMAC 署名方式では署名を計算する Lambda が必要（タイムスタンプを含めて署名し、リプレイを防ぐ）

**料金**：エージェントが作業した時間に対して秒単位で課金されます。5 パターン × 5 シナリオ × 3 回だと 75 回の調査になります。AWS/AIDevOps 名前空間の CloudWatch メトリクスで Agent Space ごとの使用量を確認し、予算アラートも設定してください。

### 5.3 監視の前提をそろえる

`03-services.yaml` で、全パターン共通のアラームを作っています。

| アラーム名 | 条件 |
|------------|------|
| `<prefix>-<P>-target-5xx` | ターゲットの 5xx が 1 分あたり 10 件超 × 2 回 |
| `<prefix>-<P>-p99-latency` | p99 応答時間がしきい値（既定 0.5 秒）超 × 3 回 |
| `<prefix>-<P>-unhealthy-hosts` | unhealthy なターゲットが 1 以上 × 2 回 |
| `<prefix>-<P>-running-below-desired` | 実行中のタスク数が希望数を下回る × 5 回（Container Insights） |

DevOps Agent が使える材料：Container Insights（強化版）、VPC Flow Logs（ECS フィールド付き）、ECS イベントのログ（`/aws/events/<prefix>-ecs`）、アプリの JSON アクセスログ（`request_time` 付き）、CloudTrail（SG 変更などの操作履歴）。

### 5.4 障害シナリオ

詳しい手順と戻し方は [devops-agent/scenarios.md](../devops-agent/scenarios.md) にあります。

| # | シナリオ | awsvpc | bridge | host | 見たいこと |
|---|----------|--------|--------|------|------------|
| F-1 | SG ルールの削除（ALB → ターゲット） | タスク SG | インスタンス SG | インスタンス SG | 原因の SG 変更と影響範囲を特定できるか |
| F-2 | ポート衝突でデプロイが止まる | 発生しない | 静的ポート時のみ | **発生** | デプロイが進まない理由をポート衝突と特定できるか |
| F-3 | ENI 不足でタスクが起動しない | B1 で発生 | ― | ― | ENI 不足と特定し、トランキングを提案できるか |
| F-4 | 特定タスクだけ遅い（FIS 遅延注入） | ○ | **FIS 非対応** | ○ | 遅いタスクを 1 つに絞り込めるか |
| F-5 | 高負荷による応答悪化 | ○ | ○ | ○ | CPU とネットワークのどちらが原因か見分けられるか |

### 5.5 調査の進め方（毎回同じ条件で）

1. 障害を起こし、アラームが発報するのを待つ（時刻を記録）
2. 調査を始める。手動の場合は **毎回同じプロンプト** を使い、原因のヒントを入れない

   ```
   <ALB 名> のリスナー <ポート> で <時刻> 頃から <5xx の増加 / 応答の遅れ / タスク数の不足> が起きています。
   原因を調査してください。
   ```

3. 結果が出るまでの時間、根拠にしたデータ、提案された対処を [devops-agent/evaluation-sheet.md](../devops-agent/evaluation-sheet.md) に記録
4. 追加で質問した場合は、その回数も記録
5. 障害を元に戻し、メトリクスが平常に戻るまで 10 分以上空ける

各シナリオ × 各パターンで **3 回** 試行します。

---

## 6. 検証④ 追加観点

スピード・コスト・モニタリング以外に、ネットワークモードを選ぶときに効いてくる観点です。**机上で調べるもの（📖）** と **実際に確かめるもの（🧪）** に分けています。

### 6.1 🧪 セキュリティの分離

モードごとに、コンテナの中から何に手が届くかを確かめます。

```bash
scripts/security-probe.sh "$NETBENCH_IMAGE"
```

| 確認項目 | 予想（A / B） | 予想（C） | 予想（D） |
|----------|---------------|-----------|-----------|
| IMDSv2 のトークン取得 | 遮断 | 遮断（ホップ数上限 1） | **取得できる** |
| ホストの ECS エージェント API（127.0.0.1:51678） | 届かない | 届かない | **届く** |
| ホストの sshd（127.0.0.1:22） | 届かない | 届かない | **届く** |
| 見えるネットワークインターフェース | タスク専用 | コンテナ専用（docker0 配下） | ホストのものすべて |

- プローブは読み取りだけを行い、取得できた情報は使いません
- 結果は `results/security-probe.csv` に追記されます
- 実施後、`<prefix>-probe-*` のタスク定義を登録解除します

**SG の粒度** も比べます。awsvpc はタスクごとに SG を分けられますが、bridge / host は同じインスタンス上のすべてのタスクが 1 つの SG を共有します。異なる通信要件のサービスを同じインスタンスに混ぜると、許可範囲が広がります。

### 6.2 🧪 IP アドレスの消費とスケールの上限

awsvpc はタスクごとに VPC の IP を使います。サブネットの残り IP をスケールの前後で比べます。

```bash
aws ec2 describe-subnets --subnet-ids <PrivateSubnetA> --query 'Subnets[0].AvailableIpAddressCount'
aws ecs update-service --cluster "$PREFIX" --service svc-a --desired-count 20
# 数分後にもう一度残り IP を確認し、元に戻す
```

`cost-calc.py` の `vpc_ips` 列とも突き合わせます。大規模な環境では、サブネットの大きさ（今回は `/20`）が設計上の制約になることを示せます。

### 6.3 🧪 デプロイの速さと止まりやすさ

全パターンで強制的に再デプロイし、安定するまでの時間を測ります。

```bash
for s in svc-a svc-b1 svc-b2 svc-c svc-d; do
  start=$(date +%s)
  aws ecs update-service --cluster "$PREFIX" --service "$s" --force-new-deployment >/dev/null
  aws ecs wait services-stable --cluster "$PREFIX" --services "$s"
  echo "$s,deploy_seconds,$(( $(date +%s) - start ))"
done
```

- D（host）は空きインスタンスがないと新しいタスクを置けないため、`minimumHealthyPercent` を下げる（=一時的に処理能力が減る）か、予備のインスタンスを持つ（=コストが増える）必要があります
- ECS ネイティブの Blue/Green デプロイも、空きポートや予備の台数の考え方は同じです

### 6.4 📖 サービス間通信の選択肢

| 機能 | awsvpc | bridge | host |
|------|--------|--------|------|
| ECS Service Connect | ○ | ○ | **×** |
| Cloud Map（サービスディスカバリ） | A レコード | SRV レコード（ポート番号も必要） | SRV レコード |
| VPC Lattice | ○ | ○ | ○ |

host モードでは Service Connect が使えません。マイクロサービス間の通信をどう組むかが、モード選びの決め手になることがあります。

### 6.5 🧪 サイドカーとタスク内の通信

ADOT Collector、Envoy、FireLens などのサイドカーは、同じタスクのコンテナと `localhost` で通信する前提のものが多くあります。

| モード | 同じタスク内のコンテナ同士 |
|--------|----------------------------|
| awsvpc | 同じネットワーク名前空間を共有。`localhost` で通信できる |
| host | ホストの名前空間を共有。`localhost` で通信できる（他のタスクとも共有） |
| bridge | **コンテナごとに名前空間が分かれる**。`links` やポートマッピング、Service Connect を使う |

確かめ方：bridge のタスク定義に、`curl http://localhost:8080/health` を繰り返すコンテナを足して動かし、失敗することを確認します（`links` を設定すると、コンテナ名で通信できるようになります）。

### 6.6 📖 IPv6

2025 年 9 月から、ECS は awsvpc・bridge・host のすべてで IPv6 のみの構成に対応しています。ただし bridge / host のタスクをロードバランサーや Cloud Map に登録するには、インスタンスにプライマリ IPv6 アドレスが必要です。「IPv6 だから awsvpc しかない」わけではない点を押さえておきます。

### 6.7 🧪 ノイジーネイバー（同じホストのタスクの影響）

EC2 のパターンでは、同じインスタンスのタスクがインスタンスのネットワーク帯域を分け合います。

1. 同じインスタンスに載っている 2 タスクを `get-targets.sh` で探す
2. 片方に iperf3 で負荷をかけながら、もう片方に k6 で HTTP 負荷をかけ、p99 の悪化を測る
3. Fargate（A）でも同じことを行い、比べる

> 仮説：EC2 のパターンはモードによらず影響を受け、Fargate はタスクごとに独立しているため影響を受けにくい。

### 6.8 📖 移行のしやすさ・将来性

| 移行先 | 使えるモード |
|--------|--------------|
| Fargate | awsvpc のみ |
| ECS Managed Instances | awsvpc / host |
| EC2 | awsvpc / bridge / host / none |
| Windows コンテナ | awsvpc / default（NAT） |

bridge で作ったサービスを Fargate や Managed Instances に移すには、ネットワークの設計（SG、ターゲットタイプ、サービスディスカバリ）を変える必要があります。**awsvpc で作っておくと、キャパシティの選択肢が最も広い** ことを示せます。

### 6.9 📖 セキュリティ監視

- GuardDuty の Runtime Monitoring（ECS）を有効にした場合、検出結果にどの粒度（タスク / インスタンス）の情報が含まれるかをモード別に確認します
- Flow Logs の ECS フィールドで、通信をタスクまで追えるかを確認します（5.1 の表と同じ観点）

---

## 7. 結果のまとめ方

[docs/result-template.md](result-template.md) に、結果を貼り込むテンプレートがあります。

### 7.1 検証前の仮説（結果で上書きする）

| 観点 | 仮説 |
|------|------|
| 起動時間 | B1 は ENI の準備で遅く、多数を同時に起動すると上限で詰まる |
| スループット | ホスト間ではモードの差は小さく、インスタンスの帯域上限の影響が大きい |
| レイテンシ | host が最も低く、bridge はわずかに高い。ただし実際のアプリでは誤差の範囲 |
| コスト | 小さいタスクを大量に動かすと、B1 と D は台数が増えて割高 |
| モニタリング | awsvpc はタスク単位のデータがそろうので、DevOps Agent が影響範囲をタスク単位で特定しやすい |
| セキュリティ | host はコンテナからホストの資源に手が届き、分離が最も弱い |

### 7.2 選び方のフローチャート（結果を見て更新する叩き台）

```
Fargate を使う？ ─ Yes ─▶ awsvpc（選択肢なし）
  │No
  ▼
タスク単位の SG・Flow Logs・障害注入・Service Connect を使いたい？ ─ Yes ─▶ awsvpc（EC2 ならトランキングを有効化）
  │No
  ▼
将来 Fargate / Managed Instances に移す可能性がある？ ─ Yes ─▶ awsvpc
  │No
  ▼
同じポートのタスクを 1 台に多数並べたい？ ─ Yes ─▶ bridge（動的ポート）
  │No
  ▼
ネットワーク性能を最優先し、ワークロードを信頼できる？ ─ Yes ─▶ host（IMDS とポート管理に注意）
  │No
  ▼
awsvpc
```

### 7.3 スライドに載せるグラフの例

- 起動時間：パターン別の箱ひげ図（`network_ready` と `startup_total` を並べる）
- レイテンシ：横軸にレート、縦軸に p99 の折れ線
- コスト：横軸にタスク数、縦軸に月額の折れ線（B1 と D が階段状に増える）
- DevOps Agent：シナリオ × パターンのヒートマップ（原因特定のスコア）
- 追加観点：○ / × の比較表（6.4、6.5、6.8）

---

## 8. 後片付け

```bash
# サービスとアラーム
aws cloudformation delete-stack --stack-name "$PREFIX-services"
aws cloudformation wait stack-delete-complete --stack-name "$PREFIX-services"

# 基盤（ECR は中のイメージごと削除される設定）
aws cloudformation delete-stack --stack-name "$PREFIX-platform"
aws cloudformation wait stack-delete-complete --stack-name "$PREFIX-platform"

# ネットワーク
aws cloudformation delete-stack --stack-name "$PREFIX-network"
aws cloudformation wait stack-delete-complete --stack-name "$PREFIX-network"

# プローブ用のタスク定義を登録解除
for td in $(aws ecs list-task-definitions --family-prefix "$PREFIX-probe" --query 'taskDefinitionArns[]' --output text); do
  aws ecs deregister-task-definition --task-definition "$td" >/dev/null
done

# ENI トランキングを元に戻す（検証前が disabled だった場合）
aws ecs put-account-setting-default --name awsvpcTrunking --value disabled

# 消し忘れの確認
aws resourcegroupstaggingapi get-resources --tag-filters Key=Project,Values="$PREFIX" \
  --query 'ResourceTagMappingList[].ResourceARN' --output text
```

このほか、手動で作ったもの（FIS の実験テンプレートと IAM ロール、DevOps Agent の Agent Space と Webhook、Secrets Manager のシークレット、結果を受け渡した S3 バケット、予算）も削除します。

---

## 付録A. セキュリティチェックリスト

- [ ] 検証専用アカウントで実施している
- [ ] VPC に IGW / NAT がなく、ALB は内部向けになっている
- [ ] タスク・EC2 にパブリック IP を付けていない
- [ ] EC2 は IMDSv2 必須・ホップ数上限 1、awsvpc は `ECS_AWSVPC_BLOCK_IMDS=true`
- [ ] host モードのタスクは信頼できるイメージだけを使っている
- [ ] タスクロールに権限がない
- [ ] SSH ではなく SSM Session Manager で接続している
- [ ] イメージは ECR でスキャン済みで、ダイジェストで指定している（ベースイメージもダイジェストで固定）
- [ ] コンテナは非 root・読み取り専用ルート・ケーパビリティなしで動いている
- [ ] シークレット（Webhook の認証情報など）は Secrets Manager に保存している
- [ ] DevOps Agent のロールに書き込み権限を足していない
- [ ] FIS の実験には停止条件を設定し、対象を 1 タスクに限定している
- [ ] ログの保持期間を設定している
- [ ] 予算アラートを設定している
- [ ] 検証後にすべて削除し、アカウント設定を元に戻した

## 付録B. トラブルシューティング

| 症状 | よくある原因 | 対処 |
|------|--------------|------|
| ネットワークスタックの Flow Logs 作成に失敗 | リージョンが `ecs-*` フィールドに未対応 | `01-network.yaml` の `LogFormat` から `ecs-*` を外す（その場合、5.1 の比較は ENI ID とタスクの対応表で行う） |
| awsvpc のタスクが `PROVISIONING` のまま | ENI の上限、サブネットの IP 不足 | トランキングを有効化、サブネットを広げる |
| B2 にトランク ENI が付かない | 有効化する前に起動したインスタンス | B2 の ASG のインスタンスを入れ替える |
| bridge のターゲットが unhealthy | インスタンス SG で動的ポートを開けていない | `Ec2BridgeSg` の 32768–65535 を確認 |
| host のタスクが置けない | 同じインスタンスでポートが使用中 | 台数を増やすか、`desired-count` を台数以下にする |
| イメージの取得に失敗 | VPC エンドポイントの不足 | ECR API / DKR / S3 のエンドポイントを確認 |
| 負荷生成 EC2 で `dnf` が失敗 | S3 ゲートウェイエンドポイントのルート | ルートテーブルの関連付けを確認 |
| k6 の `dropped_iterations` が 0 でない | 負荷生成側の限界 | 負荷生成のインスタンスを大きくする |
| FIS のアクションが失敗 | `pidMode`、`enableFaultInjection`、SSM エージェントのサイドカー、ECS Exec が有効 | [devops-agent/scenarios.md](../devops-agent/scenarios.md) の F-4 の前提を確認 |
| DevOps Agent が ECS を認識しない | トポロジーの検出が終わっていない、ロールの権限不足 | 検出完了を待つ、ロールを確認 |

---

## 参考資料

- ECS のタスクネットワーク（EC2）：https://docs.aws.amazon.com/AmazonECS/latest/developerguide/task-networking.html
- awsvpc ネットワークモード：https://docs.aws.amazon.com/AmazonECS/latest/developerguide/task-networking-awsvpc.html
- ENI トランキング：https://docs.aws.amazon.com/AmazonECS/latest/developerguide/container-instance-eni.html
- ENI トランキング対応インスタンス：https://docs.aws.amazon.com/AmazonECS/latest/developerguide/eni-trunking-supported-instance-types.html
- ECS Managed Instances のネットワーク：https://docs.aws.amazon.com/AmazonECS/latest/developerguide/managed-instance-networking.html
- サービス間の接続（Service Connect / Cloud Map / VPC Lattice の対応表）：https://docs.aws.amazon.com/AmazonECS/latest/developerguide/interconnecting-services.html
- ECS の IPv6 のみ対応（2025 年 9 月）：https://aws.amazon.com/blogs/containers/amazon-ecs-announces-ipv6-only-support
- Container Insights のメトリクス（ECS）：https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/Container-Insights-metrics-ECS.html
- FIS の ECS タスクアクション：https://docs.aws.amazon.com/fis/latest/userguide/ecs-task-actions.html
- ECS の障害注入エンドポイント：https://docs.aws.amazon.com/AmazonECS/latest/developerguide/fault-injection-endpoints.html
- AWS DevOps Agent（Webhook）：https://docs.aws.amazon.com/devopsagent/latest/userguide/configuring-integrations-and-knowledge-invoking-devops-agent-through-webhook.html
- AWS DevOps Agent の料金：https://aws.amazon.com/devops-agent/pricing/
- AWS Fargate の料金：https://aws.amazon.com/fargate/pricing/
