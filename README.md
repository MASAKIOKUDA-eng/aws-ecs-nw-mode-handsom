# Amazon ECS ネットワークモード比較ハンズオン

> 登壇タイトル：**Amazon ECS ネットワークモード選びに悩まない ～検証を通じて見えたネットワークモードの選び方～**

同じアプリを ECS の複数のネットワークモードで動かし、次の観点で比べるためのハンズオン一式です。

| # | 観点 | 主な問い |
|---|------|----------|
| 1 | **スピード** | タスクはどれだけ速く起動するか。スループットとレイテンシに差は出るか |
| 2 | **コスト** | 1 台に何タスク置けるか。同じタスク数を動かすと月額はいくらか |
| 3 | **モニタリング能力** | AWS DevOps Agent は障害の原因と影響範囲を正しく特定できるか |
| 4 | **追加観点** | セキュリティの分離、IP 消費、デプロイ、サービス間通信、サイドカー、IPv6、ノイジーネイバー、移行のしやすさ |

手順の詳細は [docs/handson-guide.md](docs/handson-guide.md) にあります。

## 比較するパターン

| ID | キャパシティ | ネットワークモード | ALB ターゲット |
|----|--------------|--------------------|----------------|
| A | Fargate | awsvpc | ip |
| B1 | EC2 | awsvpc（ENI トランキングなし） | ip |
| B2 | EC2 | awsvpc（ENI トランキングあり） | ip |
| C | EC2 | bridge（動的ポート） | instance |
| D | EC2 | host | instance |

## リポジトリ構成

```
.
├── README.md                     この概要
├── docs/
│   ├── handson-guide.md          ハンズオン手順（本体）
│   └── result-template.md        結果をまとめるテンプレート（登壇資料用）
├── cfn/
│   ├── 01-network.yaml           VPC（private のみ）、VPC エンドポイント、SG、Flow Logs
│   ├── 02-platform.yaml          ECS クラスター、IAM、ECR、内部 ALB、EC2 キャパシティ、負荷生成 EC2
│   └── 03-services.yaml          タスク定義、サービス、アラーム（A / B1 / B2 / C / D）
├── docker/
│   ├── netbench/                 計測対象（nginx 非 root + iperf3）
│   └── loadgen/                  負荷生成（k6 + iperf3 + 計測スクリプト）
├── scripts/
│   ├── measure-startup.sh        タスク起動時間の計測
│   ├── get-targets.sh            タスクへの直接の接続先（IP / ポート）を表示
│   ├── run-iperf.sh              スループット計測（負荷生成イメージ内で実行）
│   ├── run-k6.sh / k6-load.js    HTTP レイテンシ計測（負荷生成イメージ内で実行）
│   ├── security-probe.sh         モード別の分離状況の確認
│   ├── cost-calc.py              コスト試算
│   └── summarize.py              結果 CSV の集計（中央値 / p95）
├── devops-agent/
│   ├── scenarios.md              障害シナリオと戻し方
│   ├── evaluation-sheet.md       DevOps Agent の評価シート
│   └── fis-latency-template.json FIS 実験テンプレートの例
└── results/                      計測結果の置き場所（CSV はコミットしない）
```

## セキュリティ方針

- 検証専用の AWS アカウントで実施する
- VPC はインターネットに出入口を持たない（IGW / NAT なし）。AWS サービスは VPC エンドポイント経由
- ALB は内部向け。人が見るときは SSM のポートフォワーディングを使う
- EC2 は IMDSv2 必須、SSH なし（SSM Session Manager で接続）
- コンテナは非 root、ルートファイルシステムは読み取り専用、Linux ケーパビリティはすべて削除
- タスクロールには権限を付けない
- イメージは ECR でスキャンし、ダイジェストで指定する

## ライセンス

Apache License 2.0
