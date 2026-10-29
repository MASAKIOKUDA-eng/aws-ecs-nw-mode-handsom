# 障害シナリオ（DevOps Agent 評価用）

すべてのシナリオで次を守ります。

- **1 回に 1 パターン・1 シナリオだけ** 起こす（同時に起こすと原因が混ざる）
- 起こした時刻・戻した時刻を [evaluation-sheet.md](evaluation-sheet.md) に記録する
- 負荷生成 EC2 から軽い負荷（例：`lg run-k6.sh --rates 100 --duration 15m`）をかけ続け、アラームが発報する状態を作る
- 戻した後、メトリクスが平常に戻るまで 10 分以上空ける

変数（CloudShell）：

```bash
out() { aws cloudformation describe-stacks --stack-name "$1" --query "Stacks[0].Outputs[?OutputKey=='$2'].OutputValue" --output text; }
TASK_SG=$(out "$PREFIX-network" TaskSg)
BRIDGE_SG=$(out "$PREFIX-network" Ec2BridgeSg)
HOST_SG=$(out "$PREFIX-network" Ec2HostSg)
ALB_SG=$(out "$PREFIX-network" AlbSg)
```

---

## F-1：SG ルールの削除（ALB → ターゲット）

**狙い**：設定変更（CloudTrail に残る）を原因として特定できるか。awsvpc はタスク SG、bridge / host はインスタンス SG が対象になるため、影響範囲の説明が変わるかを見る。

| パターン | 削除するルール |
|----------|----------------|
| A / B1 / B2 | `TASK_SG` の 8080 ← `ALB_SG` |
| C | `BRIDGE_SG` の 32768–65535 ← `ALB_SG` |
| D | `HOST_SG` の 8080 ← `ALB_SG` |

> A / B1 / B2 は同じ `TaskSg` を共有しているため、削除すると 3 パターン同時に影響します。1 パターンずつ評価したい場合は、評価しないパターンの `desired-count` を 0 にしてから行います。これ自体も「SG をどう分けるか」という設計の話題になります。

```bash
# 例：D
RULE_ID=$(aws ec2 describe-security-group-rules --filters Name=group-id,Values="$HOST_SG" \
  --query "SecurityGroupRules[?!IsEgress && FromPort==\`8080\` && ReferencedGroupInfo.GroupId=='$ALB_SG'].SecurityGroupRuleId" --output text)
aws ec2 revoke-security-group-ingress --group-id "$HOST_SG" --security-group-rule-ids "$RULE_ID"
```

**戻し方**：同じルールを追加し直す（テンプレートは変わっていないため、`cloudformation deploy` の再実行では戻りません）。

```bash
# 例：D（A / B は TASK_SG と 8080、C は BRIDGE_SG と 32768-65535）
aws ec2 authorize-security-group-ingress --group-id "$HOST_SG" --protocol tcp --port 8080 --source-group "$ALB_SG"
# C の場合
# aws ec2 authorize-security-group-ingress --group-id "$BRIDGE_SG" --protocol tcp --port 32768-65535 --source-group "$ALB_SG"
```

戻した後、CloudFormation のドリフト検出で差分がないことを確認します。

**正解**：「<時刻> に `<SG ID>` から ALB からの許可ルールが削除され、ヘルスチェックが失敗してターゲットが unhealthy → 5xx（503）」。

---

## F-2：ポート衝突でデプロイが止まる（host）

**狙い**：「タスクが置けない理由」がポートの衝突であると特定できるか。

```bash
# 予備の台数がない状態で、最小ヘルス率 100% のローリング更新を行う
aws ecs update-service --cluster "$PREFIX" --service svc-d \
  --deployment-configuration "minimumHealthyPercent=100,maximumPercent=200" \
  --force-new-deployment
```

サービスのイベントに、ポートが使用中のためタスクを置けない旨のメッセージが出続けます。デプロイのサーキットブレーカーが働くまで、または 15 分経つまで観察します。

**比較**：同じ操作を C（動的ポート）で行うと、デプロイは問題なく進みます（ポートが衝突しないため）。

**戻し方**：

```bash
aws ecs update-service --cluster "$PREFIX" --service svc-d \
  --deployment-configuration "minimumHealthyPercent=50,maximumPercent=100"
```

**正解**：「host モードで全インスタンスの 8080 が使用中のため、新しいタスクを置けない。予備の台数を持つか、最小ヘルス率を下げる、または awsvpc / bridge を検討」。

---

## F-3：ENI 不足でタスクが起動しない（B1）

**狙い**：`PENDING` / 起動失敗の理由を ENI 不足と特定し、トランキングを提案できるか。

```bash
aws ecs update-service --cluster "$PREFIX" --service svc-b1 --desired-count 12
```

**比較**：B2 で同じ数に増やすと、トランキングにより（CPU / メモリが足りる範囲で）起動できます。

**戻し方**：`--desired-count 2`

**正解**：「インスタンスあたりの ENI の上限に達し、awsvpc のタスクを置けない。ENI トランキングを有効化するか、インスタンスを増やす / 大きくする」。

---

## F-4：特定タスクだけ遅い（FIS のネットワーク遅延）

**狙い**：多数のタスクのうち 1 つだけが遅いことを突き止められるか。

**前提**（A / B / D のみ。**bridge は FIS の ECS ネットワークアクションの対象外**）：

1. `03-services.yaml` を `EnableFaultInjection=true` で再デプロイ（`pidMode: task` と `enableFaultInjection: true` が入る）
2. FIS の要件に従い、タスク定義に SSM エージェントのサイドカーと、そのための IAM ロールを追加する（[FIS の ECS タスクアクション](https://docs.aws.amazon.com/fis/latest/userguide/ecs-task-actions.html) の手順に従う）
3. **ECS Exec は無効のまま**（有効だとアクションが使えない）
4. FIS 用の IAM ロールを最小権限で作る
5. [fis-latency-template.json](fis-latency-template.json) の `<...>` を置き換える。**停止条件のアラームを必ず指定** し、対象は `COUNT(1)`（1 タスク）にする

```bash
aws fis create-experiment-template --cli-input-json file://devops-agent/fis-latency-template.json
aws fis start-experiment --experiment-template-id <id>
```

**bridge（C）の代わり**：FIS が使えないこと自体を結果として記録します。どうしても同じ現象を起こしたい場合は、アプリ側で遅延を入れる（例：nginx の設定で特定のパスだけ遅くする）方法がありますが、ネットワーク起因ではなくなる点を明記します。

**正解**：「タスク `<ID>` だけ応答時間が長い。ネットワーク遅延が原因（他のタスクは正常）」。

---

## F-5：高負荷による応答悪化

**狙い**：CPU が原因か、ネットワークが原因かを見分けられるか。

```bash
# 負荷生成 EC2 で、3 章で見つけた「p99 が悪化し始めるレート」の 1.5 倍をかける
lg run-k6.sh --label C --url "http://$ALB_DNS:8004/1m" --rates "<rate>" --duration 10m --path alb
```

- `/1m` は帯域寄り、`/1k` は CPU 寄りの負荷になります。両方で試します
- host（D）では Container Insights のネットワークメトリクスが取れないため、エージェントがどのデータで判断するかに注目します

**正解**：Container Insights の CPU / ネットワークのメトリクス、ALB の応答時間などを根拠に、ボトルネックを正しく指摘できているか。
