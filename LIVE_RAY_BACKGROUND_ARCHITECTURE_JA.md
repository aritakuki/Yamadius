# Lispライブ・レイトレーシング背景の技術構成

両リポジトリとも、作業ブランチをデフォルトブランチの `main` にfast-forwardマージし、push済みです。

- Yamadius: `main` → `b9f0736`
- lisp-raytracer: `main` → `bd6135`
- 共有メモリのプロトコルテストも成功済み
- `AGENTS.md`、`SESSION_HANDOFF.md`、Lisp側の一時生成物はローカルのまま残し、commitしていません

## 1. HaskellはGPUをどう使っているか

基本的にはOpenGL経由です。

```text
Haskellのゲーム処理（CPU）
        │
        ├─ OpenGL命令
        │    └─ NVIDIA GPU
        │         ├─ 背景テクスチャ描画
        │         ├─ 地形・敵・弾・自機の描画
        │         └─ 半透明合成
        │
        └─ Effekseer C++ブリッジ
             └─ EffekseerRendererGL
                  └─ NVIDIA GPU
```

HaskellがCPUで行うものは、ゲーム状態、座標、当たり判定、シーン遷移などです。描画時にはHaskellのOpenGLバインディングを通じて、頂点、テクスチャ、行列、ブレンド方法などをOpenGLへ渡します。実際のラスタライズやテクスチャ合成はGPUが行います。

背景については、Lispから届いたRGBA画像をOpenGLテクスチャへアップロードし、画面全体を覆う四角形として最初に描画します。その後に地形、自機、敵、弾、HUDなどを重ねています。実装は `Monadius.hs` の `renderMonadius` 周辺にあります。

### Colabの場合

Colabには通常のデスクトップ画面がないため、GLUTのウィンドウへ直接表示していません。

C++側がEGLを使ってNVIDIA GPU上にオフスクリーンOpenGLコンテキストを作ります。実装は `EglBridge.cpp` にあります。

```text
Haskell/OpenGL
   ↓
EGL上のオフスクリーン画面
   ↓
OpenGL PBOで画面を読み出す
   ↓
JPEGへ変換
   ↓
ColabのPythonブリッジ
   ↓
ブラウザ
```

つまり、ブラウザに見えているJPEGは表示用の最終転送形式です。ゲーム内部とLisp背景の受け渡しにJPEGや画像ファイルを使っているわけではありません。

## 2. LispとHaskellの関係・インターフェース

現在は同一プロセスではなく、次の2プロセス構成です。

```text
SBCL / Common Lispプロセス
  CUDAでレイトレーシング
        │
        │ 完成したRGBAフレーム
        ▼
Linux共有メモリ（memfd・3バッファ）
        │
        │ 更新世代を確認
        ▼
Haskell Mainプロセス
  OpenGLテクスチャへアップロード
        │
        ▼
ゲーム背景として描画
```

Haskell側が全体の管理者です。

1. Haskell/C++側が匿名共有メモリを作る
2. SBCLを別プロセスとして起動する
3. 共有メモリのファイルディスクリプタをSBCLへ継承させる
4. LispがCUDAでレイトレーシングを続ける
5. 完成したフレームだけを共有メモリへ公開する
6. Haskellが新しいフレームを検知したときだけOpenGLテクスチャを更新する

プロセス起動と共有メモリ作成は `RayBackgroundBridge.cpp` にあります。

### HaskellはLispを待たない

毎ゲームフレーム、Haskell側は共有メモリの `generation`、つまり更新番号を確認します。

- 更新されている → 新しいRGBA画像をOpenGLへアップロード
- 更新されていない → 以前のOpenGLテクスチャをそのまま描画
- Lispが計算中 → Haskellは待たずにゲームを続行

これは「毎フレーム、そこにあるものを描画する」という動作です。実装は `RayBackgroundBridge.cpp` の `renderRayBackground` 周辺にあります。

### 3バッファにした理由

共有メモリには画像領域を3枚用意しています。

- 1枚は現在公開中
- 1枚はHaskellが読み取り中かもしれない
- 残る1枚へLispが次の画像を書ける

Lispは書き込み途中の画像を公開しません。RGBAへの変換が全部終わった後、アトミック操作で `front_index` と `generation` を更新します。実装はlisp-raytracer側の `GPU/monadius-shared-memory.c` にあります。

したがって、Haskellが半分だけ更新された画像を表示することはありません。

### CUDAメモリを直接共有しているわけではない

現在の経路は次のとおりです。

```text
CUDAデバイスメモリ
  ↓ device-to-hostコピー
Lisp側ホストメモリ
  ↓ RGB→RGBA変換
Linux共有メモリ
  ↓ glTexSubImage2D
OpenGLテクスチャ（GPU）
```

つまり、プロセス間インターフェースは「CUDAデバイスメモリ」ではなく「Linuxの共有ホストメモリ」です。

CUDA/OpenGLの直接相互運用よりコピーは増えますが、SBCLとHaskell/OpenGLを完全に別プロセスとして隔離でき、どちらかのランタイムやシグナル処理がもう一方を壊しにくい構成になっています。

Lisp側のCUDAループはlisp-raytracer側の `GPU/gpu-live-background.lsp`、Haskell側の新フレーム取得とテクスチャ更新はYamadius側の `RayBackgroundBridge.cpp` にあります。
