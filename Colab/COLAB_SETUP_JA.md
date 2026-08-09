# Monadius Colab 初期セットアップ・再接続手順

対象ブランチは両リポジトリとも `feature/live-raytraced-background` です。
Colab上の配置先はMonadiusが `/content/Yamadius-colab`、Lispが
`/content/lisp-raytracer` です。

## 最初に知っておくこと

- Colabのランタイムが初期化されると、`/content` 以下はすべて消えます。
  `/content/Yamadius-colab` がないのは、その場合は正常です。
- `%env MONADIUS_PORT=...` は環境変数を設定するだけです。
  `env: MONADIUS_PORT=...` と表示されてもゲームはまだ起動していません。
- Colabに `%git` というマジックはありません。Gitコマンドは `!git` を使います。
- `Colab/run-colab.sh` を複数のセルから直接起動しないでください。
  起動・再起動には `Colab/fresh_start.py` を使います。
- セル内画面と「別ウィンドウで開く」で表示した画面は、一つのゲームを共有します。
  ただし、起動セルを複数回同時に実行すると、古いiframeが余分な通信を行う可能性があります。

## 1. ランタイムが初期化されたか確認する

次をColabのPythonセルで実行します。

```python
from pathlib import Path

repo = Path("/content/Yamadius-colab/.git")
print("既存環境あり" if repo.is_dir() else "初期状態（再セットアップが必要）")
```

「初期状態」と表示された場合は次の「完全セットアップ」を実行します。
「既存環境あり」の場合は「既存環境のクリーン再起動」へ進みます。

## 2. 完全セットアップ：`/content/Yamadius-colab` がない場合

ColabでGPUランタイムを選択してから、次のシェルセルを一度だけ実行します。
依存パッケージ、両リポジトリ、Lispを埋め込むSBCL共有ランタイム、Effekseer、
Monadiusをすべて準備し、ポート8765で起動します。初回はSBCLもビルドするため、
従来より時間がかかります。

```bash
!curl -fsSL https://raw.githubusercontent.com/aritakuki/Yamadius/feature/live-raytraced-background/Colab/bootstrap-colab.sh | bash
```

完了したら、次のPythonセルで画面を表示します。bootstrap処理がすでにゲームを
起動しているため、ここでは二重起動せずiframeだけを表示します。

```python
%cd /content/Yamadius-colab
from google.colab import output
output.serve_kernel_port_as_iframe(8765, height=1100)
```

ゲーム画面を一度クリックして、キーボード入力とブラウザ音声を有効にします。

## 3. 接続だけ切れ、Colabランタイムが残っている場合

ゲームプロセスが動作したままで、セル出力だけが消えた場合は、再起動せず同じ
ポートを再表示できます。次はポート8765で起動していた場合です。

```python
from google.colab import output
output.serve_kernel_port_as_iframe(8765, height=1100)
```

以前に8781など別のポートを指定した場合は、その番号を使います。古いゲーム画面が
まだ正常に表示されている場合は、別セルで再表示せず、その画面を使ってください。

## 4. 既存環境のクリーン再起動

画面が出ない、操作や音声がおかしい、または現在のプロセス状態が不明な場合は、
一系統だけになるようクリーン再起動します。新しいポート番号を一つ決めてください。
以下では8781を使用します。

通常は `fresh_start.py` 自体が古い `Main`、ブリッジ、Xvfbを停止するため、まずは
次のセルだけで十分です。

```python
%cd /content/Yamadius-colab
%env MONADIUS_PORT=8781
%run Colab/fresh_start.py
```

`env: MONADIUS_PORT=8781` は正常な途中出力です。その次の `%run` が実際の停止、
起動、iframe表示を行います。

## 5. `pkill` が必要な場合

`fresh_start.py`を実行しても何も起きない、古いrunnerが残る、同時起動が疑われる
場合だけ、次のセルで関連プロセスを明示的に停止します。`[b]ash`などの角括弧は、
`pkill`コマンド自身を誤って一致させないために必要です。

```bash
!pkill -f '[b]ash /content/Yamadius-colab/Colab/run-colab.sh' || true
!pkill -f '[p]ython3 /content/Yamadius-colab/Colab/monadius_colab_bridge.py' || true
!pkill -x Main || true
!pkill -f '[X]vfb :99' || true
```

停止後、新しいポートで一度だけ起動します。

```python
%cd /content/Yamadius-colab
%env MONADIUS_PORT=8781
%run Colab/fresh_start.py
```

ポート8781を以前も使用していて起動できない場合は、8782、8783のように番号を
一つ増やします。複数の起動セルを連続して実行しないでください。

## 6. Git更新後に再起動する場合

```python
%cd /content/Yamadius-colab
!git branch --show-current
!git pull --ff-only
```

期待されるブランチは `feature/live-raytraced-background` です。HaskellまたはC++が
更新された場合は、続けてビルドします。ColabブリッジなどPythonファイルだけの
更新なら、このビルドは不要です。

```bash
!MONADIUS_COLAB_EGL=1 EFFEKSEER_PREFIX=/content/effekseer-install bash build.sh
```

Lisp側が更新された場合は、Lisp用ブランチも取得し、同一プロセス呼び出し用の
コアを作り直します。

```bash
!git -C /content/lisp-raytracer branch --show-current
!git -C /content/lisp-raytracer pull --ff-only
!bash Colab/build-ray-background-runtime.sh /content/lisp-raytracer /content/monadius-ray-runtime
```

Lispは完成した画像だけを世代番号付き二重バッファへ公開します。Haskellは世代が
変わった時だけテクスチャ内容を更新し、Lispが計算中なら直前の完成画像をそのまま
使います。ゲーム側の更新や描画がLispの完了を待つことはありません。

その後、「既存環境のクリーン再起動」の `%run Colab/fresh_start.py` を実行します。

## 7. 起動状態の確認

```bash
!ps -eo pid,ppid,etime,cmd | grep -E '[r]un-colab|[m]onadius_colab_bridge|[X]vfb|[.]\/Main'
!test -f /tmp/monadius-colab/runner.log && tail -30 /tmp/monadius-colab/runner.log
!test -f /tmp/monadius-colab/bridge.log && tail -30 /tmp/monadius-colab/bridge.log
!test -f /tmp/monadius-colab/game.log && tail -30 /tmp/monadius-colab/game.log
```

正常時は、`run-colab.sh`、`monadius_colab_bridge.py`、`Xvfb :99`、`./Main`が
それぞれ一つずつ表示されます。最初の背景が完成してゲーム画面に取り込まれると、
`game.log` に `Live CUDA background published frame 1` と
`OpenGL accepted the first complete Lisp background` がこの順で記録されます。
